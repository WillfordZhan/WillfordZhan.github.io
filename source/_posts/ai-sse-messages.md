---
title: "把 AI 助手改成 SSE 打字机输出，这次我没有去改 messages"
date: 2026-03-23 16:39:32
tags:
  - "AI"
  - "SSE"
  - "FastAPI"
  - "Spring Boot"
  - "小程序"
categories:
  - "AI"
source_archive_id: "20260323-ai-sse-typing-stream"
---

这次要做的需求不复杂：让 AI 助手的回答从“等几秒后整段出现”，改成“边生成边显示”的打字机效果。

一开始最容易想到的改法，是把现有的 `GET /messages` 改成 SSE。看起来改动小，前端也已经有一个拿消息的入口。但把链路顺下来以后，这个方向很快就卡住了，因为 `/messages` 在当前系统里承担的是历史投影和断线补齐，不是当前这一次提问的实时生成通道。

## 先把链路看清楚

当前链路其实是三段。

第一段是 Python 控制面。用户发起 `create` 或 `chat` 以后，Python 会先把用户消息落库，再把任务异步扔给 orchestrator，HTTP 很快返回 `202 accepted`。等编排跑完，再写一条 `final`、`clarification_needed` 或 `conversation_failed` 到会话事件里。

第二段是 Java 网关。它负责把登录态和业务上下文签进去，再把请求转发给 Python。现在这层是典型的缓冲代理：把上游响应整个读完，再作为 `ResponseEntity<String>` 返回。

第三段是前端。管理页现在还是轮询模式。小程序页已经预埋了流式消费能力，会先尝试对 `POST /conversations` 和 `POST /chat` 走 chunked/SSE，失败再自动回退到轮询 `/messages`。

这三个事实放在一起，问题就清楚了。

前端不是没准备好。真正没通的是后端。

Python 侧现在没有对外的 SSE API，也没有把 LLM 的增量 token 往前端继续透。即便内部某个上游支持 streaming，最后也是先聚合成完整 answer，再往下走终态写回。Java 侧的问题更直接，网关现在会把上游 body 读完才返回，这一层就已经把流式打断了。

## SSE 到底是什么

SSE 全称是 `Server-Sent Events`。可以把它理解成一种很薄的 HTTP 流式协议。

它不是 WebSocket，也不是轮询。它本质上还是一条普通 HTTP 请求，只是服务器在响应头里告诉客户端，这是一条事件流：

```http
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: keep-alive
```

然后这个响应不会立刻结束，而是持续往同一条连接里写事件。每条事件通常长这样：

```text
event: answer_delta
data: {"delta":"今"}

event: answer_delta
data: {"delta":"天"}

event: final
data: {"answer":"今天炉次生产情况如下"}
```

前端收到第一条 `answer_delta` 就能开始显示，不需要等整段回答全生成完。

所以打字机效果真正依赖的，不是前端自己做动画，而是后端真的一段一段把内容吐出来。

## 为什么当前链路没有打字机效果

因为现在这条链路里，Python 和 Java 都还是“缓冲式”的。

Python 侧现在的 `create/chat` 是异步受理模式。请求进来以后，先把用户消息写进会话，再把任务扔给 orchestrator，HTTP 很快返回 `202 accepted`。后面等编排结束，再把 `final` 写进会话事件。也就是说，当前 HTTP 请求早就结束了，前端只能再去轮询 `/messages`。

Java 网关这边的问题更直接。它现在不是流式代理，而是缓冲代理。代码路径大致是：

1. 打开到 Python 的 HTTP 连接
2. 拿到响应状态码
3. 调 `readBody(conn)` 把整个响应体读成字符串
4. 再用 `ResponseEntity<String>` 返回给前端

这一步会把上游的流式输出直接打平。即便 Python 真的开始一段一段吐 token，Java 也会等全部读完以后再一次性把整段字符串返回。

所以这次改造的重点不是前端，而是把“读完整 body 再返回”的链路，改成“边读上游、边写下游”的链路。

## 为什么我不打算改 `/messages`

这次改造的第一条判断是：SSE 不应该落在 `GET /messages`，而应该落在 `POST /conversations` 和 `POST /conversations/{id}/chat` 上，通过 `Accept: text/event-stream` 做内容协商。

