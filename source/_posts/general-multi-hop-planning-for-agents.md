---
title: "别再让 Agent 靠感觉停下来了：聊聊通用多跳规划能力怎么做"
date: 2026-03-17 20:35:00
categories:
  - "AI"
tags:
  - "AI"
  - "Agent"
  - "MCP"
  - "Function Calling"
  - "架构"
source_archive:
  id: 20260317-general-multi-hop-planning-for-agents
  rel_path: source_materials/posts/20260317-general-multi-hop-planning-for-agents
  conversation_file: conversation.jsonl
---

最近在调一条生产计划问答链时，碰到一个很典型的问题。

用户问的是“今天计划炉次有多少”，系统却在第一跳 `production_plan_search` 后就停了，直接把计划列表里的 `count/total` 当成了答案。真正需要的链路其实是：

1. 先查计划，定位目标计划。
2. 再查计划详情。
3. 最后基于详情里的计划炉次做汇总。

这个问题看起来像“模型不够聪明”，但本质不是。更准确地说，是系统没有把“当前要回答什么”“现有证据够不够”“不够时下一步该补什么”做成显式能力。

## 为什么 Agent 会在第一跳就停下来

这类问题一般不是单点故障，而是几层因素叠在一起。

第一层是第一跳结果看起来“很像答案”。

如果一个工具叫 `production_plan_search`，返回里又有 `count`、`total`、`items`，模型很容易把它理解成“已经拿到了足够的统计结果”。但实际上，这个工具只能回答“有几个计划”“有哪些计划”，并不能回答“某个计划里有多少个计划炉次”。

第二层是 planner 的停机条件太宽。

很多系统都会给模型一条类似的规则：如果证据已经足够，就直接回答，不要继续调工具。这条规则本身没错，问题在于“证据是否足够”如果完全交给模型自己判断，它往往会选择最短路径，而不是最稳路径。

第三层是没有把“缺什么证据”做成运行时对象。

对于“计划炉次有多少”这类问题，真正的回答证据应该来自计划详情，而不是计划列表。也就是说，这类问题的完成条件不是“拿到 search result”，而是“拿到 detail result 里的炉次字段或炉次计数”。如果系统没有把这个完成条件显式表达出来，模型就会用自己看到的第一份结构化结果尽快收尾。

## 这不是某一句 query 的问题

如果只盯着“今天计划炉次有多少”这一句，很容易走到一个错误方向：给这句话写一条 if/else，或者在 prompt 里专门补一条规则。

这种做法短期能压住一个 case，但很快会失效。因为用户下一次可能会问：

- 今天这个计划的炉次安排数量是多少
- 这个生产计划下有几炉
- 当前计划一共排了多少个炉次
- 今天 9 号炉的计划里现在有几炉

这些问题在业务上是同一种意图，但文本不一样。如果靠 query patch，一定会越写越碎。

所以更合理的做法不是“修一句话”，而是把多跳规划能力做成系统能力。

## 业界更稳的通用方案是什么

如果把官方文档和企业 Agent 实践放在一起看，更稳的方向不是给工具补越来越多的 follow-up 规则，而是把多跳过程拆成四个独立能力：

1. 先产出显式计划
2. 再执行取证动作
3. 然后校验证据是否足够
4. 不够就重规划，够了再回答

这条路线的核心不是“哪把 tool 后面通常接哪把 tool”，而是“当前缺哪种证据，就继续补哪种证据”。

这比工具耦合更泛化，因为真实多跳并不总是固定的 `search -> detail`：

- 有的是 `list -> detail -> aggregate`
- 有的是 `entity_resolve -> metric_query -> summarize`
- 有的是 `compare(A) + compare(B) -> reconcile`
- 有的是 `kb -> business_tool -> answer`

如果系统只能理解“某个 search 后面应该接某个 detail”，那只是把当前 case 模式固化了，不是真正获得通用多跳能力。

### 1. 先把“要回答什么”变成显式计划对象

很多系统的多跳失败，根因是 planner 从头到尾都只有：

- 用户问题
- 历史消息
- 工具清单
- 上一次 tool result

这样它只能靠自然语言感觉去判断下一步。

更稳的做法是先形成一个轻量计划对象，例如：

```json
{
  "goal": "回答今天计划炉次有多少",
  "subquestions": [
    "今天有哪些生产计划",
    "每个计划包含多少炉次",
    "汇总总炉次数"
  ],
  "evidence_needed": [
    "today_plan_list",
    "per_plan_furnace_count"
  ],
  "evidence_collected": []
}
```

关键点不在字段名，而在这个对象表达了三件事：

