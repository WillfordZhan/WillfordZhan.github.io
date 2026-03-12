---
title: "MCP、Tool Spec 与 Function Calling：别把三层协议揉成一锅粥"
date: 2026-03-12 10:41:48
categories:
  - "AI"
tags:
  - "MCP"
  - "Function Calling"
  - "Tool Calling"
  - "JSON Schema"
  - "AI Agent"
  - "AI工作日志"
---

## 前言

最近排查一条 AI 工具链路时，最容易把人绕进去的不是模型发疯，也不是某个参数名写错，而是脑子里把三层东西混成了一层：

1. Java 侧维护的 `AiTool / ToolSpec`
2. Python 侧拿到的 `tool list / schema`
3. 模型侧的 `function calling / tool calling`

一开始看起来都像“工具定义”。看久了就会产生一种错觉：既然都有 `name + description + parameters`，那它们应该就是同一个东西，最多换个皮。然后项目就会进入经典状态：

- Java 觉得自己已经做了 MCP
- Python 觉得自己差不多可以直接上 function calling
- 模型则保持了稳定发挥，继续把 `fnCode` 猜成 `furnace_code`

这篇文章把这次排查里最有价值的部分收口一下：MCP、tool spec、function calling 到底分别解决什么问题；它们的 spec 和 schema 差异在哪；什么时候该用哪一层；以及一条已有“类 MCP”工具面系统，应该怎么演进才不会把编排层改成意大利面。

## 一、先给结论：这不是一层东西

一句话版本：

- `ToolSpec` 是你自己系统内部的工具元数据模型
- `Function calling` 是模型 API 的调用协议
- `MCP` 是工具生态的接入协议

如果非要用程序员熟悉的类比：

- `ToolSpec` 像内部 DTO
- `Function calling` 像某个具体 SDK 的请求/响应格式
- `MCP` 更像一个标准化 RPC 协议，顺便把发现、调用、返回、认证这些事也一起规范了

这三者当然会互相映射，但它们不是同一个抽象层级。

## 二、ToolSpec 到底是什么：先别给它加戏

在大多数业务系统里，工具定义最早长这样：

```java
ToolSpec {
  name,
  description,
  parameters: List<ToolParamSpec>,
  result: ToolResultSpec
}
```

参数再继续展开：

- 参数名
- 类型
- 是否必填
- 描述
- 一些业务语义提示，比如：
  - `x-normalizationRule`
  - `x-clarifyTemplate`
  - `x-aliasExamples`

这类对象的职责很朴素：

1. 给后端描述“我有哪些工具”
2. 让调用方知道怎么传参
3. 让校验层知道 required / type / enum
4. 让澄清层知道缺参时该怎么追问

它首先是**你自己系统里的元数据对象**。别一看到 JSON Schema 就给它自动封圣成“OpenAI function calling spec”或者“MCP server spec”。很多团队就是在这一步开始给概念加戏，最后每一层都以为自己是总线。

## 三、Function Calling 解决的是“模型怎么调用工具”

OpenAI、Qwen、Claude 官方对 function calling/tool use 的定义其实很接近：

1. 应用把工具定义传给模型
2. 模型决定要不要调工具
3. 模型生成工具名和结构化参数
4. 应用执行工具
5. 应用把工具结果回传给模型
6. 模型再继续回答

这套流程里，模型最重要的职责不是“帮你把用户问题翻译成 API JSON”这么简单，而是三件事一起做：

- 判断是否需要调用工具
- 选择调用哪个工具
- 根据 schema 生成参数

如果问题需要多个 API 才能回答，官方推荐的模式也不是“自己先手搓 requirement planner 再翻译”。模型可以直接在一个回合里产出多个 tool call，或者由应用显式限制成一次只调用一个，然后循环执行。

一个典型的 function calling tool 定义长这样：

```json
{
  "type": "function",
  "function": {
    "name": "today_furnace_batches",
    "description": "Query furnace batches on a given date",
    "parameters": {
      "type": "object",
      "properties": {
        "fnCode": { "type": "string" },
        "date": { "type": "string" }
      },
      "required": ["fnCode"],
      "additionalProperties": false
    }
  }
}
```

模型返回则会是：

```json
{
  "role": "assistant",
  "content": "",
  "tool_calls": [
    {
      "id": "call_1",
      "type": "function",
      "function": {
        "name": "today_furnace_batches",
        "arguments": "{\"fnCode\":\"1\",\"date\":\"2026-03-12\"}"
      }
    }
  ]
}
```

重点在这里：

