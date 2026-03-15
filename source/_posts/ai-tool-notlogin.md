---
title: "AI Tool 调用里的 NotLogin 排查与线程级登录态注入"
date: 2026-03-15 17:51:19
categories:
  - "AI"
tags:
  - "Java"
  - "Sa-Token"
  - "MCP"
  - "问题排查"
  - "线程上下文"
  - "AI工作日志"
source_archive:
  id: 20260315-ai-tool-notlogin-thread-login-context
  rel_path: source_materials/posts/20260315-ai-tool-notlogin-thread-login-context
  conversation_file: conversation.jsonl
---

最近在一条 AI tool 调用链路里碰到一个典型问题：工具本身是从 Python 调 Java MCP，再进入 Java 里的业务 service，但执行到查库阶段时抛了 `NotLoginException`。表面看像是工具参数没带全，实际排下来，问题不在参数，而在历史业务代码对登录态的隐式依赖。

这次排查最后没有把整条链路改造成显式上下文传递，而是先做了一个线程级 `LoginUser` 注入的兼容方案。这个方案不够“理想”，但能在不污染真实登录会话的前提下，把 AI tool 跑通。

## 问题怎么出现的

AI tool 调用日志里能看到工具执行失败，错误信息大致是这样：

```text
nested exception is org.apache.ibatis.exceptions.PersistenceException:
### Error querying database.
Cause: cn.dev33.satoken.exception.NotLoginException: 未能读取到有效Token
```

一开始很容易怀疑两件事：

1. Python 调 Java MCP 时是不是没把用户 token 透传过去。
2. 工具执行时是不是 tenantId、userId 一类的业务上下文缺了。

但继续看调用链后，问题并不是这两类。

## 先把链路拆开看

当时这条链路大致是：

1. Python 收到 AI tool call。
2. Python 调 Java MCP 的 `tools/call`。
3. Java MCP 根据最小 caller context 构建 `AiRunContext`。
4. dispatcher 调 `toolRegistry.invoke(...)`。
5. tool 再进入共享业务 service。
6. 深层 service / mapper 查询时抛 `NotLoginException`。

这里有一个关键事实：Python 调 Java MCP 时，只传了最小 caller context，也就是 `tenantId` 和 `userId` 一类信息，没有把真实用户 Bearer token 一路透传下去。

这本来不是 bug，而是当前设计本来就这样。问题出在更深一层：Java MCP 已经有了 AI 运行时上下文，但下游不少历史业务代码并没有显式消费这个上下文，而是继续隐式依赖 Sa-Token 当前线程里的登录态。

## 根因不在 Python，而在 Java 存量代码的登录态假设

后面把 Java 侧调度和业务调用链串起来之后，问题就比较清楚了。

MCP dispatcher 自己做的是：

- 标准化 `conversationId`、`toolCallId`
- resolve runtime scope
- 执行 tool

它并没有恢复一段线程内登录态。也就是说，进入 tool 时有 `AiRunContext`，但没有“当前登录用户”。

而历史业务代码里还存在大量这种调用方式：

- `LoginHelper.getLoginUser()`
- `LoginHelper.getUserId()`
- 更糟一点的还会走 `StpUtil.checkLogin()` 或 `StpUtil.getLoginIdAsString()`

这类代码的问题不在于当时没意识到要显式传 userContext，而是系统历史上本来就是靠隐式登录态跑起来的。现在 AI tool 这条内部调用链不走传统 Web 登录入口，原来的假设自然就不成立了。

换句话说，这不是一次“忘了传 userId”的低级错误，而是历史设计包袱在 AI 场景里暴露出来了。

## 一开始为什么没直接走 run-as login

最直接的修法其实是：在 dispatcher 执行 tool 之前，临时构造一个 `LoginUser`，再调用 `StpUtil.login(...)` 或 `LoginHelper.loginByDevice(...)`，把当前线程伪装成一个已登录用户。这样老代码里依赖 `checkLogin()` 的地方也能跑通。

这个方案我一开始也试了，而且从兼容性上说它最稳。

但它的问题也很明显：

1. 本质上还是做了一次 Sa-Token login。
2. 会建立一段 token / token-session。
3. 默认会走 Sa-Token 的持久化逻辑，通常会落到 Redis。
4. 这更像“兼容旧系统”，不是一个干净的 AI tool 运行时方案。

