---
title: "给 AI 调用链单独开一本日志：用 MDC 给入口打标，再让 Logback 分流"
date: 2026-03-12 16:42:30
categories:
  - "AI"
tags:
  - "日志"
  - "Java"
  - "Logback"
  - "MDC"
  - "AI"
  - "复盘"
  - "AI工作日志"
source_archive:
  id: 20260312-ai-mdc-logback
  rel_path: source_materials/posts/20260312-ai-mdc-logback
  conversation_file: conversation.jsonl
---

有些系统的日志看起来很热闹，真正出事时却像在翻一本错页的电话簿。

我这次碰到的是 AI tool call 链路。需求说起来不复杂：希望 AI 触发的一整条调用链，包含内部 service、support、mapper 打出来的 `info` 和 `error`，都能在一个单独文件里找到。麻烦在后半句。那些组件并不专门服务 AI，平时还有普通业务流量在调它们。按包名单独切文件当然省事，代价是非 AI 请求也会一头扎进去，日志很快就搅成一锅粥。

现场先看了一眼现状，系统已经有一个单独文件，名字类似 `ai-tool-invoke.log`。这份日志只记了审计摘要，内容大概是 `conversationId`、`toolCallId`、`toolName`、耗时、参数预览、结果预览。排障时它当然有用，至少知道这次工具被谁调了、跑了多久、成没成功。问题也很明显：这不是“全链路日志”，更像工具调用流水账。业务日志和异常栈还散在原来的 `sys-info.log`、`sys-error.log` 里。你要追一个失败 case，还是得两边来回翻。

那天我脑子里蹦出来的第一个念头很朴素：既然 AI 相关类都在一组包下面，给它们单独配一个 logger 不就完了。这个想法没活过五分钟。AI 入口只是开头，后面会一路穿过普通 service、repo、support、甚至线程池。你不能要求这些共享组件为了 AI 再养一套 logger 名字，更不能因为它们偶尔服务 AI，就把所有非 AI 调用也打进专属文件。这个路子走下去，维护成本会非常丑。

后来收敛到一个更像工程解法的思路：别给组件打标签，给调用打标签。

## 从入口开始打标

要单独收集某一类流量的日志，最省事的办法是让入口先声明：“接下来这条链路属于 AI。”  
这个声明不需要改业务方法签名，也不需要给每个 `log.info()` 手动塞参数，放在 `MDC` 里就行。

`MDC` 全名是 `Mapped Diagnostic Context`。可以把它理解成一张挂在线程上的小纸条，里面写着这次调用的上下文：

```java
try {
    MDC.put("aiChain", "true");
    MDC.put("aiConversationId", conversationId);
    MDC.put("aiToolCallId", toolCallId);
    MDC.put("aiToolName", toolName);
    MDC.put("aiTenantId", tenantId);
    MDC.put("aiUserId", userId);

    return toolDispatcher.dispatch(req);
} finally {
    MDC.clear();
}
```

入口一般放在 `tools/call` 的接入层。那里最早拿得到 `conversationId`、`toolCallId`、`toolName`、租户和用户信息，也最适合做 `try/finally` 清理。线程池会复用线程，这个 `finally` 不能省。漏掉清理以后，后面某个普通请求复用了这条线程，日志里就会凭空多出一串 AI 字段，现场排查会非常魔幻。

做到这一步，后面那些共享组件其实什么都不知道。它们还是原来的写法：

```java
log.info("start query batch");
log.error("query failed", e);
```

区别在于这条日志事件发出来时，当前线程已经带着 `aiChain=true` 和一堆 AI 上下文字段。日志框架识别到这个标签，就能把同一条日志额外复制到 AI 专属文件。

## 为什么 logger 名字不够用

很多人第一次做日志隔离时会先想到 logger 名字。比如：

- `com.example.ai.*` 全打到 `ai.log`
- `ai.tool.invoke` 专门打一份文件

这个思路拿来做“入口审计”没问题，拿来做“共享组件全链路收集”就不够了。

因为调用链通常长这样：

```text
HTTP 入口
  -> Tool Dispatcher
  -> Tool Service
  -> 普通业务 Service
  -> Support / Mapper / DAO
```

共享组件的 logger 名字并不会因为“这次是 AI 来调我”而发生变化。  
它还是那个老 logger。你如果按包名单独切，只能抓到最外层的 AI 类，抓不住链路里实际干活的那些日志。共享组件为了这件事再换一套 logger 名字，代码会被可观测性反向挟持，最后连谁负责判断调用来源都说不清。

所以问题不在 logger name，而在调用上下文。

## Logback 负责分流，不负责猜

入口打完标，后面的事就该交给 logback 了。  
我的建议是保留现有的系统日志文件不动，再额外加一份 `ai-chain.log`。AI 调用时日志会落两份：

- 原来的系统日志照常保留
- `ai-chain.log` 额外收一份 AI 流量

这比直接把 AI 日志从原文件里剔出去稳得多。排障时你有专属视角，原来的值班习惯也不用推倒重来。

logback 这边不要靠包名过滤，直接按 MDC 过滤。思路类似下面这样：

```xml
<appender name="file_ai_chain" class="ch.qos.logback.core.rolling.RollingFileAppender">
    <file>./logs/ai-chain.log</file>
    <filter class="com.example.logging.AiChainMdcFilter"/>
    <encoder>
        <pattern>
            %d{yyyy-MM-dd HH:mm:ss} [%thread] %-5level %logger
            aiConv=%X{aiConversationId}
            aiCall=%X{aiToolCallId}
            aiTool=%X{aiToolName}
            tenant=%X{aiTenantId}
            user=%X{aiUserId}
            - %msg%n
        </pattern>
    </encoder>
</appender>
```

