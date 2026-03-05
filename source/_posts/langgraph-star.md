---
title: "LangGraph 编排重构实录：拆编排不拆对外契约（STAR）"
date: 2026-03-05 20:18:11
categories:
  - "AI"
tags:
  - "LangGraph"
  - "重构复盘"
  - "架构治理"
  - "AI工作日志"
---

这篇复盘写给已经在做 Agent/LLM 编排、并且被“历史包袱 + 线上契约 + 多系统联动”三连击过的工程师。

一句话版结论：这次不是“把代码搬到新目录”，而是把编排从“单文件扛全场”升级为“LangGraph 节点化 + 对外契约不动”的可演进内核。过程不炫技，核心是稳。

如果要用一句带点黑色幽默的话描述这次重构：

> 我们终于把 `orchestrator.py` 从“全栈菩萨”劝退成“职业编导”。

## 0. 先交代边界（避免复盘变成文学）

本次复盘基于 `ats_iot_ai` 最近一轮真实改造记录，重点覆盖：

- LangGraph 单轨编排落地（不再双轨）
- 节点拆分到独立文件（bootstrap / plan / tool_call / clarify / respond）
- API、MCP、Store 对外契约保持兼容
- 事件持久化切到 Java Store（Python 作为调用方）
- LLM 接入异常与 MCP 401 的联调定位

对应代码边界：

- 编排：`app/orchestrator.py`、`app/langgraph/**`
- Infra：`app/store.py`、`app/mcp_client.py`、`app/tool_service.py`、`app/http_tool_adapter.py`
- API：`app/api.py`
- 回归：`tests/test_orchestrator_langgraph.py`、`tests/test_plan_schema.py`、`tests/test_plan_parser.py`、`tests/test_mcp_client.py`、`tests/test_mcp_status.py`、`tests/test_event_idempotency.py`

## 1. STAR 总览

### S（Situation）

重构前的主要矛盾不是“功能缺失”，而是“演进成本不可控”：

1. 编排逻辑虽然可用，但职责边界有历史耦合，变更常常牵一发而动全身。
2. API 层已经被外部 Java 网关和前端消费，不能轻易改调用契约。
3. MCP 工具执行、事件存储、编排决策属于不同关注点，却在改造时容易被一起搅动。
4. 线上调试时，一旦出现 `模型服务暂不可用` 或 `/system/mcp/status` 的 401，排障链路会跨 Python/Java 两侧，成本高。

典型症状是：业务希望“快速改编排”，工程师却先在想“这次会不会把外部接口带崩”。

### T（Task）

目标不是“写一版更酷的新 orchestrator”，而是更硬核也更无聊的一件事：

1. 在不破坏 `app/api.py` 对外调用形态的前提下，替换编排内核为 LangGraph 单轨。
2. 把节点职责拆干净，让后续多节点扩展不是灾难性 diff。
3. 明确资产边界：编排归编排，Infra 归 Infra，MCP 归 MCP，API 只做入口与协议。
4. 保障回归：关键链路都要有测试兜底，避免“重构成功，联调翻车”。

### A（Action）

#### A1. 先冻结对外契约，再动编排内核

这是这次最省命的一步。

- `app/api.py` 原先调用 orchestrator 的位置尽量不动。
- 需要过渡时，用“外部接口不变、内部实现替换”的方式推进。
- 先保证调用方无感，再逐步清理编排内部历史链路。

好处很现实：即使编排内部改炸了，至少 Java 网关和前端不会第一时间一起炸。

#### A2. LangGraph 单轨化，节点按职责拆分

落地成 `app/langgraph/` 分层：

- `graph.py`：图结构与路由
- `state.py`：统一状态模型
- `nodes/bootstrap.py`：启动态整理与上下文预处理
- `nodes/plan.py`：计划/动作决策与结构化解析
- `nodes/tool_call.py`：工具调用与结果回写
- `nodes/clarify.py`：澄清问题输出
- `nodes/respond.py`：最终回复收敛
- `schemas/` + `decoders/`：结构化输出约束与修复

这一步本质上是在做“可维护性财政改革”：每个节点只管一类决策，减少跨文件隐式耦合。

#### A3. 工具调用从“自由发挥”改为“结构化契约”

关键收敛点：

