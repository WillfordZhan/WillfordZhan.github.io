---
title: "LangGraph HITL 重构复盘：从一次性澄清到可恢复编排"
date: 2026-03-06 01:11:48
categories:
  - "AI"
tags:
  - "LangGraph"
  - "LangChain"
  - "HITL"
  - "编排"
  - "复盘"
  - "AI工作日志"
---

这周把一条很“能跑但不优雅”的链路，改成了真正可恢复的人在回路（HITL）语义。

一句话版本：

- 以前：`clarification_needed -> final`，一轮结束，下一轮靠外部再喂输入，图内语义断开。
- 现在：`clarify 节点内 interrupt(payload)` 挂起，用户补充后 `Command(resume=...)` 继续执行，图内闭环。

下面按工程复盘写清楚：问题是什么、改了什么、为什么有效、还有什么坑。

## 背景：系统在“会聊”但还不“会等人”

我们这套控制平面是 FastAPI + LangGraph 单轨编排，核心流程是：

1. `bootstrap` 拉上下文与 tools。
2. `plan` 让 LLM 决策 `CALL_TOOL | CLARIFY | RESPOND`。
3. `tool_call` 执行工具。
4. `chat/clarify` 收口回答。

早期问题不在“能不能回答”，而在“澄清是不是一等公民”——

- 澄清路径本质是一次性结束，语义上更像“客服已结束本次工单，请重新提交”。
- 在真实多轮业务里，用户补一句参数就该继续，而不是重新开启半条流程。

## 最近几次关键提交（按因果顺序）

### 1) 先把工具调用契约理顺（`tool_calls` 统一语义）

相关提交：`505d754`、`d3c63c6`

改动点：

- 统一 planner 输出为 `tool_calls[]`，不再混用单 tool 字段和数组字段。
- 对应测试补齐，避免“看起来没错，实际分支漏处理”。

收益：

- 工具执行入口变成统一批处理语义。
- 后续做校验、重试、聚合不再分叉写两套逻辑。

### 2) 参数治理从“猜一猜”变“按 schema 说话”

相关提交：`a8a04b6`、`42b1f5d`

改动点：

- 引入 schema 驱动的参数归一化与澄清策略（缺参、未知参、不可用工具统一处理）。
- 增加 HTTP -> LangChain `StructuredTool` 适配能力，为后续 ToolNode 化打基础。

收益：

- 错误路径可解释（不是“模型抽风”，而是“参数不满足契约”）。
- 澄清文案可脱敏，不把内部字段名直接甩给用户。

### 3) 稳定性加固：事件幂等 + 解析恢复

相关提交：`c3a54ce`、`72e5e5d`

改动点：

- 增加通用事件幂等策略，修复 `conversation_started` 重复写入。
- Plan 解析失败增加恢复策略，不直接把一切异常都归因到“模型不可用”。

收益：

- SSE 时间线更干净，可观测性提升。
- 出错时可恢复可降级，减少“一次解析失败导致整轮崩掉”。

### 3.5) Clarify 专项优化（这部分单独记）

相关提交：`72e5e5d`（`fix(langgraph): 增强Plan解析恢复并统一CLARIFY/RESPOND收敛节点`）

这次 Clarify 的重点不是“多问一句”，而是把 Clarify 从一个零散分支变成编排里的标准出口：

- planner 输出不稳定时，先做结构恢复，再统一落到 `CLARIFY` 或 `RESPOND`。
- `react_plan` 事件里记录 `parseStatus`、`validationErrors`，方便线上定位“为什么进了澄清”。
- Clarify 文案走统一策略，避免不同节点各说各话。

为什么这一步很值：  
以前排障经常出现“用户看到澄清，研发不知道是缺参、解析失败还是工具不可用”。  
现在至少从事件层就能直观看到分类，运维和研发都省掉很多猜谜时间。

### 4) HITL 关键落地：从“澄清即结束”到“澄清即挂起”

相关提交：`796de41`、`f7bfbb0`、`934b34e`