原因有四个。

第一，小程序现有实现基本不用推倒重来。它本来就是按 `create/chat` 先尝试流式，再退回轮询。后端协议对齐以后，前端主路径就能直接生效。

第二，`/messages` 可以继续只做历史真相。页面刷新、切会话、弱网恢复，还是从持久化消息里拿。实时流和历史投影不是一回事，混在一个接口里只会把语义搞乱。

第三，一次用户提问对应一条长连接，边界清楚。连接打开以后只服务当前这一轮，流到 `final` 就结束。超时、中断、trace 都比较好挂。

第四，当前 `/messages` 的职责本来就是“历史投影、断线补齐、失败兜底”。把实时生成也塞进去，后面重连、回放、游标边界都会变得很难解释。

所以更稳的边界是：

- `POST /conversations` 和 `POST /chat` 负责当前 turn 的实时流
- `GET /messages` 继续负责历史补齐和失败兜底

## 这次改造真正要新增什么能力

这里最容易被误解的一点，是“加 SSE”不等于“多写一个流式接口”。

真正需要补的是一条运行时增量输出通道。

当前系统里已经有持久化事件：

- `user_message`
- `final`
- `clarification_needed`
- `conversation_failed`
- `conversation_interrupted`

这些事件适合保存到会话历史里。

但打字机需要的是另一类东西：

- `answer_delta`

它是瞬时的、临时的、只对当前请求有意义的。它不适合直接进持久化层。

所以系统需要两条并行通道：

1. 持久化真相通道
   - 最终把 `final` 写进 store
   - `/messages` 从这里读
   - 页面刷新、切会话都靠它

2. 运行时流通道
   - 当前 turn 正在生成时，把 `delta` 实时推给当前客户端
   - 不写库
   - 这一轮结束连接就关掉

如果把两者混成一条，后面会非常难维护。

## Python 侧应该怎么改

Python 侧真正需要补的，不是单独一个 SSE 路由，而是一条完整的增量输出链路。

### 1. API 层：同一个接口支持 JSON 和 SSE

同一个 `POST /conversations` 和 `POST /chat`，当请求头里没有 `Accept: text/event-stream` 时，继续保持原来的 JSON 模式；当请求头里带了 `Accept: text/event-stream` 时，返回 `StreamingResponse`，在这条响应里持续输出 SSE 事件。

这样旧前端不受影响，支持流式的前端可以直接切新能力。

### 2. 新增 turn 级 stream broker

这里不能直接把 token 级别的内容写进会话表，因为会话历史承担的是“最终真相”和“页面恢复”，不是实时展示。

实时增量应该走内存里的 turn stream broker，只服务当前这一轮请求。最终回答结束以后，再把完整 answer 作为 `final` 写回会话历史。

这条链路可以拆成两层：

- 持久化真相层：保存 `user_message`、`final`、`clarification_needed`、`conversation_failed`
- 运行时流层：输出 `answer_delta`

这样做的好处是，实时流和历史恢复不会互相污染。前端拿流式体验，页面刷新以后还是从 `/messages` 拿完整历史。

### 3. LLM 层要真的支持流式输出

这一层是最容易被低估的。

现在的最终回答阶段，本质上还是先拿到完整 `answer`，再写一条 `final`。这对 JSON 模式没问题，但对 SSE 不够。

要补的不是“把 final 改名”，而是让 LLM 层多出一种能力：

- 非流式：返回完整字符串
- 流式：返回一个异步迭代器，边生成边吐 chunk

这里 chunk 不一定必须是单个 token。只要它是可渐进展示的文本增量就够了。

### 4. Runner 层边收边发，最后再落 final

最终回答生成阶段要改成这样：

1. 调用流式 LLM
2. 每拿到一个 chunk
   - 追加到本地 answer buffer
   - 发布一条 `answer_delta`
3. 全部结束后
   - 用完整 answer 跑 output guardrail
   - 写持久化 `final`
   - 同时给当前 SSE 连接发一条 `final`

这个顺序不能反过来。

不能只发 `delta` 不发 `final`，否则前端断线或者漏了一段以后无法确认最终真相。也不能只发 `final` 不发 `delta`，否则就没有打字机效果。

