---
title: "AI 日志单独落盘这件事，MDC 到底在做什么"
date: 2026-03-20 14:55:00
categories:
  - "AI"
tags:
  - "AI工作日志"
  - "MDC"
  - "Logback"
  - "Java"
  - "AI日志"
source_archive:
  id: "20260320-mdc-logback-ai-chain-routing"
  rel_path: "source_materials/posts/20260320-mdc-logback-ai-chain-routing"
  conversation_file: "conversation.jsonl"
---

最近在收一条 AI 日志链路。诉求不复杂：AI 相关日志要单独落到 `ai-chain.log`，但每行日志尾巴上那串 `[aiChain= aiConversationId= aiToolCallId= aiToolName=]` 太重了，想砍掉大部分字段，最好日志正文里连 `aiChain=true` 都不要看到。

这类问题很容易改着改着偏成“怎么把日志打印得更短”，但代码顺下来以后会发现，核心不在展示，而在分流。当前链路里，`aiChain` 不是给人看的字段，它本质上是日志路由系统用来判断“这条日志该不该进入 AI 专属文件”的信号。

按这次代码现状，最稳的方案不是去猜哪些日志属于 AI，也不是按包名、类名、logger 名做静态规则，而是保留 `aiChain` 在 MDC 里做路由标签，只把它从最终日志文本里拿掉。这样 `ai-chain.log` 还能继续准确分流，日志行也会干净很多。

## 一、先看当前链路到底怎么走

这条链路在代码里分成四段：

```text
AI 请求进入
  -> AiLogContext.openRoot(...) / openToolCall(...)
  -> MDC 写入 aiChain=true
  -> 业务代码正常打日志
  -> Logback 创建 ILoggingEvent
  -> AiChainMdcFilter 读取 event.getMDCPropertyMap()
  -> 命中 aiChain=true
  -> file_ai_chain appender
  -> ai-chain.log
```

对应到这次项目里的关键位置：

- `AiLogContext` 负责把 `aiChain` 放进当前线程的 MDC。
- `AiChainMdcFilter` 负责判断这条日志事件是否属于 AI 链路。
- `logback.xml` 里的 `file_ai_chain` appender 负责把命中的日志写进 `ai-chain.log`。

也就是说，日志能不能进 AI 文件，判断依据不是日志正文，也不是 logger 名称，而是日志事件生成时携带的 MDC 上下文。

## 二、MDC 在这里不是“打印变量”，而是“链路标签”

第一次看 MDC 时，很容易把它理解成“日志里多打几个 `%X{xxx}` 字段”。这个理解只说对了一半。

MDC 更重要的作用，是给当前线程上的日志事件挂一个上下文标签。后面只要还在同一条调用链里，业务代码、共享组件、异常日志打出来时，Logback 都能拿到这份上下文。

放到这次场景里，`aiChain=true` 的职责只有一个：标记这条日志处于 AI 调用链。

它带来的直接好处是，分流逻辑不需要关心“谁在打日志”。无论是 AI 入口类、工具调度器、下游 service，还是复用到的公共组件，只要日志事件仍然携带 `aiChain=true`，`AiChainMdcFilter` 就能把它送进 `ai-chain.log`。

这个能力和“在日志文本里展示一个方括号字段”是两回事。

## 三、为什么“完全自动识别 AI 链路”听起来更高级，实际上更脆

讨论这个问题时，直觉上很容易想到另一条路：既然 `aiChain` 不想展示，那能不能连代码里也别显式打这个标记，让系统自己识别哪些日志属于 AI？

能拼，但不稳。

常见的“自动识别”做法大概就几类：

- 按包路径判断，`com.xxx.ai.*` 都算 AI。
- 按请求 URL 判断，`/api/ai/*` 都算 AI。
- 按 logger 名称判断，像 `ai.tool.invoke` 这种固定 logger 走专属文件。
- 用 AOP 或 ThreadLocal 在某些入口类上包一层。

这些做法的问题都一样：它们识别的是局部位置，不是整条调用链。

一旦 AI 链路里调用了共享 service、DAO、HTTP client 或公共组件日志，这些日志很可能就丢出去了。反过来，如果普通业务复用了 AI 包下面的某个组件，又可能把不该进 `ai-chain.log` 的日志带进去。

所以这次更合理的取舍，不是放弃显式标记，而是把显式标记收敛成一个最小字段：`aiChain`。

## 四、方案 A 到底改了什么

这次最终确定的方案，其实只做两件事：

1. 保留 MDC 里的 `aiChain`，继续用于链路分流。
2. 把日志 pattern 里展示出来的 AI 字段删掉。

如果当前 `logback.xml` 是这样：

```xml
<property name="log.pattern"
          value="%d{yyyy-MM-dd HH:mm:ss} [%thread] %-5level %logger{36} [aiChain=%X{aiChain} aiConversationId=%X{aiConversationId} aiToolCallId=%X{aiToolCallId} aiToolName=%X{aiToolName}] - %msg%n"/>
```

方案 A 改完以后，更接近这样：

