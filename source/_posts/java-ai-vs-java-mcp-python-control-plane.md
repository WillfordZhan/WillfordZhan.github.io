---
title: "纯 Java AI vs Java MCP + Python Control Plane：重构方案与落地模块解析"
date: 2026-02-20 15:36:27
categories:
  - "AI"
tags:
  - "AI工作日志"
  - "架构设计"
  - "AI工程"
  - "MCP"
  - "Java"
  - "Python"
---

## 背景

第一版 AI 能力是典型的纯 Java 单体实现：请求进入 Java Web 层后，直接在同一进程内完成模型调用、工具路由、业务执行与响应拼装。这个方案早期上线快，但随着需求从「能用」走向「可控、可观测、可扩展」，问题开始集中暴露：

1. 推理编排和业务工具耦合，修改工具策略会影响主链路稳定性。
2. 流式输出与长任务状态管理能力弱，`run` 生命周期缺少统一抽象。
3. 多工具权限控制分散在业务代码里，审计链路不完整。
4. Java 侧迭代成本高，难以快速试验 Agent 策略和协议演进。

因此本次重构目标不是简单“拆服务”，而是明确控制平面与执行平面的边界：**Java 负责工具执行的稳定性与治理；Python 负责运行编排与流式交互体验**。

## 现状：纯 Java AI 实现的结构与瓶颈

当前纯 Java 方案的主流程可以抽象为：

`HTTP 请求 -> Java Controller -> Prompt/Tool 组装 -> 模型调用 -> 工具执行 -> 返回结果`

这个流程的问题不在“能否跑通”，而在于以下三个工程属性不足：

1. 生命周期治理不足：缺少 `run` 级状态机，失败恢复、断线重连、事件重放困难。
2. 观测粒度不足：日志多为文本级，缺少标准化 `tool_call/tool_result` 事件和 trace 关联。
3. 协议演进困难：工具调用协议与 Java 内部对象绑定，跨语言复用成本高。

## 关键差异对比表

| 维度 | 纯 Java AI（当前） | Java MCP + Python Control Plane（目标） | 关键收益 |
| --- | --- | --- | --- |
| 架构边界 | 编排与执行同进程 | 控制平面与执行平面分离 | 解耦迭代节奏 |
| 工具协议 | 内部对象/方法调用为主 | 统一 MCP 协议 + tool registry | 跨语言一致性 |
| 运行模型 | 请求级同步思维 | `run` 异步生命周期 + SSE 事件流 | 可恢复、可追踪 |
| 权限治理 | 业务代码内零散校验 | `authz-lite` 前置校验 | 风险收敛到入口 |
| 可观测性 | 文本日志为主 | 标准事件 + `ai.tool.invoke` 结构化日志 | 排障效率提升 |
| 扩展路径 | 增加工具需改主流程 | registry 注册 + dispatcher 分发 | 新工具接入更快 |
| 失败处理 | 失败点分散 | run 状态机 + 可回放事件流 | 故障定位更确定 |
| 研发效率 | Java 改动链路长 | Python 快速试验，Java 保持稳定内核 | 试验速度与稳定性兼得 |

## 目标架构图（文字图）

```text
[Client/UI]
   |
   | HTTP POST /ai/runs
   v
[Python Control Plane]
  - Run API (/ai/runs)
  - Orchestrator (plan/step/retry)
  - SSE Stream (/ai/runs/{id}/events)
  - MCP Client
   |
   | MCP tool call
   v
[Java MCP Server]
  - MCP Entry
  - Tool Registry
  - Authz-lite
  - Dispatcher
  - Tool Adapters (domain services)
   |
   v
[Business Systems / DB / Device APIs]
```

## 调用链设计（端到端）

1. 客户端提交问题到 Python `POST /ai/runs`，返回 `runId`（异步）。
2. Orchestrator 创建步骤并触发模型推理，决定是否调用工具。
3. 若需工具，MCP Client 发起标准化 `tool_call` 到 Java MCP 入口。
4. Java 侧经 `registry -> authz-lite -> dispatcher` 找到目标工具并执行。
5. Java 产出 `ai.tool.invoke` 结构化日志与工具结果，返回 MCP 响应。
6. Python 将 `tool_result` 写入运行上下文，继续下一步推理。
7. SSE 端持续推送 `run_started / step / tool_call / tool_result / completed|failed`。

这条调用链的关键是：**控制平面只做编排，不承载业务副作用；执行平面只做可治理的工具执行，不绑推理策略。**

## 模块拆分与职责

### Java 侧（执行平面）

1. `mcp-entry`：协议入口、请求反序列化、trace 透传。
2. `tool-registry`：工具元数据与 handler 注册，支持动态发现或配置注册。
3. `authz-lite`：轻量权限校验（租户、角色、工具级 allowlist）。
4. `dispatcher`：统一分发、超时控制、错误码标准化。
5. `ai.tool.invoke` 日志：记录 `runId/toolName/argsDigest/latency/resultCode`，支持审计与性能分析。

