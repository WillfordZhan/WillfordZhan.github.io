---
title: "Pi 与 Java MCP：大量工具的渐进式披露"
date: 2026-08-12 17:11:49
categories:
  - "AI"
tags:
  - "Pi"
  - "MCP"
  - "Java Runtime"
  - "Tool Use"
  - "AI工作日志"
source_archive:
  id: "20260812-pi-java-mcp-progressive-tool-disclosure"
  rel_path: "source_materials/posts/20260812-pi-java-mcp-progressive-tool-disclosure"
  conversation_file: "conversation.jsonl"
---

我们准备把 Java MCP 接到 Pi Runtime 上。工具目录未来会按租户、用户和业务权限过滤，但过滤后的工具仍可能很多。把全部 Tool Schema 每轮发给模型，会增加 token 消耗，也会让相似工具之间的选择变得不稳定。

Pi 已经有渐进加载的底层机制：工具可以全部注册在 Registry 中，只把当前 Active Tools 发给模型。这套能力可以复用到 Java MCP，搜索和鉴权边界需要单独接上。

## 现在的 Java Runtime 会暴露全部工具

当前链路很直接：

```text
Java /tools/list
  -> JavaMcpClient.createTools()
  -> 转换为 Pi ToolDefinition[]
  -> createAgentSession(customTools)
  -> 全部 customTools 成为 Active Tools
  -> 全部 Schema 进入模型请求
```

`JavaMcpClient.createTools()` 调用 `/tools/list`，再把每个 Java 工具转换成 `ToolDefinition`。`runtime.ts` 将它们作为 `customTools` 传入 `createAgentSession()`。Pi 会把 custom tools 放进工具注册表，并在当前初始化流程中全部激活。

`noTools: "builtin"` 只禁用 `read`、`bash` 等内置工具，不会让 custom tools 延迟加载。

## Pi 已有的动态工具机制

Pi 内部分开了两个集合：

- Tool Registry 保存所有已注册工具。
- Active Tools 保存下一次模型请求可见的工具。

Extension API 提供 `getAllTools()`、`getActiveTools()` 和 `setActiveTools()`。官方的 Dynamic Tool Loading 示例会先注册所有工具，初始只激活 `tool_search`。模型调用搜索工具后，它在执行期增量激活命中工具。

```text
全部已授权工具 -> Registry
                      -> 初始 Active: tool_search
用户任务            -> tool_search(query)
                      -> 匹配 Top-K
                      -> setActiveTools(当前 + Top-K)
                      -> 下一轮暴露具体 Tool Schema
```

Pi 会对工具执行前后的 Active Tools 做差集，把新增名称记录到 `ToolResultMessage.addedToolNames`。支持原生 Deferred Tools 的 Provider 可以在该 Tool Result 之后插入新 Schema：

- Anthropic 走 `defer_loading` 和 `tool_reference`。
- OpenAI Responses 走 `tool_search_call` 和 `tool_search_output`。

其他 Provider 也能使用动态激活。Pi 会在下一轮正常发送当前完整的 Active Tools，代价是 Provider 的 Prompt 缓存前缀可能失效。

Pi 这层提供动态注册、激活和 Provider 协议适配。搜索算法没有被固化成通用服务，示例里只是简单关键词匹配。

## Java MCP 的最小接入方式

### 1. `/tools/list` 先做授权过滤

`/tools/list` 需要接收与 `/tools/call` 一致的调用人上下文，至少包含租户和用户标识。Java 端按租户能力、用户角色、业务配置得到 filtered tools。

```text
全部工具
  -> 租户可用范围
  -> 用户角色/权限
  -> 当前业务配置
  -> filtered tools
```

这一步决定用户能发现哪些工具。`/tools/call` 仍然要在每次执行前重新鉴权。会话期间的权限可能变化，而且客户端激活状态不能代替服务端授权。

### 2. Pi 只激活搜索入口

filtered tools 仍然全部转成 `ToolDefinition`，先放入 Pi Registry。Session 创建完成后，初始 Active Tools 收缩为 `tool_search`。

Java Runtime 目前通过 SDK `customTools` 注入工具，没有直接得到 Extension 中的 `pi` 对象。最小适配需要让 `tool_search` 在执行时调用当前 `AgentSession.setActiveToolsByName()`。搜索工具仍经过 Pi 的 extension-tool wrapper，因此 Active Tools 的纯增量变化会自动写入 `addedToolNames`，后续 Deferred Tools 链路可以直接复用。

搜索先用工具名、描述、领域和动作标签做 Top-K 匹配。已授权目录大到不适合每个 Session 全量拉取时，再增加 Java `/tools/search`，由服务端同时完成权限过滤和检索。

### 3. 具体工具仍走原来的执行链路

```text
模型调用具体工具
  -> Pi ToolDefinition.execute()
  -> POST /tools/call
  -> Java 重新鉴权
  -> 执行业务能力
  -> 返回 preview + payload
```

现有 `toPiTool()` 已经封装了这条转发链路。渐进披露不要求重写业务工具，也不需要改成一个泛化的 `call_tool(name, args)`。保留具体工具的强类型 Schema，模型在搜索命中后仍能获得参数约束。

## 这次改造的边界

最小变更集中在三处：

1. `/tools/list` 增加调用人上下文和服务端过滤。
2. Java Runtime 注册全部 filtered tools，初始只激活 `tool_search`。
3. `tool_search` 命中 Top-K 后增量激活具体工具。

具体工具的 `/tools/call` 转发保持不变，Java 端补上每次执行的权限复核。初期限制每次搜索的 Top-K，并保持 Active Tools 只增不减，就能用 Pi 现成机制跑通第一版。向量检索和独立工具索引可以等目录规模与召回率数据证明关键词策略不够用时再补。