改动点：

- `clarify` 节点内统一做两件事：
  - 发 `clarification_needed`
  - 调用 `interrupt(payload)`
- 恢复时由 orchestrator 走 `Command(resume=query)`，图继续跑，不重新拼“伪首轮”。
- 抽 `graph_config(conversation_id)`，收口 thread_id 配置。
- `_is_waiting_for_human` 仅看 snapshot task 的 `interrupts`，不再靠 `next_nodes` 宽判断。

收益：

- HITL 语义和状态流在图内闭环。
- 代码层减少外部补事件逻辑，维护成本下降。
- 恢复判定更稳，不会把普通 pending 状态误判为“正在等人”。

## 这次改造的“Pro”总结

### Pro 1：语义正确性提升

`CLARIFY` 不再是假结束，而是可恢复暂停。

这点很关键：复杂业务里“等用户一句话”是主流程，不是异常流程。

### Pro 2：状态边界更清晰

- 图状态（interrupt/resume）归 LangGraph。
- 会话事件（SSE 可见性、审计）归 store/event_streamer。

边界清晰后，排障时不会在“是图的问题还是事件的问题”上兜圈子。

### Pro 3：幂等和恢复更工程化

- 事件去重策略化。
- 中断后状态清理更明确。
- 恢复入口统一（`Command(resume=...)`）。

这三件事叠加，线上“偶发重复/偶发卡住”的排查成本会明显下降。

### Pro 4：为后续增强预留了正确接缝

目前已经具备继续演进的前提：

- checkpoint 持久化策略
- Tool schema 闭环
- ToolNode / 多节点子图化

不是“以后再重构一轮”，而是“在当前结构上可持续迭代”。

## 真实联调结果：通过主链路，也暴露了环境问题

我们把典型用例扩展到中断恢复场景（Case11：create -> interrupt -> chat resume），联调现象：

- 创建会话成功。
- interrupt 成功并返回 `interrupted=true`。
- chat 继续受理成功。
- 事件链出现 `conversation_interrupted`，说明 HITL 路径已被触发。

同时发现一个额外缺陷：

- 恢复后出现 `conversation_failed`，错误为 `[Errno 2] No such file or directory`。

这个错误不是 HITL 语义本身的问题，更像运行环境依赖缺失（文件/路径配置）导致的后续节点失败。它被记录为独立环境问题处理，不和本次语义改造混在一起。

## 关键代码片段（简化示意）

```python
# clarify node
await emit_event("clarification_needed", {"question": question})
resume_text = interrupt({"question": question})
return {"query": resume_text}
```

```python
# orchestrator
if is_waiting_for_human(conversation_id):
    graph_input = Command(resume=query)
else:
    graph_input = {"conversation_id": conversation_id, "query": query}

result = await graph.ainvoke(graph_input, config=graph_config(conversation_id))
```

## 延伸问答

### Q1：为什么不在 orchestrator 里补发澄清事件？

因为这会让语义跨层：图在暂停，控制层又补业务事件，边界变混乱。最稳妥是把“澄清+挂起”原子化放在 `clarify` 节点里。

### Q2：为什么恢复判定不用 `next_nodes`？

`next_nodes` 只代表“还有待执行节点”，不等于“在等人”。判断 HITL 等待应看任务是否带 interrupt 标记。

### Q3：这套改造是不是只适配当前 case？

不是。它依赖的是 LangGraph 的通用语义（interrupt/resume/checkpoint），不绑定具体 query 文本或某个业务字段。

## 收尾

这轮改造最有价值的地方，不是“又多了几个节点”，而是把编排从“能跑”推进到“可恢复、可审计、可扩展”。

如果你也在做多轮工具型 Agent，建议优先把这三件事做好：

1. 结构化输出契约稳定。
2. schema 驱动参数治理。
3. HITL 走图内 interrupt/resume，不走外部补丁流。

踩坑是常态，但把坑做成公共能力，下一次就不是坑了。