- 目标结论是什么
- 为了这个结论还缺什么证据
- 当前只是部分完成，还是已经足够回答

这类思路和 planning agents、plan-and-execute、ReWOO 这一路更接近。核心不是多打标签，而是让 planner 真正先产出计划，再进入执行。

### 2. 每轮执行后先做证据校验，不要直接让模型决定停机

这是比补更多 tool description 更关键的一步。

很多系统的问题不是不会调下一把 tool，而是第一跳回来后直接 `RESPOND` 了。

更稳的做法是在每次 tool 调用后，加一个小的 verifier 步骤，只回答一个问题：

> 基于当前计划和已有证据，现在能回答吗？

输出也应该是结构化的，比如：

```json
{
  "can_answer": false,
  "missing_evidence": [
    "per_plan_furnace_count"
  ],
  "reason": "当前只有计划列表，没有每个计划的炉次详情或炉次数量"
}
```

只有 `can_answer=true` 时才允许进入最终回答。

这样“是否停止”就不再是模型自由发挥，而是被一个显式的证据校验步骤卡住。

### 3. 下一跳工具选择要围绕“补齐缺失证据”，不是围绕固定 follow-up 关系

这里最容易走偏的地方，是给工具增加一堆强耦合关系，例如：

- `tool A` 后面通常接 `tool B`
- 某类问题只能由某两个工具串起来
- 某把 search 固定对应某把 detail

这类设计短期有用，但会让工具体系越来越耦合，新增工具时还要不断维护 follow-up 图谱。

更泛化的做法是让运行时只关心一件事：

> 当前缺的证据是什么，哪个工具最可能补齐它？

这样 tool metadata 最多只需要很轻的一层，例如：

- domain
- granularity
- outputs/provides

而不是写成“这个工具下一步该接谁”。

这时候 planner 的推理链就从：

- “我刚调了 search，所以也许应该调 detail”

变成：

- “我还缺每个计划的炉次数量，所以我要找能提供 plan detail 或 furnace count 的工具”

这是两种完全不同的设计。

### 4. 稳定链路最终还是可以收敛成 facade，但那是后续优化，不是多跳能力本身

当一条链路已经非常稳定时，把它收成只读 facade 依然是合理的。

但这里要分清主次：

- facade 解决的是高频稳定路径的成本和稳定性问题
- 显式计划 + 证据校验 + 重规划，解决的才是通用多跳能力

如果一开始就把方案做成“不断把多跳收进 facade”，系统会越来越像工作流平台，而不是一个真正有推理能力的 agent。

## 在现有系统里，应该怎么落

如果是 Java MCP + Python Orchestrator 这类架构，我现在更认可的落地方向是下面四步。

### 第一步：在 Python runtime 里引入显式 `plan_state`

这个对象不需要很重，但至少要有：

- `goal`
- `subquestions`
- `evidence_needed`
- `evidence_collected`
- `can_answer`

这样系统每轮循环里就不再只是“拿消息 + 拿工具结果”，而是“更新计划状态”。

### 第二步：在每次 tool 调用后增加 verifier / replan 步骤

这个 verifier 不负责回答用户，只负责判断：

- 当前证据是否足够
- 如果不足，还差哪类证据
- 是继续执行现有计划，还是需要重规划

然后 runtime 决定：

- `RESPOND`
- `CALL_TOOL`
- `REPLAN`

### 第三步：让 planner 只依赖结构化证据，不依赖 preview 幻觉

很多系统第一跳过早停机，是因为 planner 看到了“像答案”的自然语言 summary。

更稳的做法是：

- planner 和 verifier 主要消费结构化结果
- 预览文本只给日志或回答阶段使用
- 不让 preview 参与“是否可以结束”的核心判断

### 第四步：few-shot 训练任务模式，不训练固定工具组合

few-shot 仍然有价值，但应该教的是任务模式：

- `list -> detail -> aggregate`
- `entity -> detail`
- `compare(A) + compare(B) -> summarize`
- `kb + business fact -> reconcile`

而不是教：

- `production_plan_search` 后面接 `production_plan_detail`

前者能迁移，后者只是把当前工具名背熟了。

## 一句更直接的总结

真正的通用多跳规划能力，不是让模型“更会猜下一步”，也不是给工具之间补越来越多的耦合关系。

更稳的方向是把这四件事做成系统能力：

- 显式计划
- 证据校验
- 重规划
- 基于证据缺口的工具选择

只要系统还在靠“第一跳看起来差不多就停”，多跳能力就会持续不稳定。

反过来，只要“要回答什么、证据够不够、还缺什么、下一步补什么”这四件事被显式化，用户换一种问法，planner 也更容易走出正确的多跳链路。