对应的 filter 很小：

```java
public class AiChainMdcFilter extends Filter<ILoggingEvent> {
    @Override
    public FilterReply decide(ILoggingEvent event) {
        String flag = event.getMDCPropertyMap().get("aiChain");
        return "true".equals(flag) ? FilterReply.ACCEPT : FilterReply.DENY;
    }
}
```

这段代码很直接。  
logback 不需要推理“这是不是 AI 类”，它读取 `MDC.aiChain` 就能决定收不收这条日志。

## 这套做法为什么对共享组件侵入低

聊到这里时，一个追问很自然：共享组件同时服务 AI 和非 AI，会不会被侵入得很难看。

按这次拆法，侵入几乎都在外围：

- AI 入口补 `MDC.put`
- dispatcher 补齐 `toolCallId/toolName` 等字段
- logback 新增一个 appender
- 加一个小 filter

共享 service、mapper、support 理论上可以一行不改。  
它们照常用 `@Slf4j`，照常打普通日志。只有当这次调用从 AI 入口进来时，日志事件才会被专属文件额外收走。平时的非 AI 请求没有 `aiChain=true`，日志还是去原来的地方。

这种方式少了一个很烦的维护动作：你不需要挨个判断“这个类算不算 AI 组件”。它在这次链路里被执行了，日志自然会带上 AI 标签。

## 真正会把事情弄乱的地方

方案本身不复杂，坑主要有三个。

### 1. 只有摘要，没有异常栈

系统里经常已经有一份审计日志，记录了工具名、参数预览、结果预览。  
这类日志适合做调用看板，不适合做现场排障。

异常分支只是把 `e.getMessage()` 塞进返回值，而没有单独 `log.error(..., e)` 的话，专属文件里看到的就只有一句“工具执行失败”，没有 stack trace，没有根因，连抛异常的类都看不见。排查时还是得回系统错误日志里翻。

这块要单独补一刀：

```java
try {
    return toolRegistry.invoke(toolName, args, ctx);
} catch (Exception e) {
    AI_CHAIN_LOG.error(
        "tool invoke failed tool={} conversationId={} toolCallId={}",
        toolName,
        conversationId,
        toolCallId,
        e
    );
    throw e;
}
```

### 2. 线程切换以后，MDC 会丢

`MDC` 默认挂在线程上。同步调用时很顺手，线程一切换，标签就可能掉地上。

常见场景有这些：

- `@Async`
- 自定义线程池
- `CompletableFuture`
- MQ 回调
- Reactor / 响应式链路

这类地方如果不做透传，前半段日志在 `ai-chain.log`，后半段突然消失，读起来像日志自己断片了。  
只覆盖同步链路的话，这套方案当天就能上；想把“全链路”几个字写得住，线程池那层迟早得补 `TaskDecorator` 或 MDC 复制包装。

### 3. 参数和结果不能裸奔

既然准备把 AI 链路单独汇总，大家很容易顺手把 `args`、`result`、上下文快照全打进去。  
这事短期排障是爽的，长期会有三个后果：

- 文件量暴涨
- 敏感字段泄露
- 搜索时被大片 JSON 噪音淹没

我比较认同的做法是：

- 摘要日志里保留预览，做长度截断
- 关键 error 分支打印 stack trace
- 真要打完整 payload，单独做脱敏和长度策略

别把 `ai-chain.log` 写成对象储存桶。日志不是归档系统。

## 一版能落地的最小实现

现在就要改的话，我会按下面这个粒度落：

### Phase 1

1. 在 AI 的 `tools/call` 外层入口设置 MDC
2. 在 dispatcher 里补全 `conversationId/toolCallId/toolName`
3. 新增 `ai-chain.log`
4. 用 MDC filter 只接收 `aiChain=true` 的日志
5. 异常分支补完整 stack trace
6. pattern 里带上 `conversationId/toolCallId/toolName`

做到这里，已经能解决大部分“AI 调用了谁、谁报错了、错误栈在哪、同一条链路里还有哪些普通 service 被打到了”的问题。

### Phase 2

1. 处理线程池和异步透传
2. 对 `args/result` 做脱敏和截断
3. 补统一的 AI audit 日志工具
4. 按 `conversationId` 做检索脚本或 Kibana 查询模板

没必要一上来就搞成完整观测平台。先把日志从“到处都是，但哪都不全”改到“至少能在一个文件里还原现场”。

## 延伸问答

### MDC 到底是什么

可以把它当成线程本地的小字条。  
请求一进来，把 `traceId`、`conversationId`、`toolCallId` 这些字段写进去；后续这条线程上的任何日志都能自动带上它们。你不需要在每一行 `log.info()` 里手动拼接。

### 共享组件会不会被 AI 方案绑架

按这次拆法，入口负责打标，日志系统负责分流，共享组件基本无感。  
方案要求你去批量改共享组件的 logger 名字，或者在 service 里到处写 `if (isAiRequest)`，设计就已经跑偏了。

### 为什么不直接建一个 `ai` 包专门打日志

因为真正让人头疼的日志通常不在入口层，而在链路深处。  
AI 类自己当然会打两三条日志，SQL、参数校验、聚合逻辑、异常栈更多时候在共享组件里。只按包名切，日志还是会缺页。

## 收尾

这类需求讨论到最后，核心会落到“调用来源该放在哪里表达”。  
我这次的处理办法比较朴素：来源放在入口上下文里，日志框架只做分流，业务组件继续干业务组件的事。

链路基本同步的话，这套做法已经够用了。  
AI 流量一进来就跨线程、跨任务、跨进程乱窜，光有一个单独文件还不够，还得把上下文透传补完，全链路日志才算成立。
