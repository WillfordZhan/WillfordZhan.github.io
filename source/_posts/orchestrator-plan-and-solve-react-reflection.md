---
title: "里程碑进展：Orchestrator 动态范式编排（Plan-and-Solve / ReAct / Reflection）落地"
date: 2026-02-21 00:19:23
categories:
  - "AI"
tags:
  - "AI工作日志"
  - "Orchestrator"
  - "ReAct"
  - "Plan-and-Solve"
  - "Reflection"
  - "MCP"
  - "里程碑"
---

动态范式 Orchestrator 改造完成，本文记录本轮里程碑的目标、交付、兼容性与下一步计划。

## 1) 里程碑目标

- 将单路径编排升级为“按意图动态选择策略”的多范式执行框架。
- 在不破坏既有事件契约的前提下，引入 Plan-and-Solve / ReAct / Reflection 三类策略能力。
- 补齐可观测链路，支撑后续运行质量评估与策略演进。

## 2) 本次完成内容（按模块）

### Intent Router + Policy Engine

- 新增意图识别层：将输入路由为 `TOOL_CALL` / `TRACE_DIAGNOSIS` / `GENERAL_QA` 等意图。
- 新增策略决策层：基于意图映射到执行策略（如 ReAct、Plan-and-Solve），并输出决策原因与元数据。
- 支持工具调用意图中 `tool:<name> <json>` 结构化参数解析，并保留失败兜底语义。

### Strategy Executors + Runtime Guard + Eval Loop

- 新增策略执行器集合：按策略统一实现 `run(context)`，输出标准化结果。
- 新增 Runtime Guard：对策略结果做运行期约束校验（字段完整性、状态一致性、失败传播）。
- 新增 Eval Loop：支持策略链路尝试、trace 记录与终止条件控制，为 Reflection 回退提供基础。

### Orchestrator 主流程集成

- 将 Intent Router、Policy Engine、Strategy Executors、Eval Loop 组装进主流程。
- 在主流程中新增意图/策略/trace 事件发射，并保持终态收敛逻辑一致。
- 打通策略输出到 `tool_call/tool_result/final` 的统一落库路径，确保事件序列可重放、可追踪。

## 3) 关键代码路径（带文件路径）

- `app/orchestration/intent_router.py`
- `app/orchestration/policy_engine.py`
- `app/orchestration/strategies.py`
- `app/orchestration/runtime_guard.py`
- `app/orchestration/eval_loop.py`
- `app/orchestration/types.py`
- `app/orchestrator.py`
- `tests/orchestrator/test_intent_policy.py`
- `tests/orchestrator/test_strategies.py`
- `tests/orchestrator/test_orchestrator_integration.py`

## 4) 行为兼容性说明

本次改造严格保留既有关键事件语义与可消费性，不破坏下游 SSE/UI/存储侧处理逻辑。保留事件包括：

- `run_started`
- `user_message`
- `tool_call`
- `tool_result`
- `final`
- `run_failed`

兼容性原则：

- 新能力在原契约上“增量扩展”，而非重定义。
- 终态事件仍以 `final` / `run_failed` 收敛。
- `tool_call` 与 `tool_result` 的关联字段（如 `toolCallId`）持续可用。

## 5) 新增可观测事件

在兼容原有事件的基础上，新增以下可观测事件用于策略链路诊断：

- `intent_determined`：记录识别出的意图、判定原因与辅助元数据。
- `policy_decision`：记录策略选择结果、选择理由与策略元信息。
- `trace`：记录每步策略执行轨迹（`strategy`、`ok`、`reason`、`durationMs`、`metadata`）。

## 6) 测试与验收结果

- `pytest` 全量：`36 passed, 1 warning`
- 覆盖范围包含：
- 意图解析与策略决策单测
- 策略执行器 / Guard / Eval Loop 行为单测
- Orchestrator 端到端集成测试（含事件顺序与关联字段校验）

## 7) 关联 commit 列表

- `7c51a83 feat(orchestrator): add intent router and policy engine`
- `2ade778 feat(orchestrator): add strategy executors and runtime guard`
- `54359f4 feat(orchestrator): integrate dynamic strategy pipeline`

## 8) 下一步计划（v2）

- policy 可配置化（tenant 级）
- trace 指标沉淀到可视化面板
- 真实 LLM planner 接入