- function calling 是**模型 API 协议**
- 它要求你提供工具定义的 envelope
- 它要求你处理 `tool_calls`
- 它不替你执行业务调用

所以 function calling 不是“自动打通外部系统”，而是“让模型按结构化协议参与工具选择”。

## 四、MCP 解决的是“系统怎么标准化暴露和接入工具”

MCP 更像“面向模型生态的标准化 RPC 总线”。

它关心的不是某个模型这一轮怎么产出 `tool_calls`，而是更上游的东西：

- server 怎么暴露能力
- client 怎么发现能力
- tools/resources/prompts 怎么列出来
- transport 怎么走
- auth 怎么做
- 返回内容如何标准化

这就是为什么 MCP 看起来有很重的“RPC 既视感”。这个判断没错，但它比“一个 RPC 方法表”还多包了几件事：

1. **能力发现**
   不是你手工写死每个函数定义，而是 server 把能力对外暴露出来。

2. **统一 spec**
   `inputSchema`、`outputSchema`、content items 这些结构统一了，不用每个系统自己发明一版半吊子 JSON。

3. **统一接入方式**
   工具、资源、提示词都走同一个协议体系，而不是这边一个 HTTP，那边一个 YAML，那边又一段 prompt。

所以如果用 HTTP 类比：

- function calling 更像“某个应用层调用约定”
- MCP 更像“为 AI 工具生态设计的一套标准协议”

这也是为什么很多系统看起来是这样的：

```text
MCP server
   ↓ tools/list
client 拿到 tool spec
   ↓
转成模型能吃的 tools
   ↓
模型用 function calling 生成 tool_calls
   ↓
client 执行调用
```

这不是概念重叠，而是**上下游配合**。

## 五、两者最大的区别，不在“都用 JSON Schema”，而在边界

很多讨论容易卡在一句话里：

> 既然 MCP tool 和 function calling tool 都有 `name / description / schema`，那区别到底在哪？

区别主要在边界。

### 1. Function calling 的边界

它的边界是“模型一次请求里如何使用工具”。

它要解决的问题是：

- 模型看见哪些工具
- 模型怎么输出结构化参数
- 模型什么时候调工具，什么时候直接答

它并不负责：

- 工具是怎么注册出来的
- 工具在哪里发现
- 多个外部系统怎么统一接进来

### 2. MCP 的边界

它的边界是“工具生态如何被客户端和模型系统统一接入”。

它要解决的问题是：

- 一个 client 如何接多个 server
- tool/resource/prompt 怎么统一发现
- schema 怎么对齐
- 调用与返回怎么统一

它并不强制你必须用某个模型厂商的 function calling。

所以你完全可以：

- 用 MCP 暴露 tool list
- 但在客户端继续走 ReAct prompt

也可以：

- 用 MCP 暴露 tool list
- 客户端把它转成 OpenAI/Qwen 的 `tools`
- 再走原生 function calling

这两种都成立。

## 六、工程里最容易踩的坑：看见相似字段就想“直接通”

这次排查里，最有教育意义的坑并不是网络调用失败，而是“格式看起来差不多，于是以为能直接切协议”。

比如某条工具定义在 Python 侧最终长这样：

```json
{
  "name": "today_furnace_batches",
  "description": "Query furnace batches ...",
  "inputSchema": { "...": "..." },
  "parameters": { "...": "..." }
}
```

这已经非常接近 function calling 所需的信息了，但它仍然**不能直接原样喂给 OpenAI-compatible tools**。

原因很简单：

- function calling 要求外层是 `type=function`
- 真正的 schema 应该挂在 `function.parameters`
- `inputSchema` 这种字段名是 MCP / 自定义工具面的语义，不是 OpenAI 工具请求体字段

也就是说，它是：

- **足够好的源数据**
- 但不是**最终请求协议**

这一步只差一个很薄的映射层，却经常被误解成“那我们已经做完 function calling 了”。没有。你只是具备了切过去的条件。

## 七、你现在这类链路，通常处在什么阶段

很多业务系统会自然演进到这个形态：

1. Java 维护工具注册表和 schema
2. Java 暴露 `/tools/list`、`/tools/call`
3. Python 拉工具清单
4. Python 把 schema 塞进 planner prompt
5. LLM 输出一段 JSON 计划
6. Python 再做 tool validate / call / clarify

这个阶段最准确的说法是：

**自研的 MCP-like 工具面 + prompt-based planner**

它有几个优点：

- 工具定义和调用边界已经独立出来
- schema 可以贯穿参数校验和澄清
- 工具执行和模型决策分层比较清晰

但它也有一类固定毛病：