## Java 网关应该怎么改

Java 侧是这次改造里真正的阻塞点。

当前实现是典型的缓冲代理，不是流式代理。问题不在于用了 `HttpURLConnection`，而在于调用方式是“把上游响应全部读完，再作为字符串返回”。

### 1. Controller 层要支持两种返回模式

JSON 模式还是现在的老逻辑：上游返回完整 body，网关包装成 `ResponseEntity<String>` 返回。

SSE 模式则不能继续返回完整字符串，而应该返回 `StreamingResponseBody` 或者直接写 `HttpServletResponse` 输出流。

也就是说，Controller 不再是“拿到完整字符串再交给 Spring”，而是“把一个持续写数据的回调交给 Spring”。

### 2. Service 层要边读上游边写下游

真正的核心在这里。

流式代理的关键逻辑是：

1. 请求 Python 时把 `Accept` 设成 `text/event-stream`
2. 拿到上游 `InputStream`
3. 不再调用 `readBody`
4. 用固定大小的 byte buffer 循环读取
5. 每读到一块就立刻写到下游 `OutputStream`
6. 每次写完都 flush

伪代码长这样：

```java
HttpURLConnection conn = openConnection("POST", path);
conn.setRequestProperty("Accept", "text/event-stream");
writeRequestBody(conn, requestBody);

StreamingResponseBody body = outputStream -> {
    try (InputStream input = conn.getInputStream()) {
        byte[] buffer = new byte[8192];
        int len;
        while ((len = input.read(buffer)) != -1) {
            outputStream.write(buffer, 0, len);
            outputStream.flush();
        }
    } finally {
        conn.disconnect();
    }
};
```

现在和改造后的最大区别只有一句话：

现在是“读完再返回”，以后是“边读边写”。

### 3. 为什么必须 flush

`write()` 只是把数据写进当前这一层的缓冲区，不代表客户端立刻收到。

`flush()` 的作用是告诉当前这层：这段数据现在就可以往下发了。没有它，很多 chunk 会在中间被攒成一大块，前端看到的就不是打字机，而是隔几秒蹦出来一整段。

### 4. 为什么网关不应该理解 token

Java 网关在这里最合理的职责是：

- 附加认证和业务上下文
- 根据 `Accept` 选择 JSON 还是 SSE
- 无损透传上游字节流
- 正确设置响应头

它不应该自己去解析 `event:`、`data:`，也不应该自己理解 `answer_delta`。

这些事情属于：
- Python 控制面的对外协议
- 前端的消费协议

如果网关自己也开始理解事件内容，协议一改，Java 和 Python 就得一起改，耦合会很重。

## 前端为什么反而最省事

小程序这边已经具备：

- chunk 读取
- SSE 解析
- delta 文本拼接
- 终态收口
- 流式失败自动回退轮询

所以后端只要把协议对齐，小程序基本就能直接用。

真正要做的只是把这些字段稳定下来：

- `answer_delta.data.delta`
- `final.data.answer`
- `clarification_needed.data.question`
- `conversation_failed.data.error`

管理页目前还是轮询模式，这个入口后面可以再单独切流式，不需要和小程序一起强绑上线。

## 这次改造的边界

这里我刻意没有把 `tool_call`、`tool_result`、`react_plan` 这些内部编排事件继续往前端透。

用户真正要的是“答案正在生成”，不是“状态机正在跳转”。

把内部编排对象直接暴露给展示层，前端会和 runtime 结构绑死，后面只要改一次编排，展示协议也要跟着动。更稳的边界是：

- 展示层只吃 `answer_delta + terminal`
- 调试页和日志继续看内部事件

这个拆法更克制，但长期更省事。

## 最后怎么上线

这套方案保留了一个很重要的兜底：`/messages` 不下线。

实时流负责打字机体验，`/messages` 负责历史补齐和断线恢复。流式失败时前端自动退回轮询，页面刷新以后也还能从持久化真相把整段消息拿回来。

这意味着 SSE 只是新增了一条体验通道，不是把整个对话协议推倒重来。

这次改造里，前端不是难点，真正的活在 Java 网关和 Python runtime。一个负责别把流吃掉，一个负责真的把 delta 产出来。只改其中一边，最后都不会有打字机效果。
