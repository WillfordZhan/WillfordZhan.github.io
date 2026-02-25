---
title: "AI控制面生产化改造：LLM意图路由与ReAct执行边界"
date: 2026-02-25 19:29:24
categories:
  - "AI"
tags:
  - "AI工作日志"
  - "ReAct"
  - "Orchestrator"
  - "IntentRouter"
  - "Qwen"
  - "PolicyEngine"
  - "Verify"
---

这次改造把 `ats_iot_ai` 的 Orchestrator 从 MVP 规则路由，切到生产模式的 LLM 驱动编排。

## 背景

线上痛点很明确：`process_input` 里 `IntentRouter.route(query)` 主要依赖模式匹配，无法稳定处理语义歧义、槽位缺失和复杂意图。与此同时，React 执行层存在 query 二次解析，执行边界不够清晰。

目标是把链路拉直为：

`Understand -> Decide -> Act -> Verify -> Respond`

## 本次核心变更

1. `IntentRouter` 升级为 **LLM-based** 主路径。
- 保留 deterministic fast path：`tool:<name> {json}`。
- 其他请求走 Qwen 结构化解析（intent/confidence/slots/missing_slots/tool_plan）。

2. 新增 `QwenIntentParser`。
- 强约束 JSON 输出。
- 解析失败自动回退到安全 chat 路由，避免阻塞主流程。

3. `PolicyEngine` 从静态 strategy map 升级为决策闸门。
- 新增 action：`execute/clarify/fallback/deny`。
- 引入 confidence 阈值与 missing_slots 规则。

4. `ReactStrategy` 去掉 query 二次解析。
- 仅消费结构化 `tool_call`，执行输入边界可控。

5. 引入 `Verify` 最小硬规则。
- 先落三条：schema、权限上下文、空结果。
- 校验失败写出 `verification_failed` 事件并终止错误收敛。

6. SSE 事件链路增强。
- `intent_determined` 增加 confidence/candidates/slots/missingSlots/toolPlan。
- `policy_decision` 增加 action。
- 新增 `clarification_needed`、`verification_failed`。

## 代码落点

- `app/orchestration/intent_router.py`
- `app/orchestration/intent_llm_parser.py`
- `app/orchestration/policy_engine.py`
- `app/orchestration/strategies.py`
- `app/orchestration/verify.py`
- `app/orchestrator.py`
- `tests/orchestrator/*`

## 文档同步

- `README.md` 切到 Production Mode 描述。
- `docs/REACT_ORCHESTRATOR_INTENT_UPGRADE_SPEC.md` 升级为生产基线（LLM 主路径、Policy 闸门、Verify 必经）。
- 对应 skill 文档也从 MVP 调整为 production 导向。

## 测试结果

- Orchestrator 核心回归通过。
- 全量测试通过（本次改造后运行结果：`49 passed`）。

## 结论

这次改造的关键不是“把 ReAct 做复杂”，而是先把生产边界做正确：
- 语义理解交给 LLM（结构化输出）
- 执行决策交给 Policy（代码闸门）
- 执行结果交给 Verify（质量防线）

下一步会继续做 LLM parser 的生产强化：schema 校验加强、重试与降级策略、prompt/version 管理和可观测性细化。
