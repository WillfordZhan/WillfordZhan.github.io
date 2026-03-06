---
title: "LangGraph 编排重构复盘：一次把“能跑”改成“可证据化运行”的实战"
date: 2026-03-06 18:01:00
categories:
  - AI
tags:
  - AI工作日志
  - LangGraph
  - 重构复盘
  - Tool Schema
  - 联调实战
---

这次改造最有意思的地方，不是“把编排迁到 LangGraph”这件事本身，而是我们把一个常见工程陷阱踩出来又填平了：

> 到底是要“快速把 case 跑通”，还是要“把系统做成可长期治理”。

答案很明确：后者。

下面按真实时间线复盘，尽量给可复现证据，不讲玄学。

## 1. 讨论分歧：要不要用 fallback 快速过 case

中途一度出现典型诱惑：

1. 用户说“1号炉”，那就直接从 query 里正则提 `fnCode`。
2. schema 还没升级就先兼容参数名，保证联调先绿灯。

这类方案短期很爽，长期很贵。因为它会快速演变成“编排层半个业务解析器”。

最终我们把原则钉死：

1. **禁止 case 特判**。
2. **禁止 query 文本硬编码补参**。
3. 参数补全和澄清必须由 **tool schema 语义字段**驱动。

换句话说：补参逻辑是协议能力，不是对话技巧。

## 2. 改造目标：保外部资产，重写内部编排

目标是“重写编排侧”，不是“把所有层都改烂”。

保留不动的资产：

1. Infra（鉴权、存储、事件）
2. MCP 对接与工具执行平面
3. HTTP API 对外契约

改造聚焦在编排层：

1. LangGraph 单轨流程
2. 节点拆文件
3. schema-driven 的 tool 参数 resolve 与澄清

## 3. Java 侧改造：把工具参数从“文档”变成“可执行语义”

核心动作是让 `tools/list` 返回的 schema 可直接驱动编排。

### 3.1 参数注解扩展语义字段

新增并透传：

1. `x-normalizationRule`
2. `x-clarifyTemplate`
3. `x-aliasExamples`
4. `x-acceptedExamples`
5. `x-requiredWhen`

### 3.2 Tool schema 输出升级

`tools/list` 返回 `inputSchema`（兼容保留 `parameters`），并带参数级 `x-*` 字段。

### 3.3 工具定义补全语义

例如：

1. `fnCode` 标注 `extract_furnace_code_number`
2. `date` 标注 `relative_date_to_yyyy_mm_dd`
3. 每个关键参数给出 `x-clarifyTemplate`

### 3.4 Java 侧提交

提交信息：`feat: 增加工具参数语义 schema 并打通补参与澄清`

## 4. Python 侧改造：严格 schema 驱动，不做参数名猜测

核心函数是 `normalize_plan_with_tools`，行为约束如下：

1. 只读取 `inputSchema`/`parameters` 中显式声明的规则。
2. 按 `x-normalizationRule` 做归一化与缺参补全。
3. 缺参时优先拼 `x-clarifyTemplate` 作为澄清问题。

实现后我们做过一次“反向修正”：

1. 先临时加了向前兼容 fallback（按参数名补）。
2. 被明确要求撤回（理由：这是硬编码捷径）。
3. 立即删除 fallback，回到纯 schema-driven。

这次回滚非常关键，它保证了后续治理边界不再漂移。

### Python 侧提交

提交信息：`feat: 按 schema 驱动工具参数归一化与澄清流程`

## 5. 联调排障：先判协议，再判流程，最后判数据

这次联调如果只看“最终回答”，很容易误判。

正确排障顺序是：

1. Java MCP `tools/list` 是否真的返回了 `inputSchema + x-*`。
2. `react_plan` 是否从 `missing_arg` 转为真实 `tool_call`。
3. `tool_result` 失败到底是参数问题还是业务数据未命中。

### 5.1 第一轮现象（协议未生效）

当在线 Java 仍返回旧 schema 时，Case2 会持续停在“缺少 fnCode”的澄清。

这是协议问题，不是 LangGraph 节点逻辑问题。

### 5.2 服务重启后验证（协议生效）

确认 `tools/list` 已含 `inputSchema` 和 `x-normalizationRule/x-clarifyTemplate`。

之后再跑 case，链路变化为：

1. Case2 第二轮出现真实 `tool_call(arguments={"fnCode":"1"})`。
2. Case3 出现 `tool_call -> tool_result`，并携带归一化后的参数。

### 5.3 最终阻塞点

`tool_result` 返回“未找到匹配炉体，fnCode=1”。

这说明：

1. 编排链路已通。
2. 参数解析已通。
3. 业务数据不命中。

这个结论比“没跑通”更有价值，因为可执行动作变得明确：补业务数据或提供真实可命中炉号。

## 6. 典型用例结果（真实联调）

### Case1：问候语

链路：`user_message -> conversation_started -> llm_request -> react_plan -> final`

结果：通过。

### Case2：缺参澄清 -> 补参

1. 首轮按 schema 提示补 `fnCode`。
2. 次轮输入“1号炉”后触发 `tool_call`。
3. 由于数据未命中进入标准编码澄清。

结果：编排通过，数据未命中。

### Case3：今天 vs 昨天

1. 触发 `tool_call` 与 `tool_result`。
2. 参数归一化生效。
3. 数据未命中后进入澄清。

结果：编排通过，数据未命中。

## 7. 这次改造的工程收益

### 7.1 可维护性提升

新增工具参数时，路径稳定：

1. Java 注解声明语义
2. MCP schema 透出
3. Python resolve 执行规则
4. 测试覆盖

不再需要在编排里堆 if/else。

### 7.2 可观测性提升

现在可以基于事件链定位：

1. `react_plan.validationErrors`
2. `tool_call`
3. `tool_result`

故障定位从“猜测式”变成“证据式”。

### 7.3 治理边界稳定

最重要的一点：这次明确拒绝了“tricky pass”。

这让系统从“能跑一次”转向“能持续演进”。

## 8. 给做 Agent 编排的同学三条建议

1. 先把 tool schema 语义化，再谈 prompt 技巧。
2. 把“失败可解释”当成首要验收标准。
3. 真实联调必须分层看证据：协议 -> 编排 -> 数据。

## 结语

这次改造的最终形态并不炫技：

1. LangGraph 单轨。
2. schema 驱动补参与澄清。
3. 事件链可验证。

但它解决了一个更难的问题：

> 当需求变化时，系统还能不能继续被清晰地改下去。

这件事，比一次“看起来很聪明”的临时绿灯值钱得多。