如果只是为了让一条内部工具调用临时拿到用户对象，这个代价偏大了。

## 这次落地的方案：线程级注入 LoginUser

最后采用的做法更克制一些：不做 `StpUtil.login`，只在 tool 执行线程里临时注入一个 `LoginUser`。

核心思路是：

1. dispatcher 先根据 `sysUserId` 查出 `SysUser`。
2. 用现有 `LoginSupport.buildLoginUser(...)` 构建标准 `LoginUser`。
3. 只往 `SaHolder.getStorage()` 里塞 `loginUser`。
4. 执行真正的 tool 逻辑。
5. 在 `finally` 里把线程内 `loginUser` 清掉。

伪代码大概是这样：

```java
LoginUser loginUser = loginSupport.buildLoginUser(user);
SaHolder.getStorage().set(LoginHelper.LOGIN_USER_KEY, loginUser);
try {
    return action.get();
} finally {
    SaHolder.getStorage().set(LoginHelper.LOGIN_USER_KEY, null);
}
```

这个方案能覆盖什么，不能覆盖什么，要说清楚。

能覆盖的：

- `LoginHelper.getLoginUser()`
- `LoginHelper.getUserId()`
- `LoginHelper.getDeptId()`
- 其他基于线程内 `loginUser` 的旧逻辑

不能覆盖的：

- `StpUtil.checkLogin()`
- `StpUtil.getLoginIdAsString()`
- 直接依赖 token-session 的逻辑

这次之所以能这么收，是因为排查后确认当前这条业务链路里没有直接调用这些更重的 Sa-Token API。

## 为什么这个方案更适合当前场景

它不是完美方案，但在当前约束下更合适。

第一，它不会污染真实登录会话。  
只注入线程级 `loginUser`，不建 token，不写 token-session，也不碰 Redis 里的真实在线用户数据。

第二，它只影响当前执行线程。  
工具执行完就清理，不会把一段“假登录态”扩散到系统级别。

第三，它和现有历史代码的耦合点刚好对上。  
既然问题点主要集中在 `LoginHelper.getLoginUser()` 这类隐式读取，那就先用最小代价补这一层，不先动更大的业务面。

## 并发和线程池的问题怎么看

这种线程级注入有一个天然边界：它只在当前线程有效。

这意味着两件事：

1. 如果 dispatcher 同步执行 tool，这个方案是安全的。
2. 如果后面改成线程池异步执行，也不是不能用，但注入动作必须发生在真正执行 tool 的工作线程里，而不是提交任务的父线程。

它不会自动跨线程传播，这其实是好事。默认不传播，至少比错误传播更安全。真正需要跨线程时，再按具体异步点显式处理。

## 顺手还修了一层日志问题

这次排查还有一个副产品：tool 调用里的异常链路原来有被反射调用抹平的风险。

原因是 tool 执行通过 `Method.invoke(...)`，而执行异常又在 `ToolRegistry` 里被直接吃成了 `ToolResult.fail(...)`。这样最终日志里容易只看到一个错误摘要，看不到真正的业务异常栈。

后面把这层也收了一下：

- `ToolMethod.invoke(...)` 里解包 `InvocationTargetException`
- 参数绑定错误继续在 `ToolRegistry` 里转成稳定错误码
- 真正的业务执行异常统一往上抛
- 最终由 `AiMcpToolDispatcher` 统一打完整异常栈，并统一转成对外响应

这样排查体验会好很多。至少日志里能看到真实业务方法栈，而不是只停在反射层。

## 这次方案的定位

这次的线程级 `LoginUser` 注入，我把它视为一个兼容层，而不是最终架构。

更理想的状态应该是：

- AI tool 链路显式消费 `AiRunContext`
- 共享业务逻辑逐步减少对 `LoginHelper` 和 Sa-Token 当前线程态的隐式依赖
- 最终让 AI 内部调用和传统 Web 登录态彻底解耦

但这类历史设计问题很少适合一次性推平。改造成本不小，风险也不低。既然当前目标是先把 AI tool 调通，同时别污染真实登录会话，那么线程级注入 `LoginUser` 是一个可以接受的中间方案。

它不优雅，但足够克制，也足够实用。
