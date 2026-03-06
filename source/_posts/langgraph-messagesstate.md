---
title: "LangGraph 从字段拼接到 MessagesState：两次提交把编排链路收口"
date: 2026-03-06 17:16:30
categories:
  - "AI"
tags:
  - "LangGraph"
  - "FastAPI"
  - "AI工作日志"
  - "架构重构"
  - "工程复盘"
---

这篇记录复盘最近两次连续提交：

- `76539e9`：`refactor(langgraph): 全量收口到MessagesState单一状态源`
- `2138513`：`refactor(langgraph): 删除未激活respond节点并清理导出`

一句话总结：把编排状态从“字段搬运工模式”改成“消息主链模式”，再把没上班的节点请出工位。

## 先说改造前的问题

在这次重构前，编排链路同时维护几套上下文来源：

- `query`
- `tool_result_preview`
- `tool_result_payload`
- `validated_tool_calls`
- 以及事件流里的 `user_message/tool_result/final`

问题不在于字段多，问题在于这些字段会在不同节点被分别读写，久而久之出现两个经典现象：

1. 同一轮对话，状态里能找到三份“都像真相”的数据。
2. 想复盘一次问题，要在多个字段之间来回对照，像在车间里找同一把 14 号扳手。

## Commit 1：`76539e9` 做了什么

### 1) 状态基类切到 `MessagesState`

`app/langgraph/state.py` 从普通 `TypedDict` 改为继承 LangGraph 原生 `MessagesState`，把 `messages` 作为主上下文容器。

收益：

- 与 LangGraph reducer 机制对齐，后续扩展更顺滑。
- 消息历史有统一载体，不再靠散落字段拼接“近似上下文”。

### 2) 编排入口统一注入 `HumanMessage`

`app/orchestrator.py` 在每轮输入 graph 前写入：

```python
"messages": [HumanMessage(content=query)]
```

收益：

- 进入图时上下文结构统一。
- `plan` 不必依赖“这个 query 是不是刚好被某节点回填过”。

### 3) 新增消息工具层 `app/langgraph/messages.py`

抽出通用函数：

- `latest_human_query(...)`
- `serialize_history(...)`
- `tool_observations(...)`
- `latest_tool_fallback_answer(...)`

收益：

- 消息提取规则集中，避免在 `plan/chat/prompting` 重复写解析逻辑。
- 这是可复用抽象，不是为了“抽象而抽象”。

### 4) `plan` 节点改为消息驱动

`plan` 现在优先从 `messages` 中提取最后一条用户输入，再把历史与工具观察一起喂给 planner。

收益：

- 多轮澄清/恢复时，plan 看到的是“对话事实”，不是残留字段。

### 5) `tool_call` 写入标准 `ToolMessage`

工具调用结果被写成 `ToolMessage`，内容是结构化 JSON（`ok/preview/result/error`）。

收益：

- 工具观察自然进入消息主链。
- 后续做 “只靠 messages 驱动 answer 汇总”有基础。

### 6) `clarify` 和 `chat` 也并入消息链

- `clarify` 写入澄清 `AIMessage`，resume 后写回 `HumanMessage`
- `chat` 产出 final 时写入 `AIMessage`

收益：

- 澄清中断恢复形成闭环，不再是“事件有记录，状态没历史”。

### 7) 同步清理 schema 与测试

`state_patch/tool_runtime/test_plan_node/test_prompting` 一并调整，保证字段迁移后行为不回退。

## Commit 2：`2138513` 做了什么

这次提交非常短，但很值钱：

- 删除 `app/langgraph/nodes/respond.py`
- 清理 `nodes/__init__.py` 导出

背景：图路由已经走 `chat`，`respond` 节点处于未激活状态。

收益：

- 去掉“看起来能跑、实际不会跑”的伪路径。
- 新同学读代码不会被“幽灵节点”误导。

## 两次提交带来的直接收益

### 可维护性

- 状态收口后，节点职责更清晰：
  - `plan` 看消息决定行动
  - `tool_call` 产出工具消息
  - `chat` 汇总输出
- 读链路时不再需要先猜“这轮到底读了哪个旧字段”。

### 可追溯性

- 一条完整轨迹可直接在消息序列中复盘：
  - `HumanMessage -> AI(计划/澄清) -> ToolMessage -> AI(final)`
- 这对排查“为什么走了 CLARIFY 而不是 CALL_TOOL”非常实用。

### 可扩展性

- 与 LangGraph 原生生态更贴近，后续接 checkpoint/human-in-the-loop/更复杂 reducer 成本更低。

### 代码冗余

- 删除未激活节点，减少维护噪音。
- 部分旧字段依赖被移除，状态面变窄。

## 这次改造没有解决什么

客观讲，这两次提交是“主干收口”，不是“全量终局”。仍有几个后续项值得继续做：

1. 把剩余兼容字段继续下沉或删除，彻底做到 messages 为唯一事实源。
2. 统一参数校验入口，避免 normalize 与 validate 双逻辑长期漂移。
3. 给消息链增加结构化观测（如每轮关键消息摘要），提升线上排障速度。

## 一个典型的因果链（这次改造为什么有效）

- 现象：多轮恢复时，plan 可能读到旧字段而不是最新用户补充。
- 机制：状态事实分散在多个字段，更新边界不一致。
- 修复：统一改为 MessagesState 主链，resume 明确写回 `HumanMessage`。
- 结果：plan 读取路径固定为“最后用户消息 + 历史消息”。

这就是本次改造的核心：不是追求“看起来高级”，是把上下文事实源从“多处拼接”变成“一处主链”。

## 延伸问答

### Q1：为什么不是直接上一个超大 `BaseModel` 状态类？

因为 LangGraph 的强项是增量 patch + reducer。先用 `MessagesState` 收口主链，再按节点加 typed patch，风险更低。

### Q2：删除 `respond` 会不会影响行为？

不会。路由已经走 `chat`，`respond` 仅是未激活冗余实现。

### Q3：这次改造最值的一点是什么？

“单一事实源”落地。调试、复盘、继续迭代都更便宜。

## 小结

这两次提交做的是一类看起来不炫、但长期收益很高的工程活：

- 用 `MessagesState` 把主链收口
- 用删除冗余节点减少认知噪音

短期你会感觉“代码没多出什么新功能”；长期你会发现“同类 bug 明显更难长出来”。EOF