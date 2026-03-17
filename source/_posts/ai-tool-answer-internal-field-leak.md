---
title: "AI Tool 回答为什么会泄漏内部字段名"
date: 2026-03-17 20:05:27
categories:
  - "AI"
tags:
  - "AI"
  - "Agent"
  - "MCP"
  - "Prompt"
  - "复盘"
  - "AI工作日志"
source_archive:
  id: 20260317-answer-data-field-leak
  rel_path: source_materials/posts/20260317-answer-data-field-leak
  conversation_file: conversation.jsonl
---

这次踩坑点不在工具调用本身，而在回答阶段。

链路里工具已经查到了正确数据，`tool_call -> tool_result` 也没问题，最后给用户的 `final` 还是把内部字段名说了出来，比如：

- `furnacePlans`
- `ladleBatchCountTarget`

这类字段名即使业务含义没说错，也不该出现在用户可见回答里。问题不是“模型不懂业务”，而是我们把不该给它看的东西也一并塞进了回答上下文。

## 现场是什么样

联调时有一轮真实对话是这样的：

```text
我：计划炉次有多少

Assistant：
根据已有信息，9号炉今日（2026年3月17日）的生产计划中未安排任何炉次：
- `furnacePlans` 字段为空数组；
- `ladleBatchCountTarget`（目标包次数量）为 0；
- 计划内容仅为“炉前上班自动创建计划”，无具体炉次配方、铁水重量等执行细节。

因此，该计划当前计划炉次数量为 0。
```

用户真正想问的是“现在有没有计划炉次、数量是多少”，这轮回答里已经把正确结论说出来了，但同时也把内部字段名带给了用户，还顺手补了一些工具结果里并没有明确给出的说明。

当时的日志大概长这样：

```text
llm_completion mode=loop output=根据已有信息，今日生产计划中未安排任何炉次：
- `furnacePlans` 字段为空数组
- `ladleBatchCountTarget` 为 0
...
```

工具结果并没有报错，模型也没有编造一个完全不存在的数据。它只是把内部 key 原样带进了自然语言回答。

这类问题在调 Agent 时很容易被误判成“prompt 不够强”或者“schema 描述还不够细”。这两个方向都能缓解一点，但收不住。

## 为什么 prompt 补丁收不住

这套链路当时的做法大致是：

1. Java MCP 返回工具结果。
2. Python 编排层把 `tool_result.result` 连同 `output_schema` 一起塞进回答 prompt。
3. 回答模型根据这些内容生成 `final`。

这里最麻烦的地方在第 2 步。

回答模型看到的不是“已经整理好的用户可见事实”，而是原始结果对象。只要原始对象里还带着：

- `furnacePlans`
- `ladleBatchCountTarget`
- `planId`
- `statusName`

模型就有机会把这些字段名直接带进最终回答。

`output_schema.title/description` 在这条链里只是参考信息，不是硬边界。它能帮模型理解字段含义，但不能阻止模型引用原始 key。

所以这里补再多类似下面的规则，效果都不稳定：

- 不要输出内部字段名
- 优先按 title 回答
- description 只做辅助解释

这些规则都建立在同一个前提上：模型已经看到了内部字段名，然后希望它自觉别说出来。

## 当前方案为什么还会漂

这次问题里其实有两种不同症状。

第一种是字段泄漏。

比如直接说：

- ``furnacePlans``
- ``ladleBatchCountTarget``

这属于边界没收住。

第二种是语义扩写。

比如把一个内部字段改写成更长的业务表述，或者在空数组场景下顺着领域常识往外补一串“可能存在的字段”。这个问题和字段泄漏不是一回事，但根子一样：回答模型看到了原始结构。

字段泄漏更靠前，也更该先解决。只要这层没收住，后面的语义约束再细都不稳。

## 比较稳的解法

这次更靠谱的改法不是继续往 prompt 里叠限制，而是改返回契约，把规划和回答彻底分开。

工具结果分成两份视图：

- `planData`
- `answerData`

`planData` 保留原始 key，给编排和后续工具链用。这里可以继续带：

- `planId`
- `status`
- `furnacePlans`
- 各种内部 id、码值、marker

`answerData` 单独做成回答专用视图。这里不再保留原始字段名，直接把对象 key 转成 `ToolField.title`，再附一份 `title -> description` 的语义说明。

结果就从：

```json
{
  "statusName": "生产中",
  "furnacePlans": [],
  "ladleBatchCountTarget": 0
}
```

变成：

```json
{
  "answerData": {
    "计划状态": "生产中",
    "计划炉次": []
  },
  "answerSchema": {
    "计划状态": "计划状态中文名称，例如待生产、生产中、生产完成",
    "计划炉次": "计划下的炉次安排摘要"
  }
}
```

回答模型拿到的是已经转义好的结果，原始字段名根本不存在。字段泄漏问题会一下子简单很多。

## 这套拆法解决了什么

先解决的是“不能说什么”。

只要回答模型不再看到原始 key，它就没法把：

- `furnacePlans`
- `ladleBatchCountTarget`
- `planId`
- `recipeId`

原样带进 final。

同时它也顺手解决了一个老问题：同一个 tool result 给规划节点和回答节点混用，导致职责边界一直不清楚。

拆完以后职责很直：

- 规划节点吃 `planData`
- 回答节点吃 `answerData`

这比让 Python 在回答阶段临时猜“哪些字段该展示、哪些字段不该展示”省事很多，也更稳。

## 这套方案的代价

代价也很明确，主要在 Java 这一层。

首先，工具结果不能再只是“把 VO 丢给 Jackson 转 JSON”就结束了，得多做一层投影。

其次，`ToolField` 不能只承担可见性，还要承担回答语义：

- `title`
- `description`
- 哪些字段只给规划看
- 哪些字段可以进回答视图

再往后走，数组、嵌套对象、空集合怎么表达，也要统一约束。比如：

- `计划炉次=[]` 到底保留空数组，还是提前转成“当前尚无具体炉次安排”

这些都不复杂，但它们需要在一层统一能力里做，不适合分散到每个 tool 手工拼。

## 最后还要留一层兜底

即使把 `answerData` 做出来，我还是会留一层 final sanitizer。

原因很简单，回答模型仍然是自由生成文本。它可能不再泄漏原始 key，但仍可能把一些内部痕迹带出来，比如：

- 反引号包裹的字段样式
- `status=1`
- `[]`
- `key=value`

所以更稳的链路应该是：

1. Java 工具返回 `planData + answerData`
2. Python 回答阶段只看 `answerData`
3. final 落库前再跑一轮字段泄漏检查

前两步解决主问题，最后一步负责兜底。

## 这类问题以后怎么判断

我现在会先看一句话：

回答模型看到的，到底是“原始 DTO”，还是“已经整理过的用户可见事实”。

只要答案还是前者，字段泄漏、术语漂移、空数组乱扩写这类问题就会反复出现。区别只是这次漏的是 `furnacePlans`，下次可能换成别的 key。

这次把回答视图单独拆出来，工程上会更重一点，但这类问题后面会少很多。
