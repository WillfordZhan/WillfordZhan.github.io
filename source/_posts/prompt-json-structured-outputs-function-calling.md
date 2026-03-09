---
title: "别再靠 Prompt 硬劝模型吐 JSON：Structured Outputs、Function Calling 与国产模型能力盘点"
date: 2026-03-09 09:52:00
categories:
  - "AI"
tags:
  - "Structured Outputs"
  - "Function Calling"
  - "JSON Schema"
  - "Prompt Engineering"
  - "Qwen"
  - "Kimi"
  - "GLM"
  - "DeepSeek"
  - "AI工作日志"
---

## 前言

很多团队第一次做结构化输出，都会写出一句极其熟悉的咒语：

```text
请严格输出 JSON，不要解释
```

然后几轮之后，程序收到的内容往往是：

- 一坨长得像 JSON 但少了逗号的文本
- 一个合法 JSON，但字段缺了一半
- 一个字段结构没问题，但值一本正经地胡说八道

这不是模型跟你作对，这是你把三件不同的事混在了一起：

1. `Prompt 约束`
2. `Structured Outputs / JSON mode`
3. `Function calling / tool calling`

这篇文章就是把这次对话里最有价值的部分整理成一版工程化说明：它们到底有什么区别，`Structured Outputs` 为什么能“强制”模型按 schema 出参，为什么生产上必须显式开协议参数，以及国产模型这一圈大致支持到什么程度。

## 一、先把概念摆平：这四层不是一个东西

很多讨论一上来就把“输出 JSON”“结构化输出”“工具调用”混着说，最后越说越像玄学。实际上可以把它们分成四层：

| 方式 | 保证什么 | 保证强度 | 本质 |
| --- | --- | --- | --- |
| 纯 Prompt 约束 | 最多是“尽量按你说的来” | 低 | 靠模型自觉 |
| JSON Mode | 输出是 JSON | 中 | 只约束格式 |
| Structured Outputs | 输出符合指定 JSON Schema | 高 | 解码阶段受约束 |
| Function Calling | 输出符合工具参数 schema，并进入工具调用协议 | 高 | 结构化输出的“可执行版” |

一句话记忆：

- `Prompt` 是劝人
- `JSON Mode` 是要求穿工服
- `Structured Outputs` 是把轨道焊死
- `Function Calling` 是不仅焊轨道，还规定必须开去哪个车站

## 二、Structured Outputs 到底怎么“强制”模型吐合法 JSON

这个问题最容易被误解成“是不是 prompt 工程更强了”。答案很直接：**不是。**

真正起作用的是两层能力叠加：

1. 模型训练层  
   模型被训练得更理解 schema、字段名、类型、枚举、`required`、嵌套对象这些结构约束。
2. 解码约束层  
   运行时把 schema 转成 grammar，在每一步生成 token 时，屏蔽所有会导致结构非法的候选 token。

工程视角下，可以把它理解成这样：

```text
用户输入 + JSON Schema
        ↓
系统把 Schema 编译成 Grammar
        ↓
模型逐 token 生成
        ↓
每一步只允许“仍可能导向合法 JSON”的 token
        ↓
非法路径直接被剪掉
```

这和“先生成一坨文本，再拿 Pydantic / JSON Schema 校验，不行就 retry”有本质区别。

后者是：

```text
先自由生成
再发现不对
再补锅
```

前者是：

```text
从第一个 token 开始就不让它跑偏
```

差别看一个最小例子就够了：

```json
{
  "type": "object",
  "properties": {
    "status": {
      "type": "string",
      "enum": ["ok", "error"]
    },
    "code": {
      "type": "integer"
    }
  },
  "required": ["status", "code"],
  "additionalProperties": false
}
```

如果模型已经输出到：

```json
{"status":
```

那下一步就不应该还能随手冒出 `"message"`、`}`、或者 `"success"` 这种不在 `enum` 里的值。受限解码做的就是这件事：把这些非法路径当场掐掉。

所以 `Structured Outputs` 的“强制”，不是“模型更听话”，而是“服务端根本不让它走非法路径”。

## 三、为什么 JSON Mode 还不够

`JSON Mode` 的价值当然有，但它解决的是“长得像 JSON”，不是“符合你的业务结构”。

例如你希望模型返回：

```json
{
  "status": "ok",
  "code": 200
}
```

在 `JSON Mode` 下，这种结果也是合法的：

```json
{
  "status": "ok"
}
```

没报错，能 parse，括号也对，但它仍然是错的，因为：

- 缺了必填字段 `code`
- 可能多出未定义字段
- 类型可能不对
- 枚举值可能漂移

所以老套路通常是：

1. prompt 强约束
2. 模型输出后再校验
3. 校验失败就重试

而 `Structured Outputs` 把校验这件事前移到了生成阶段，重试次数和脏数据量都会明显下降。

## 四、为什么不能只靠 Prompt 暗示，必须显式开启

这也是这次对话里最值得拿出来单独强调的一点：**结构化输出和 function calling 在工程上都应该显式开启，不能只靠 prompt 暗示。**

原因很简单。

如果你不传任何额外 API 参数，只在 prompt 里写：

```text
请输出 JSON
请调用 weather 函数
```

服务端其实并不知道你要启用哪条协议路径。它只知道你写了一段自然语言要求。

而显式开启的方式通常是：

结构化输出：

```json
{
  "response_format": {
    "type": "json_schema",
    "json_schema": {
      "name": "weather_result",
      "strict": true,
      "schema": {
        "type": "object",
        "properties": {
          "city": { "type": "string" },
          "temperature": { "type": "number" }
        },
        "required": ["city", "temperature"],
        "additionalProperties": false
      }
    }
  }
}
```

