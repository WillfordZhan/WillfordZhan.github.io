---
title: "一次 ERP AI 会话频繁中断的排查：SSE 心跳、Spring 异步超时与 Pi 状态投影"
date: 2026-08-12 18:58:08
categories:
  - "AI"
tags:
  - "Pi"
  - "Java Runtime"
  - "SSE"
  - "Spring Boot"
  - "故障复盘"
  - "AI工作日志"
source_archive:
  id: 20260812-pi-java-runtime-sse-interruption
  rel_path: source_materials/posts/20260812-pi-java-runtime-sse-interruption
  conversation_file: conversation.jsonl
---

ERP 里接入数字员工后，普通问答偶尔会同时出现两条提示：一条是“本次业务处理未完成”，另一条是“连接已中断”。发生问题的会话通常已经开始调用 Tool，回答生成到一半就停止。

这次排查确认了两个问题。Spring MVC 的异步响应先超时，Pi 随后把下游断开解释成会话取消；前端又分别展示了 Tool 失败和连接失败，于是一次断流变成了两条错误提示。

## 现场证据

先看服务端时间线。同一时段里，Java 日志连续出现 4 次 `AsyncRequestTimeoutException`。对应的 Pi 会话 JSONL 中，Tool 结束状态为 aborted，紧随其后的 assistant 消息也是：

```json
{
  "role": "assistant",
  "stopReason": "aborted",
  "errorMessage": "Request aborted"
}
```

对当天相关会话做了一次小范围统计：5 次正常结束，4 次 assistant aborted；Tool 结果里有 2 次中断，另外 2 次是正常的业务失败。这个分布说明业务 Tool 确实会失败，但截图中的高频现象主要来自连接中断，不能统一归类成业务处理失败。

## 中断是怎样传到 Pi 的

当前链路是：

```text
浏览器 fetch SSE
  -> Java AiController
  -> StreamingResponseBody 转发上游响应
  -> Pi streamConversation()
  -> PiConversationRuntime.startConversation()
  -> AgentSession.prompt()
  -> 模型推理 / Tool 调用
```

对 Java 后端开发者来说，可以把 `AgentSession` 看成一个带事件流和持久化历史的有状态执行器。它会产生文本增量、Tool 开始、Tool 结束和最终回答等事件，HTTP 层只负责把这些事件投影成 SSE。

问题发生时，Spring MVC 的异步请求先达到默认超时并关闭响应。Pi 的 HTTP 层监听了连接关闭：

```ts
const abortOnClose = () => {
  clientDisconnected = true;
  started.abort();
};

response.once("close", abortOnClose);
```

`started.abort()` 触发 `AbortController`，Runtime 再把信号传给当前 `AgentSession`：

```ts
const abortSession = () => void session.abort();
signal?.addEventListener("abort", abortSession, { once: true });
```

因此 Pi 记录 aborted 是符合当前实现的。Pi 没有自行把一条正常任务取消掉，它收到了下游连接已经关闭的事实。

## 修复分成三层

### 1. Pi 每 15 秒发送一次 SSE 心跳

模型思考和 Tool 执行期间可能暂时没有文本输出。链路中的反向代理、Java HTTP 客户端或移动网络会把这种连接视为空闲连接。

Pi 的 SSE 接入层增加了最小心跳：

```ts
const SSE_HEARTBEAT_INTERVAL_MS = 15_000;

const heartbeat = setInterval(() => {
  writeSse(response, "ping", {
    timestamp: new Date().toISOString(),
  });
}, SSE_HEARTBEAT_INTERVAL_MS);

try {
  await started.result;
} finally {
  clearInterval(heartbeat);
}
```

`ping` 只维持连接，不进入 Agent 状态机，前端也不需要把它渲染成消息。`finally` 清理定时器，避免会话结束后残留任务。

### 2. Java 把异步响应窗口延长到 10 分钟

心跳能处理空闲超时，处理不了 Spring MVC 的总时长限制。Java 入口服务同时配置异步执行器和总超时：

```java
@Override
public void configureAsyncSupport(AsyncSupportConfigurer configurer) {
    configurer.setTaskExecutor(taskExecutor);
    configurer.setDefaultTimeout(10 * 60 * 1000L);
}
```

这里复用了项目已有的 `threadPoolTaskExecutor`。启动日志此前提示 `SimpleAsyncTaskExecutor` 不适合生产负载；继续使用默认执行器，会让每条流式响应缺少统一的线程数、队列和拒绝策略治理。

10 分钟只是正常 Agent 执行的上限，不承担保活职责。两项配置解决的是不同问题：

```text
15 秒 ping
  -> 避免空闲连接被中间层回收

10 分钟 MVC timeout
  -> 允许模型推理和多轮 Tool 在合理窗口内完成
```

### 3. 中断状态由 Pi 结构化投影，前端只展示一次

原来的历史投影看到 `toolResult.isError` 就显示“业务处理未完成”。连接中断产生的 Tool error 也走了这条分支，无法和库存不足、参数校验失败等真实业务错误区分。

Pi 的会话历史已经包含结构化的 `assistant.stopReason`。投影层利用相邻 Entry，把中断标记为单独的失败类型：

```ts
if (
  message.stopReason === "aborted" &&
  pendingFailedToolResultIndex !== undefined
) {
  interrupted.data = {
    tool_call_id: toolCallId,
    is_error: true,
    failure_kind: "interrupted",
    display_text: "连接中断，业务处理结果未知，请勿重复操作",
  };
}
```

这个判断没有匹配错误文案，也没有针对某个 Tool 写例外规则。Pi 原生的终止状态是事实源，`failure_kind` 是给 UI 使用的展示投影。

前端在 SSE 没收到 `final` 时重新加载会话历史。历史中已经存在 `failure_kind: interrupted`，就不再追加第二条“连接已中断”：

```js
const recovered = conversationId
  ? await loadMessages(conversationId)
  : false

if (!recovered) addNotice('连接已中断，可继续发送消息')
```

## 为什么没有自动重放

断流不等于 Tool 没有执行。写类 Tool 可能已经在 Java 事务里提交成功，只是 Pi 在收到或持久化 `toolResult` 前失去了连接。此时自动重放可能重复创建单据。

这次只恢复服务端已经持久化的会话状态，并把文案改成“处理结果未知，请勿重复操作”。写操作的自动恢复需要业务幂等键、结果查证接口或可恢复的执行状态机，不能由前端重发用户问题代替。

## 验证

修复后做了三层验证：

- Pi：2 个相关测试文件、14 个测试通过，其中包含“模型暂时无输出时仍发送 ping”和“aborted 与业务失败分开投影”的回归测试。
- Java：入口模块及依赖模块测试通过，并验证 ERP 应用名能够注册异步 MVC 配置。
- 前端：生产构建通过；SSE 提前结束后能从历史恢复结构化中断状态，不再重复提示。

部署到测试环境后，Java 容器健康检查通过，Spring 在 55.451 秒完成启动；Pi Runtime 使用新镜像启动，`/healthz` 返回 `ok`。入口健康接口和 AI 状态接口都返回 HTTP 200。

## 这次改动的边界

Pi 心跳只能防止空闲连接被回收，网络真正断开时仍会中断。10 分钟超时也不是无限执行许可，超过窗口的任务更适合改成异步 Job，再通过状态查询或事件通知返回结果。

当前 Spring 配置作用于入口服务的异步 MVC 响应。以后同一服务增加不同超时口径的异步接口时，需要把超时策略进一步收口到具体入口。当前阶段只有 AI SSE 使用这条长连接路径，先复用原有线程池并设置统一上限，变更面最小。
