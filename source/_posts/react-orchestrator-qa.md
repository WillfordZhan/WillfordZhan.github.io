---
title: "ReAct Orchestrator 意图识别升级：踩坑与 QA 纪要"
date: 2026-02-25 18:42:15
categories:
  - "AI"
tags:
  - "ReAct"
  - "Orchestrator"
  - "意图识别"
  - "Tool Calling"
  - "AI工程"
  - "AI工作日志"
---

这篇记录来自一次真实的架构评审：我们发现当前 Orchestrator 在意图识别阶段还偏“query直通”，导致后续策略选择和工具调用容易偏离用户真实意图。本文沉淀核心踩坑、关键 QA 结论和可执行改造路径。

## 背景

当前链路已经可用：`/ai/runs` + SSE + Tool Call。但意图层的主要问题是：

1. 路由以规则/关键词为主，语义理解和槽位抽取不足。
2. Policy 更像静态映射，不是执行闸门。
3. React 执行层仍可能从原始 query 反向 parse 工具调用。
4. Tool 成功返回后，缺少统一 Verify 防线。

## 踩坑记录

### 坑1：把“路由命中”当成“意图识别完成”

`tool:xxx {json}` 命中只能说明格式命中，不代表用户任务真正可执行。现实里经常出现：
- 参数不全（缺设备、时间范围）
- 参数不合法（schema 不匹配）
- 意图冲突（用户其实想“分析原因”，不是“直接执行某工具”）

结论：必须输出结构化理解对象，而不是只输出一个策略枚举。

### 坑2：把策略选择完全交给模型

如果没有代码层 Policy Gate，模型就既当“语义理解者”又当“执行裁判”。在工业场景这会带来权限、越权、误执行风险。

结论：让模型决定“可能是什么”，让代码决定“能不能做”。

### 坑3：把 Observation 当 Verify

拿到工具返回（Observation）不等于结果可用。常见失败：
- 返回缺关键字段
- 结果与上下文不一致
- 数据跨租户越权

结论：Observation 是事实输入，Verify 是规则判定，必须分开。

### 坑4：盲目要求输出完整 CoT

我们讨论后明确：可让模型进行内部推理，但不建议把原始 CoT 作为产品输出，也不建议把长 CoT 作为编排决策主输入。

结论：编排层只消费结构化字段 + 简短 rationale。

## QA 讨论结论

### Q1：Understand 和 Decide 能不能合并？

可以在“一次 LLM 调用”中产出理解和候选动作，但架构职责不建议合并。

- Understand：语义解析与结构化产出（intent、slots、confidence）
- Decide：代码层 Policy 决策（execute/clarify/fallback/deny）

### Q2：Reasoning 输入输出到底是什么？

推荐输入：
- 用户 query
- 历史上下文摘要
- 工具描述+参数 schema
- 当前运行状态（重试次数、预算、前序失败）
- 策略约束（权限、风险规则）

推荐输出（强结构化）：
- `intent`
- `confidence`
- `candidates`
- `slots`
- `missing_slots`
- `next_action`
- `tool_plan`
- `clarification_question`
- `brief_rationale`

### Q3：Verify 是不是 Observation？

不是。

- Observation：工具执行后的原始返回
- Verify：对返回做完整性/一致性/权限/风险校验

ReAct 推荐循环：
`Reason -> Act -> Observe -> Verify -> (继续/结束)`

### Q4：槽位缺失怎么处理？

缺关键槽位时不执行工具，进入澄清：
- 触发 `clarification_needed`
- 一次只问 1-2 个关键问题
- 用户补充后合并上下文再推理
- 超过最大澄清轮次则 fallback 或人工接管

### Q5：Qwen 是否建议输出 CoT？

结论：可以启用 thinking 用于内部推理/调试，但默认不把原始 CoT 回给用户。系统对外以结构化结果和简短解释为主。

## 最终落地优先级（先做这4项）

1. ReactStrategy 不再从 query 二次 parse tool call，只接受结构化 `tool_call`。
2. PolicyEngine 增加 `action`（`execute/clarify/fallback/deny`）与阈值配置。
3. 新增 `clarification_needed` 事件，承接缺槽位追问流程。
4. 增加 Verify 最小闭环（schema + 权限 + 空结果 三条硬规则）。

## 建议迭代顺序

- Iter A：先扩结构（不改行为）
- Iter B：Policy 阀门化 + 澄清
- Iter C：React 去 query 直通
- Iter D：Verify 校验器

这样可以在不打断现有可用链路的前提下，逐步逼近“可解释、可治理、可回滚”的 ReAct 编排架构。

## 复盘一句话

MVP 能跑是起点，生产级 ReAct 的关键不是“让模型多想”，而是把“理解、决策、执行、校验”边界拉直，并让代码掌握最终执行权。