Function calling：

```json
{
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Query weather by city",
        "parameters": {
          "type": "object",
          "properties": {
            "city": { "type": "string" }
          },
          "required": ["city"]
        }
      }
    }
  ]
}
```

可以把它理解成：

- `prompt = 意图说明`
- `response_format / tools = 真正开启协议`

Prompt 当然还有用，但它是辅助稳定输出，不是协议开关。

## 五、它也不是魔法：保证边界要讲清楚

`Structured Outputs` 很强，但别把它吹成“从此不需要兜底”。

它能强保证的是：

- JSON 语法合法
- 结构符合 schema
- 必填字段、类型、`enum`、层级关系受控

它不能天然保证的是：

- 值一定真实
- 业务规则一定正确
- 外部世界状态一定没变

此外还有几个边界要单独处理：

1. schema 支持范围有限  
   很多厂商只支持 JSON Schema 的子集，不是所有特性都能无损表达。
2. refusal  
   触发安全策略时，模型可能拒答，而不是继续给你业务 JSON。
3. truncation  
   `max_output_tokens` 太小，输出可能还没结束就被截断。
4. tool interruption  
   tool call 链路是多阶段协议，不是“参数合法”就等于业务闭环已经成功。

所以真正的生产范式通常是：

```text
Structured Outputs / Function Calling
    + 本地 schema 校验
    + refusal / 截断分支处理
    + 外部数据源校验
    + 业务规则校验
```

别让 schema 替你背业务正确性的锅。它背不起。

## 六、国产模型大致支持到什么程度

这次对话顺手把几家常见模型的公开能力也梳理了一遍。按 2026-03-09 能从官方公开文档确认到的信息，大致可以这样记：

| 厂商 / 模型 | Structured output | Function calling / tool calling | 备注 |
| --- | --- | --- | --- |
| Qwen | 支持 `json_object`，也支持 `json_schema`，且有 `strict: true` | 支持 | 公开文档里最接近 OpenAI `Structured Outputs` 语义的一档 |
| Kimi / Moonshot | 可确认 `JSON Mode` | 支持 `tools / tool_calls` | 官方文档强调 `tool_calls`，不是旧 `functions` |
| GLM / 智谱 | 可确认 JSON 输出与结构化输出能力 | 支持 | 从公开文档能确认支持，但具体严格 schema 能力要按模型页细看 |
| DeepSeek | 可确认 `JSON Output` | 支持，且 function calling 有 `strict mode` | 严格约束更多体现在函数参数 schema 上 |
| MiniMax | 公开文档可确认 function calling | 本轮未查到足够明确的 `json_schema` 类公开说明 | 谨慎起见，不建议默认当成强 schema 输出来设计 |

如果你只想记结论：

- 最看重强 schema 结构化输出：优先看 `Qwen`
- 最看重工具调用：`Qwen / Kimi / GLM / DeepSeek` 都可以进入候选
- 想把函数参数约束得更严：重点看 `Qwen` 和 `DeepSeek strict mode`
- `MiniMax` 至少先按“工具调用可用”来接，结构化强保证不要脑补

## 七、落地建议：别写成“看起来高级，实际全靠重试”

如果你在做 Agent、工作流编排、SaaS 查询助手，下面这套做法最稳：

1. 需要结构化数据时，显式传 `response_format`
2. 有明确字段约束时，优先传 `json_schema`
3. 要调工具时，显式传 `tools`
4. 给工具参数写清楚 `description + parameters schema`
5. Prompt 里补充字段说明、示例和工具使用规则
6. 业务侧保留本地 schema 校验和异常分支处理

不要把下面这种写法当生产方案：

```text
请你务必严格输出 JSON，不许废话，如果格式错了你自己修复
```

这不是协议设计，这是把程序正确性寄托在模型当天心情上。

## 八、一句话总结

最准确的结论其实很朴素：

`Structured Outputs` 能强制模型按 schema 输出，不是因为 prompt 更凶，而是因为系统在解码阶段就把非法 token 路径剪掉了；`Function Calling` 则是在这套结构化能力上，再叠加了一层工具调用协议。

工程上真正可靠的范式从来不是“靠 prompt 暗示”，而是：

```text
显式开启协议参数
    + 合理设计 schema
    + 用 prompt 做辅助约束
    + 业务层继续兜底
```

这套组合拳看起来不浪漫，但很适合线上系统。毕竟线上故障从来不会因为你写了“请严格输出 JSON”就心软。

## 参考

- 对话原始整理：https://chatgpt.com/share/69ae273c-5fb0-8013-8ff9-c94347f4d466
- OpenAI Structured Outputs：https://platform.openai.com/docs/guides/structured-outputs
- OpenAI Introducing Structured Outputs：https://openai.com/index/introducing-structured-outputs-in-the-api/
- Qwen 结构化输出：https://help.aliyun.com/zh/model-studio/qwen-structured-output
- Kimi JSON Mode：https://platform.moonshot.cn/docs/guide/use-json-mode-feature-of-kimi-api
- Kimi Tool Calls：https://platform.moonshot.cn/docs/guide/use-kimi-api-to-complete-tool-calls
- DeepSeek JSON Output：https://api-docs.deepseek.com/guides/json_mode
- DeepSeek Function Calling：https://api-docs.deepseek.com/guides/function_calling
- GLM 开放文档首页：https://docs.bigmodel.cn/
- MiniMax 开放平台文档首页：https://platform.minimax.io/