### Python 侧（控制平面）

1. `/ai/runs`：异步创建运行，立即返回 `runId`。
2. `/ai/runs/{runId}/events`：SSE 事件流，支持重连后的 replay + tail。
3. `orchestrator`：步骤状态机、重试策略、工具调用决策。
4. `mcp-client`：与 Java MCP 协议通信、异常映射、幂等请求头传递。

## 已落地模块（本次盘点）

目前已经看到并可归类为“已落地”的能力有：

1. Java MCP 入口层（可接收 MCP tool 调用）。
2. Java tool registry（工具注册与查找能力）。
3. Java `authz-lite`（轻量授权校验链路）。
4. Java dispatcher（统一调度与执行入口）。
5. Java `ai.tool.invoke` 日志（工具调用审计关键埋点）。
6. Python `/ai/runs` + SSE 事件流接口骨架。
7. Python MCP client（控制平面到执行平面的协议桥接）。

这意味着架构重构不是“纸面设计”，而是已经完成了核心骨架打通，后续重点转向稳定性与规范化。

## 实施计划（阶段里程碑）

### Phase 1：协议与入口固化（已完成主体）

目标：打通 Python -> Java MCP 的最小闭环。  
里程碑：

1. `POST /ai/runs` 创建 run。
2. Java MCP 入口可执行至少一个真实工具。
3. SSE 能看到 `tool_call/tool_result` 基础事件。

### Phase 2：治理能力补齐

目标：把“能跑”升级为“可控”。  
里程碑：

1. `authz-lite` 从静态规则升级到可配置策略。
2. dispatcher 增加超时分级与熔断隔离。
3. `ai.tool.invoke` 接入统一 trace/span 关联。

### Phase 3：运行时可靠性

目标：把“可控”升级为“可恢复”。  
里程碑：

1. run 状态机补齐中断恢复与重试幂等。
2. SSE 支持断线续传与游标回放。
3. 工具失败分类（可重试/不可重试/需人工干预）。

### Phase 4：规模化扩展

目标：低成本扩工具与跨团队协作。  
里程碑：

1. 工具接入模板化（注册、鉴权、日志、测试用例）。
2. 多租户策略隔离与限流策略下沉。
3. 性能基准与容量模型稳定输出。

## 验收标准（Definition of Done）

1. 功能正确性：核心业务工具在新链路调用成功率 >= 99.9%。
2. 时延目标：P95 工具调用端到端时延 <= 800ms（不含大模型本体推理）。
3. 可观测性：`runId` 能串联 API 日志、MCP 调用日志、错误事件。
4. 稳定性：单工具故障不拖垮 run 主链路，错误可降级可回传。
5. 回归保障：关键工具具备契约测试 + 冒烟测试 + 回滚演练记录。

## 面试亮点（架构师视角）

1. **控制平面/执行平面分离**：把“策略迭代快”与“执行稳定”矛盾拆开，组织协作效率显著提升。
2. **协议先行**：MCP 将工具调用变成标准接口，降低语言与团队边界摩擦。
3. **run 生命周期建模**：从“请求响应”升级到“可追踪任务”，天然支持 SSE、重放、恢复。
4. **治理内建而非补丁**：`authz-lite + dispatcher + ai.tool.invoke` 在入口前置，风险可控可审计。
5. **渐进式重构**：先打通骨架，再补治理和可靠性，避免大爆炸式改造风险。

## 风险与回滚策略

### 主要风险

1. 双栈复杂度上升：Python 与 Java 边界如果定义不清，会形成新的耦合。
2. 协议漂移：MCP schema 版本治理缺失会造成灰度失败。
3. 观测碎片化：日志、事件、trace 口径不一致会影响排障。

### 回滚方案

1. **流量级回滚**：网关开关将特定租户/场景切回纯 Java 旧链路。
2. **能力级回滚**：按工具维度关闭 MCP 路由，仅保留白名单工具走新链路。
3. **版本级回滚**：保持 Python orchestrator 与 Java MCP 的最近稳定版本镜像，可一键回退。
4. **数据级保障**：run 事件与日志保留，回滚后仍可复盘失败路径。

回滚原则：**先止损再定位，先降级再修复**。如果新链路在连续窗口内错误率超阈值（如 5 分钟 > 1%），自动触发降级。

## 结语

这次重构的价值不只是“多了一个 Python 服务”，而是建立了一个可持续演进的 AI 工程底座：  
Java 守住执行稳定性与治理边界，Python 承担编排创新与交互体验。  
在这个边界之上，未来接入更多工具、模型与业务场景都会更可控。