- 统一 `tool_calls` 数组语义
- 在 schema/decoder 层处理“模型输出不规范”的恢复
- 参数归一化与澄清机制前置，避免盲调工具

换句话说，不再赌模型每次都输出 perfect JSON，而是把“模型偶发抽风”纳入系统设计。

#### A4. Infra/MCP/Store 侧边界固化

编排只负责流程，不直接背 infra 细节：

- `store.py`：会话与事件存储抽象（含 Java Store 接入）
- `mcp_client.py`：MCP HTTP 协议与错误包装
- `tool_service.py` / `http_tool_adapter.py`：工具层适配

这让后续你要换存储后端、换工具执行策略，理论上都不需要重写编排图。

#### A5. 把“线上异常”当一等公民处理

本轮联调里，两个高频问题被重点治理：

1. `当前模型服务暂不可用，请稍后重试`：优先核查 LLM API 接入参数与服务可达性，再核对编排节点回退逻辑。
2. `/epservice/api/ai/system/mcp/status` 返回 `401 unauthenticated`：定位到鉴权上下文缺失/Token 不一致，按 Java 网关与 Python MCP 配置统一修复。

工程经验是：不要把“401/超时/解析失败”当偶发边角料，真实系统里它们才是主剧情。

### R（Result）

#### 结果 1：编排可以持续演进，而不是一次性工程

- LangGraph 单轨已成为主编排路径。
- 节点拆分后，新增节点或替换单节点的改动面显著降低。
- 编排主流程从“巨石函数”转向“节点化职责协作”。

#### 结果 2：对外资产稳定，重构风险被隔离

- API 层调用接口保持兼容，外部调用方无需同步大改。
- MCP / Store / Tool Adapter 作为 infra 资产得以保留并独立演进。
- 重构影响主要收敛在编排侧，不扩散到全局。

#### 结果 3：测试覆盖围住关键回归点

- 编排主链路：`tests/test_orchestrator_langgraph.py`
- 结构化解析与恢复：`tests/test_plan_schema.py`、`tests/test_plan_parser.py`
- MCP 协议与状态：`tests/test_mcp_client.py`、`tests/test_mcp_status.py`
- 事件幂等：`tests/test_event_idempotency.py`

这意味着下次再改 plan/tool_call，不再靠“玄学自信”上线。

#### 结果 4：排障路径更短，责任域更清晰

- 模型不可用问题和 MCP 鉴权问题可以分层定位。
- “是编排决策错了，还是 infra 调用挂了”不再混成一锅粥。

## 2. 这轮重构真正的收益（给进阶工程师）

### 收益一：把“接口稳定性”从口号变成工程约束

先锁 API 契约再改内核，听起来保守，但它是多人协作场景下最有效的重构杠杆。你会明显感到评审和联调冲突下降。

### 收益二：把“模型不稳定”变成“系统可处理”

结构化解析 + 恢复策略的价值，不在 happy path，而在模型输出半残时系统还能给出可预期行为。

### 收益三：把“可测试性”设计进架构

节点化后，测试粒度终于可以对准行为单元。过去改一个点全链路冒烟，现在能做到局部验证 + 端到端抽查。

### 收益四：为后续多节点编排留了正规扩展位

这次先做的是单轨主链路，但图结构已经把后续“多节点策略编排”预留好了，不用再把代码推倒重来。

## 3. 反思（顺便帮你省下未来两周）

1. 重构最怕“同时改契约 + 改内核 + 改依赖”。这次有意识分层，是关键。
2. 如果没有测试护栏，LangGraph 拆得再漂亮也会在联调阶段还债。
3. 排障文档要跟代码一起演进，不然团队知识会蒸发成聊天记录。

## 4. 给下一轮编排设计的建议

1. 把节点间共享能力（幂等、重试、去重、错误分级）策略化，不要写死在某个节点内部。
2. 给每个节点定义统一输入/输出 patch 契约，避免状态字段随手长。
3. 将可观测性（trace_id、node_latency、tool_error_class）纳入默认事件模型，不要靠临时日志救火。

## 5. 收尾

这次重构的价值，不是“我们用了 LangGraph”，而是“我们终于把编排当成可以长期维护的系统工程来做”。

至于那种“先写成一坨，后面再拆”的冲动，建议保留在周末 Hackathon。工作日的系统，还是让边界先说话。