- 模型仍然是在“读 prompt 后吐 JSON”
- 参数名虽然有 schema 参考，但仍可能臆造
- `CALL_TOOL / RESPOND / CLARIFY` 的解析恢复逻辑比较重

这个阶段像青春期，已经不像脚本拼接了，但也没完全长成标准协议客户端。容易说人话，也容易闹别扭。

## 八、什么时候该继续往 function calling 走

不是所有“类 MCP”链路都要马上切 function calling。

更实用的判断标准是看你当前问题集中在哪。

### 适合继续用 prompt planner 的情况

- 已经把完整 tool spec 喂给模型
- 参数校验层足够稳
- 澄清逻辑比较成熟
- 真实问题主要在业务工具本身，而不是 planner 输出质量

这时候继续硬切，收益可能没有你想象中那么高，反而会引入一轮编排层改造。

### 适合切原生 function calling 的情况

- 模型经常瞎编参数名
- 多工具调用经常解析歪
- planner JSON 经常需要恢复和修补
- 你希望把 `CALL_TOOL` 这一支的协议约束交给模型 API 层

这个时候 function calling 的收益会很明显，因为它天然减少“让模型读自然语言工具说明，再猜 JSON 长什么样”的误差。

## 九、推荐演进顺序：别一口气把三层都推倒

对一条已经跑起来的工具链路，比较稳的演进顺序通常是：

### 第一步：先把工具面独立好

先有：

- `tools/list`
- `tools/call`
- 稳定 schema
- Python 侧 tool validation

这一步的目标是：**让工具定义和执行先稳定下来**。

### 第二步：再决定是否切 function calling

如果 prompt planner 已经经常出现这些问题：

- 猜错参数名
- tool_calls 结构漂移
- 恢复逻辑越来越重

那就切原生 function calling，把“工具选择与参数生成”交给模型 API 协议层。

### 第三步：如果真要跨客户端复用，再补完整 MCP

只有当你真的有这些需求时，再考虑把工具面继续做成更标准的 MCP server：

- 想让不同模型/IDE/客户端共用同一套工具
- 想让 tools/resources/prompts 都走统一接入层
- 想减少自定义适配层

很多团队的问题不是没有 MCP，而是**太早把“类 MCP 工具面”当成“完整 MCP 平台”来设计**。然后项目没先解决参数正确性，先多长了三层抽象。

## 十、一个足够实用的判断法

最后给一个简单判断法，排查时很省脑子。

如果你看到的是：

- `name`
- `description`
- `inputSchema`
- `parameters`

先问自己两个问题：

1. 这是**工具元数据**，还是**模型请求协议**？
2. 这是在解决**工具接入问题**，还是在解决**模型调用问题**？

如果回答是：

- 工具元数据
- 工具接入问题

那它更像 `ToolSpec / MCP-like tool descriptor`

如果回答是：

- 模型请求协议
- 模型调用问题

那它才更像 function calling 的 `tools`

把这两个边界想清楚，很多架构讨论会瞬间从“玄学互喷”降级为“正常工程交流”。

模型不会因此变聪明，但人会少在群里打架。

## 延伸问答

### 1. MCP 是不是就是 RPC？

可以这么理解，但别只理解到“有个 list 和 call”。MCP 还把 resources、prompts、transport、auth 这些配套语义一起标准化了，所以它比普通 RPC 方法表更完整。

### 2. MCP 和 function calling 是不是二选一？

不是。很常见的做法就是：

- 上游用 MCP 暴露工具
- 下游把 MCP tool spec 转成模型 `tools`
- 模型走 function calling

两者经常是上下游关系。

### 3. 有了完整 tool spec，是不是就可以直接切 function calling？

不完全是。你通常还要补：

- request 侧 `tools` 包装
- response 侧 `tool_calls` 解析
- 编排层从“文本 JSON 计划”切到“工具调用协议 + 普通文本回复”的分流

真正的工作量往往不在 schema，而在 orchestration。

## 参考资料

- OpenAI Function Calling Guide  
  https://developers.openai.com/api/docs/guides/function-calling
- OpenAI MCP Guide  
  https://developers.openai.com/api/docs/mcp
- Model Context Protocol Introduction  
  https://modelcontextprotocol.io/docs/getting-started/intro
- Model Context Protocol Specification  
  https://modelcontextprotocol.info/specification/
- Qwen Function Calling  
  https://qwen.readthedocs.io/en/stable/framework/function_call.html
- Anthropic Tool Use / MCP Connector  
  https://platform.claude.com/docs/en/agents-and-tools/tool-use/implement-tool-use  
  https://platform.claude.com/docs/en/agents-and-tools/mcp-connector
