---
title: "LangGraph 编排清理复盘：一次最小增量重构（STAR）"
date: 2026-03-05 14:46:26
tags:
  - "LangGraph"
  - "重构"
  - "可维护性"
  - "测试"
---

近期对 `ats_iot_ai` 的 LangGraph 编排层做了一轮“小步快跑”的整理。目标不是大改架构，而是把最容易反复出问题的边界先收紧。

## Situation

改造前的主要痛点集中在三处：

1. plan 解析链路偏脆弱：对模型输出格式依赖较强，非标准结构时兜底不清晰。
2. 节点输出不一致：不同节点返回 patch 形态不统一，状态合并逻辑分散，排查回归成本高。
3. tool schema 校验偏弱：unknown/missing args 场景下行为不够显式，容易出现“调用成功但语义错误”的隐患。

## Task

约束是“最小增量重构”：

1. 不引入大规模接口破坏，优先可回滚、可验证的小提交。
2. 同时提升三件事：简单性（代码路径更少）、健壮性（异常输入有明确 fallback）、可扩展性（后续新增工具/节点不需要复制粘贴式改造）。
3. 保持可观测性，确保失败原因可定位。

## Action

按提交拆分，逐步落地。

### 1) `refactor(langgraph): unify node state patch outputs`

核心动作：统一节点 state patch 输出契约。

- 在编排相关实现中收敛 patch 返回结构，减少“节点各自定义”的分叉行为。
- 将状态合并规则集中化，避免散落在节点函数里的隐式 merge。
- 结果是：节点职责更单一，调试时只需对照统一 patch 约定。

### 2) `refactor(langgraph): adopt structured plan parser and tool-spec normalization`

核心动作：替换解析轮子并补齐参数规范化。

- plan parser 切换到 `langchain_core` 的 `PydanticOutputParser`。
- 移除自定义 `structured_output` 轮子，降低维护成本与行为分歧。
- 增加 tool-spec normalization：对 unknown/missing args 给出明确 fallback 规则，避免隐式吞错。

文件级变更重点（按职责）：

- 计划解析模块：引入结构化 parser，统一解析入口与异常分支。
- tool schema/规范化模块：补充参数归一化与缺省处理逻辑。
- orchestrator 相关模块：接入新的 parser 与规范化结果，统一运行时行为。

### 3) `test(langgraph): cover structured parsing and tool validation fallbacks`

核心动作：把关键回归点落到测试。

- 新增/完善 `test_plan_schema.py`：覆盖结构定义与边界校验。
- 新增/完善 `test_plan_parser.py`：覆盖结构化解析成功与 fallback 分支。
- 新增/完善 `test_orchestrator_langgraph.py`：覆盖 orchestrator 与 tool 校验联动行为。

## Result

- `pytest` 结果：`39/39` 通过。
- 自定义解析轮子被移除，LangGraph 周边实现更贴近标准组件。
- 节点 patch 与 tool 参数处理更一致，后续排障与扩展成本下降。
- 失败路径更可解释，可观测性提升（能更快定位是解析问题还是 schema 问题）。

## 关键收益

1. 降低认知负担：统一契约后，新增节点/工具不必重复发明输出与校验逻辑。
2. 降低回归风险：核心边界由测试覆盖，改动可快速验证。
3. 降低维护成本：减少自研轮子，优先复用社区成熟能力。

## 后续可选增强

1. 为 tool-spec normalization 增加结构化错误码，便于前端/调用方做精细化提示。
2. 在 orchestrator 增补按阶段打点指标（解析耗时、校验失败类型分布）。
3. 为关键 fallback 增加快照型回归样例，降低未来重构时的行为漂移。