```xml
<property name="log.pattern"
          value="%d{yyyy-MM-dd HH:mm:ss} [%thread] %-5level %logger{36} - %msg%n"/>
```

同时 `AiLogContext` 那边也收口，不再往 MDC 里塞 `aiConversationId`、`aiToolCallId`、`aiToolName` 这些重字段，只保留最小路由信号。

这两个动作要一起做。

只改 `logback pattern`，只是“看起来没了”，MDC 里实际上还在继续构造和透传那些字段。只改 `AiLogContext` 不改 pattern，日志格式又会继续尝试展开无意义字段。

## 五、改前改后，日志到底会长什么样

先看一段业务代码：

```java
try (AiLogContext ignored = AiLogContext.openRoot("1001", 2001L)) {
    LOG.info("收到 AI tools/call 请求");
}
```

改之前，日志可能长这样：

```text
2026-03-20 10:00:00 [http-nio-8080-exec-1] INFO  com.xxx.AiMcpEntryService [aiChain=true aiConversationId= aiToolCallId= aiToolName=] - 收到 AI tools/call 请求
```

改之后，日志文本会变成：

```text
2026-03-20 10:00:00 [http-nio-8080-exec-1] INFO  com.xxx.AiMcpEntryService - 收到 AI tools/call 请求
```

关键点在于，这条日志虽然看不到 `[aiChain=true]` 了，但仍然会进入 `ai-chain.log`。原因不是 logger 名碰巧命中，也不是类名带了 AI，而是日志事件创建时，MDC 里仍然有 `aiChain=true`，`AiChainMdcFilter` 读到它以后照样会放行。

再看工具调用链路里另一类日志：

```java
INVOKE_LOG.info(
    "conversationId={} toolCallId={} toolName={} status={}",
    conversationId,
    toolCallId,
    toolName,
    status
);
```

如果这条日志发生在 AI 链路上下文里，改完以后可能会是：

```text
2026-03-20 10:00:02 [http-nio-8080-exec-1] INFO  ai.tool.invoke - conversationId=conv-123 toolCallId=call-456 toolName=query_device status=ok
```

这里要分清两层信息：

- 方括号里的 `%X{...}` 是 MDC 展示字段。
- `conversationId=... toolCallId=...` 这一段是日志正文。

方案 A 只收掉前者，不会自动删除正文里的业务审计信息。

## 六、这条链路真正的流转图

为了排查时更直观，我把这次链路压成了一张图：

```text
+---------------------------+
| 业务入口 / AI 工具调用点   |
| try (AiLogContext ...)    |
+------------+--------------+
             |
             | 1. 写入 MDC
             v
+---------------------------+
| MDC                       |
| aiChain=true              |
+------------+--------------+
             |
             | 2. 业务代码打日志
             v
+---------------------------+
| Logger / LOG.info(...)    |
+------------+--------------+
             |
             | 3. Logback 生成日志事件
             v
+---------------------------+
| ILoggingEvent             |
| 携带 MDCPropertyMap       |
+------------+--------------+
             |
             | 4. AiChainMdcFilter 判断
             |    event.MDC["aiChain"] == "true" ?
             v
+-------------------+       +----------------------+
| 命中               | ----> | file_ai_chain        |
| ACCEPT            |       | 写入 ai-chain.log    |
+-------------------+       +----------------------+
             |
             | 5. 其他 appender 继续各走各的
             v
+---------------------------+
| sys-info.log / console... |
+---------------------------+
```

这张图里最重要的一点，是第 4 步。

`AiChainMdcFilter` 判断的是日志事件里的 MDC，不是最后打印出来的文本。所以你完全可以把 `aiChain` 从日志格式里删掉，同时继续用它做路由依据。

## 七、这次方案的边界和代价

这次做法很稳，但也要说清边界。

第一，它依赖 MDC 能沿着调用链传播。同步链路里问题不大，异步线程池、跨线程执行、某些手动封装任务，如果没有把 MDC 上下文一起透传，日志分流还是会断。这不是 `aiChain` 这个字段的问题，而是 MDC 的通用边界。

第二，它解决的是“AI 链路日志怎么分流到单独文件”，不是“所有 AI 审计字段都从世界上消失”。如果日志正文里仍然主动打印 `conversationId`、`toolCallId`、`toolName`，这些字段还会继续出现在消息内容里。

第三，这个方案刻意没有走“按包名或 logger 名做硬编码规则”。少了点自动感，但换来的是更稳定的链路语义。对这类日志路由问题来说，稳定通常比聪明更重要。

## 八、最后的判断

这次问题看起来像日志格式调整，顺着代码走下来，其实是在做一件更基础的事：把“链路路由标签”和“日志展示字段”拆开。

`aiChain` 保留在 MDC 里，负责告诉 Logback 这条日志是不是 AI 链路。

`log.pattern` 里把它去掉，负责让最终日志行不要再挂一串吵闹的上下文字段。

这两个动作拆开以后，AI 日志分流仍然准确，日志文本也能恢复干净。对这类问题来说，这已经是很合适的收口方式了。
