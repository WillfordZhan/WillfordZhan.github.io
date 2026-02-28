---
title: "基于 OpenClaw 对照改造 iot-framework AI Orchestrator：终结非工具问题 CLARIFY 循环"
date: 2026-02-28 11:12:21
categories:
  - "AI"
tags:
  - "OpenClaw"
  - "Orchestrator"
  - "ReAct"
  - "CLARIFY"
  - "奥卡姆剃刀"
  - "FastAPI"
  - "AI工作日志"
---

## 背景

这次改造聚焦一个真实线上体验问题：用户问的是通用解释类问题（本质不需要工具），Orchestrator 仍然进入 ReAct 规划，随后触发 `CLARIFY`，并在后续交互里反复追问，形成“看起来一直要补信息”的循环感。

目标很明确：在不扩大系统复杂度的前提下，借鉴 OpenClaw 的分层思路，把“是否需要工具”尽早判定，把 `CLARIFY` 收紧到真正可执行的场景，让非工具问题直接回到 CHAT。

## 问题复现

复现输入（典型）：

- Query：`铸造行业的通用定义是什么`
- 可用工具：`today_furnace_batches` 等业务数据查询工具

改造前表现（问题态）：

1. Query 直接进入 ReAct planner。
2. Planner 可能输出 `action=CLARIFY`，但 `tool_name` 为空、`missing_slots` 为空，问题并非“缺参数的工具调用”。
3. 用户继续回答后，系统仍可能在“澄清-再澄清”路径内打转，无法尽快回到直接回答。

根因不是模型“笨”，而是编排器缺少足够强的前置闸门与动作约束。

## OpenClaw 关键机制对照

OpenClaw 给了三个值得借鉴的点：

1. 先路由再执行：先决定是否走工具链路，再进入工具循环，而不是所有请求都先进入循环。
2. 结构化动作与守卫：工具调用、终止、澄清都有清晰边界，避免“语义上不成立但语法上合法”的动作继续扩散。
3. 循环治理：强调无进展循环检测与回退策略，避免 agent 在低价值轨道上反复执行。

对照下来，我们原链路缺的正是“前置分流 + CLARIFY 可执行性约束 + 明确回退”。

## 现状评审

旧链路的关键风险点：

1. 没有 `CHAT|TOOL|UNKNOWN` 前置判定，非工具问题也被送进 ReAct。
2. `CLARIFY` 触发条件过宽，只要模型给出 `CLARIFY` 就可能被接收。
3. 对“不可执行澄清”缺乏强制回退，导致对用户感知是“问来问去不落地”。

这三个点叠加后，正好解释了“非工具问题陷入 CLARIFY 循环”。

## 奥卡姆方案

遵循奥卡姆剃刀，这次没有引入新策略层、没有增加多模型协同，只做最小闭环：

1. 在 ReAct 前增加一个轻量 mode 决策：`CHAT|TOOL|UNKNOWN`。
2. 让 `CLARIFY` 只有在“已锁定具体工具且确实缺必填参数”时才成立。
3. 对不满足可执行条件的 `CLARIFY`，直接回退到 CHAT 直答，不继续澄清链路。
4. 用测试把上述行为固化，避免回归。

这套方案改动集中、语义清晰、维护成本低。

## 改造点（核心）

这次改造的核心可归纳为四条：

1. `CHAT|TOOL|UNKNOWN` 前置分流  
   在 `_process_input` 初始阶段引入 `_determine_mode(...)`。若判定为 `CHAT`，直接 `policy_decision=chat/respond` 并结束；只有 `TOOL/UNKNOWN` 才进入 ReAct 主循环。

2. `CLARIFY` 触发条件收紧  
   Planner prompt 增加硬规则：非工具问题输出 `RESPOND`，且只有“已确定 `tool_name` + 缺必填参数”才能 `CLARIFY`。  
   同时 `_plan_from_intent_route(...)` 也改为：只有存在 `normalized_call` 且有 `missing_slots` 才映射为 `CLARIFY`。

3. 非可执行 `CLARIFY` 回退到 CHAT  
   新增 `_is_actionable_clarify(...)`：若没有具体工具、没有缺失必填参数，判定为不可执行澄清。  
   一旦命中，记录 `react_feedback=clarify_without_actionable_tool`，再发 `policy_decision=chat/fallback`，最终走 `_direct_answer(query)` 结束。

4. 相关测试补齐  
   新增并通过关键测试，覆盖“聊天短路”“不可执行澄清回退”与“工具场景仍可多步执行”。

## 测试结果

本次改造后在 `ats_iot_ai` 仓库执行：

```bash
pytest -q tests/test_runs.py
# 15 passed in 0.28s

pytest -q tests/test_qwen_client.py
# 6 passed in 0.46s

pytest -q
# 37 passed in 0.97s
```

重点行为用例：

1. `test_chat_query_short_circuits_without_react_tool_loop`  
   验证 CHAT 问题不再进入 `react_plan/tool_call/clarification_needed`。

2. `test_non_actionable_clarify_falls_back_to_chat_response`  
   验证非可执行 `CLARIFY` 不再继续追问，而是回退直答。

3. `test_compare_query_forces_second_tool_call_before_respond`  
   验证工具型对比问题仍保持多步 `CALL_TOOL` 能力，没有被“过度收紧”误伤。

## 经验总结

1. `CLARIFY` 不是“兜底动作”，而是“可执行动作”：必须绑定具体工具和缺失参数。
2. agent 的第一道关卡应是“是否需要工具”，而不是“先规划再看情况”。
3. 回退策略要显式可观测（事件化），否则线上很难定位“为什么看起来在打转”。
4. 简化优先于堆叠：先把错误路径切断，再考虑更复杂的智能优化。

## 参考

- OpenClaw Docs（Tools & loop detection）：https://docs.openclaw.ai/architecture/tools
- OpenClaw Docs（Core architecture）：https://docs.openclaw.ai/architecture/overview
- OpenClaw Docs（System prompt / tool use policy）：https://docs.openclaw.ai/architecture/system-prompt
