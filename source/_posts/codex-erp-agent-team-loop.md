---
title: "给 ERP AI Tool 开发组一支 Codex Agent Team：角色、Loop 与交接合同"
date: 2026-08-19 09:49:47
categories:
  - "AI"
tags:
  - "AI Agent"
  - "Codex"
  - "Sub-agent"
  - "ERP"
  - "Pi"
  - "Java Runtime"
  - "架构设计"
  - "AI工作日志"
source_archive:
  id: 20260819-codex-erp-agent-team-loop
  rel_path: source_materials/posts/20260819-codex-erp-agent-team-loop
  conversation_file: conversation.jsonl
---

接入一个 ERP 模块，交付物远不止一个 Tool 方法。

开发者要先从代码和 UI 里还原业务能力，找领域人员确认规则，再决定 Tool 粒度；实现完成后还要补模块 Skill、单元测试、Agent Scenario、Canary 和开发环境验收。查询和创建单据还有公共协议，模块实现不能各写一份。

我们准备把这条链路交给一支 Codex Sub-agent Team。人只处理领域知识、模块优先级和跨领域冲突。代码调研、实现、测试、部署和验收由固定 Loop 推进。

这套 Team 目前处于设计阶段。当前代码中已经存在 Pi Runtime、Java MCP 适配和仓管 Skill；四个 Agent TOML、Loop Skill、Contract Protocol 和标准化 Run 产物尚未落地。下面会把代码事实和拟议设计分开写。

## Pi 与 Java Runtime 已经提供了哪些基础能力

当前 ERP Agent 的调用链可以压缩成下面几层：

```text
ERP / APP
  -> Java Gateway
  -> Pi Java Runtime
  -> Pi AgentSession
  -> Java MCP Tool
  -> ERP Service
```

Java Gateway 负责可信用户上下文。Pi Runtime 负责会话、模型调用和 Agent loop。Java MCP 继续持有 Tool 目录、Schema、鉴权和业务执行。ERP Service 处理最终查询或写入。

### `PiConversationRuntime` 持有会话和 Agent loop

`runtime.ts` 中的 `PiConversationRuntime.runConversation()` 先按 `conversationId` 排队，再打开或恢复 Session，随后调用 `session.prompt()`。同一会话的请求串行执行，避免两个 `AgentSession` 同时追加会话历史；不同会话仍可并行。

调用完成后，Runtime 从 Session 里取得最后一条 Assistant 文本，并把新增 Entry 同步到 Java Conversation Store。模型失败和 Tool 失败已经落入 Session 时，同步仍会尝试执行。索引同步失败只记录旁路错误，不会把已经生成的回答伪装成对话失败。

对 Java 后端开发者来说，这一层接近“会话级事务协调器”：它负责打开上下文、执行一次 Agent loop、回收资源和推进持久化，但不实现采购、库存或生产计划规则。

### Java MCP 每轮提供当前 Tool 目录

`PiConversationRuntime.openSession()` 每次打开会话都会调用 `JavaMcpClient.createTools()`。Java 返回当前 Tool 描述，Runtime 再转换成 Pi 的 `ToolDefinition`，并在执行闭包中绑定本轮调用人。

`java-mcp.ts` 中的 `toPiTool()` 把三项可信数据固定进执行闭包：

- `conversationId`
- `tenantId`
- `userId`

模型只能提交 Tool 的业务参数。它无法在参数中替换会话、租户或用户。Tool 调用统一经过 Java `/tools/call`，内部鉴权头、超时、业务错误和结果格式也集中在这一层处理。

这条边界对后续 Agent Team 很重要。Sub-agent 可以设计和实现 Tool，可信身份、权限和业务事务仍留在 Java 服务端。Prompt 无法代替运行时安全边界。

### Skill 使用受限的渐进加载

`openSession()` 创建 `DefaultResourceLoader` 时关闭工作目录 Context 和全局 Skill，只加载随 Runtime 发布的 Skill 目录。内置 Tool 也被关闭，模型只能使用 Java 业务 Tool 和一个受限 `read`。

`skill-read.ts` 的 `createSkillReadTool()` 会先把已登记 Skill 路径解析成真实路径白名单。模型传入绝对路径、`..` 或符号链接都不能扩大读取范围。单个 Skill 还受 64 KiB 上限约束。

因此，模块 Skill 可以随 Runtime 评审和发布，同时保留 Pi 的渐进加载机制。Agent Team 后续创建 Skill 时，可以直接接入这条现有链路。

## 一个万能开发 Agent 会把职责搅在一起

这项工作最初可以交给一个 Agent：读代码、问需求、写 Tool、跑测试。模块变多后，几个冲突会同时出现。

第一，代码证据和领域判断容易混在一起。页面上有一个按钮，只能证明当前 UI 暴露了这个动作，不能直接推出它是一个独立领域命令。

第二，实现者自己定义测试期望，失败时很容易把合同改成“当前代码的行为”。测试失去了独立验收作用。

第三，多个 Agent 同时修改业务代码会增加共享工作区冲突。并行调研可以节省时间，并行写同一组 Tool、Skill 和测试通常会增加返工。

第四，聊天记录承载不了长期交接。另一名员工或另一个 Codex 会话接手时，需要重新猜测哪些结论已经批准、当前卡在哪个阶段、哪些测试证据仍然有效。

设计因此固定为四个执行角色，再由主 Agent 持有状态机。

## 四个角色分别交付什么

| 角色 | 主要输入 | 主要输出 | 边界 |
| --- | --- | --- | --- |
| Explorer | Run Contract、目标模块、允许访问的仓库与环境 | 代码/UI 证据、调用链、能力清单、Tool 规范基线、未知项 | 只读，不补业务规则，不决定 Tool 粒度 |
| Domain Modeler | Explorer 证据、领域人员回答 | 领域模型、Tool Catalog、Skill Topology、待确认问题 | 不修改代码，不用页面结构代替领域边界 |
| Implementer | 已批准合同、现行 Tool 规范基线 | Tool、Skill、单元/契约测试、部署证据 | 唯一业务代码写入者，不改合同迁就实现 |
| Evaluator | 领域模型、Tool/Skill 合同、实现证据 | Scenario、确定性断言、LLM Judge 结果、失败归因 | 不修改业务实现，不让 Judge 覆盖硬失败 |

### Explorer：先把事实收干净

Explorer 同时看 Java 服务、Pi Runtime、ERP 前端和业务 UI。它要追踪真实入口、DTO、校验、权限、数据库查询和异常路径，并把四类信息分开：

- 代码事实
- UI 事实
- 文档描述
- 工程推断

代码和 UI 互不依赖时，可以启动两个 Explorer 并行调研。主 Agent 合并证据后再推进状态，避免 Domain Modeler 在证据不完整时开始建模。

Explorer 还负责定位当前生效的查询 Tool、创建单据流程、公共实现、规范文档和契约测试。这些来源会形成 `sourceBaselines`，供后续角色引用。

### Domain Modeler：把业务语言变成 Tool 和 Skill 合同

Domain Modeler 兼产品职责。它根据证据整理统一语言、实体、值对象、聚合、命令、查询、不变量和状态变化，再输出两份目录：

```text
Tool Catalog
  -> 每个 Tool 的业务意图、领域、输入输出、错误、权限和边界

Skill Topology
  -> 模块 Skill、跨模块 Skill、使用的 Tool、澄清点和停止条件
```

领域知识缺失时，它返回 `domain_gap`。主 Agent 再向领域负责人提一个窄问题。日常代码选择、测试实现和部署操作不需要反复找人确认。

### Implementer：串行持有业务代码

Implementer 是唯一允许修改业务代码的角色。它消费已通过门禁的合同，复用现行查询和创建单据框架，补齐 Tool、Skill、单元测试和契约测试。

合同无法落地时，Implementer 返回 `contract_defect`。它不能通过放宽测试、增加样例特判或在模块里复制一套公共协议来完成任务。

部署也由 Implementer 执行，但只能推进到 Run Contract 授权的环境。生产发布、破坏性迁移和权限扩大继续要求单独授权。

### Evaluator：从合同生成验收证据

Evaluator 从领域模型和 Tool/Skill 合同派生 Scenario。每个 Scenario 明确：

- 期望调用的 Tool
- 允许出现的 Tool
- 禁止调用的 Tool
- 参数和结果约束
- 最终回答的业务目标

确定性断言先检查 Tool 调用、参数、结果、身份上下文和确认流程。硬断言通过后，LLM Judge 再评估 Faithfulness、Correctness、Business Appropriateness 和 Boundary Compliance。

这种顺序保留了测试的判定边界。LLM 可以评价语义质量，没有权力把“调用了禁止 Tool”改判成通过。

## 主 Agent 是 Loop Owner，不增加第五个角色

主 Agent 已经拥有创建 Sub-agent、等待结果、追加任务和收敛输出的能力。再增加一个“编排专家”会多出一层交接，同时出现两个全局状态持有者。

设计中只有主 Agent 可以写 `run.json`。四个执行角色提交阶段结果，主 Agent 校验门禁、记录状态、分类失败并选择下一步。

用 Java 工作流的说法，主 Agent 接近状态机引擎，四个角色接近各状态的 Handler。Handler 处理局部任务，状态迁移由引擎统一提交。

主流程如下：

```text
INIT
  -> DISCOVERY
  -> DOMAIN_MODELING
  -> CONTRACT_DESIGN
  -> IMPLEMENTATION
  -> LOCAL_VERIFICATION
  -> CANARY_VERIFICATION
  -> DEV_ACCEPTANCE
  -> DONE
```

还有三个辅助状态：

- `WAITING_USER`：等待领域知识、模块优先级或跨领域决定
- `BLOCKED`：权限、环境或外部依赖持续阻塞
- `CANCELLED`：用户终止 Run

状态与角色保持固定归属：

| 状态 | 主执行者 | 交接动作 |
| --- | --- | --- |
| `INIT` | 主 Agent | 固化授权范围和成功条件 |
| `DISCOVERY` | Explorer | 交付证据和规范基线 |
| `DOMAIN_MODELING` | Domain Modeler | 交付领域模型、Tool Catalog 和 Skill Topology |
| `CONTRACT_DESIGN` | Domain Modeler | Evaluator 从可测性反审合同 |
| `IMPLEMENTATION` | Implementer | 交付实现、测试和变更证据 |
| `LOCAL_VERIFICATION` | Evaluator | 执行本地验收并归因失败 |
| `CANARY_VERIFICATION` | Implementer + Evaluator | 一个部署，一个验收 |
| `DEV_ACCEPTANCE` | Implementer + Evaluator | 一个部署，一个验收 |
| `DONE` | 主 Agent | 汇总通过门禁的交付证据 |

`targetStage` 控制本次 Run 的授权上限。一次只读调研可以在 `DISCOVERY` 停止；一次本地开发可以在 `LOCAL_VERIFICATION` 停止。状态机不会因为后面存在部署阶段就自动扩大权限。

## Run Contract 先限定这次允许做什么

每次启动 Loop，主 Agent 先写一份 Run Contract：

```json
{
  "runId": "run-20260819-001",
  "objective": "完成目标模块的 Tool、Skill 和本地验收",
  "scope": {
    "modules": ["target-module"],
    "repositories": ["agent-runtime", "java-erp-service"],
    "environments": ["local"]
  },
  "targetStage": "LOCAL_VERIFICATION",
  "constraints": [],
  "successCriteria": [
    "Tool 和模块 Skill 同时交付",
    "L0/L1/L2 本地门禁通过"
  ],
  "userDecisionTopics": [
    "领域知识",
    "模块优先级",
    "跨领域冲突"
  ]
}
```

Run Contract 保存用户授权。`sourceBaselines` 属于运行元数据，由 Explorer 在 Discovery 阶段补齐。两者分开以后，代码版本变化不会被误写成用户授权变化。

## 交接靠文件，不靠聊天记忆

计划创建的 Team 资产分成几层：

```text
AGENTS.md
  -> Loop SKILL.md
       -> loop.md
       -> contract-protocol.md
       -> evaluation-protocol.md
       -> Agent TOML

当前 Tool 实现 / 规范 / 契约测试
  -> discovery.md 中的 source baseline
  -> design.md 中的能力映射
  -> verification.json 中的验收证据
```

每个文件只持有一种信息：

| 资产 | 保存内容 |
| --- | --- |
| `AGENTS.md` | 仓库工程、安全和操作约束 |
| `SKILL.md` | Loop 入口、触发条件和引用加载顺序 |
| `loop.md` | 状态、门禁、失败路由和停止条件 |
| `contract-protocol.md` | Run Contract、阶段输入输出和交接校验 |
| `evaluation-protocol.md` | Scenario、断言、Judge 和 verdict |
| Agent TOML | 单一角色的职责、证据要求和禁止事项 |
| `run.json` | 本次 Run 的状态、授权、基线、失败和产物路径 |
| `discovery.md` | 代码/UI 证据、调用链、能力清单和未知项 |
| `design.md` | 领域模型、Tool Catalog、Skill Topology 和测试合同 |
| `verification.json` | 硬断言、Tool Trace、Judge 和失败归因 |
| `delivery.md` | 变更、测试、部署和剩余风险 |

主 Agent 给 Sub-agent 的上下文只包含 Run Contract、已通过门禁的上游产物和当前基线引用。聊天里的临时讨论不能直接进入下游实现。

## Loop 不复制 Tool 协议

查询 Framework 和创建单据 Framework 由独立工作流建设，已经有单独的设计记录：《[给 ERP AI Tools 收一套统一协议：commandType、prepare-confirm 与 Query Framework](/2026/08/18/erp-ai-tool-command-query-framework/)》。

Loop 只要求各角色读取当时仓库里的现行查询 Tool、创建单据流程、规范文档和契约测试。它不再维护另一份 `tool-protocol.md`。

Explorer 为这些来源记录路径、版本或内容摘要。Implementer 和 Evaluator 开始工作前，主 Agent 重新检查基线。基线发生变化时，当前失败类型记为 `baseline_changed`，状态回到 `DISCOVERY`，受影响的下游产物失效。

这项设计会增加一次基线复核，也避免并行工作流更新公共协议后，模块 Agent 继续拿旧字段和旧测试开发。

规范文档、公共实现和契约测试互相矛盾时，Explorer 把差异写入证据，主 Agent 返回 `contract_defect`。任何角色都不能静默挑选一份更方便的解释。

## Tool 和 Skill 必须一起交付

Tool 提供稳定、结构化、可验证的业务能力。Skill 负责选择 Tool、组织调用顺序、检查证据、澄清信息和停止流程。

当前仓管 Skill 已经展示了这条分工：

1. 先查询两类主数据，用查询结果区分业务链路。
2. 主数据未唯一确定时继续查询或询问用户。
3. 创建出库单前检查仓库和库存。
4. 创建单据先生成预览，再等待明确确认。
5. 出库确认前重新查询库存。
6. 物料、仓库、数量或方向变化后，旧预览失效。

这些编排规则适合留在 Skill。租户鉴权、数据库事务、幂等、并发控制和参数安全校验仍由 Java Runtime 与业务服务执行。

每个业务模块至少交付一个模块级 Skill。跨模块场景可以增加跨模块 Skill，但不能用一个庞大的总 Skill 取代各模块的基础能力组织。

```text
领域模型
  -> Tool Catalog
  -> Tool 实现
  -> Module Skill / Cross-domain Skill
  -> Scenario Cases
  -> 确定性断言 + LLM Judge
```

## 失败要退回产生缺陷的阶段

整个 Loop 无差别重跑会浪费调研和测试成本。失败路由按能力缺口分类：

| failureType | 含义 | 回退状态 |
| --- | --- | --- |
| `evidence_gap` | 缺少代码、UI、接口或数据证据 | `DISCOVERY` |
| `baseline_changed` | Tool 规范或公共实现已变化 | `DISCOVERY` |
| `domain_gap` | 缺少业务知识或领域决定 | `WAITING_USER` |
| `contract_defect` | Tool、Skill 或测试合同矛盾 | `CONTRACT_DESIGN` |
| `implementation_defect` | 实现不符合合同 | `IMPLEMENTATION` |
| `environment_failure` | 网络、凭证、服务或部署环境异常 | 当前阶段重试，持续失败后阻塞 |
| `evaluation_warning` | Judge 分歧或非门禁语义问题 | 当前状态人工复核或记录风险 |

同一根因最多自动重试两次。第三次仍失败，主 Agent 停止循环并保存已执行动作、证据和恢复条件。这里按结构化失败类型路由，不根据模块名、问题文本或固定样例写分支。

## 评测沿用硬断言加 LLM Judge

评测部分直接复用现有分层设计，不在 Team Loop 中再造一套运行器：

| 层 | 检查内容 |
| --- | --- |
| L0 | 单元测试和纯函数验证 |
| L1 | Tool Schema、错误、权限和副作用合同 |
| L2 | Agent Scenario、Tool 选择和编排 |
| L3 | Canary/DEV 健康检查和关键冒烟 |

确定性断言先读取 Pi 的结构化 Tool Call 和 Tool Result，检查期望/禁止 Tool、参数、结果、身份上下文和流程约束。通过后才运行 LLM Judge。

Judge 的输入包含用户问题、结构化 Tool 证据、Golden 和最终回答。双 Judge、分歧处理与 Golden Provider 的详细设计记录在《[把 Agent 评测器落到代码里：确定性断言、Golden 与双 LLM Judge](/2026/08/18/agent-evaluation-deterministic-assertions-llm-judge/)》中。

## 第一轮先验证 Team，不开发新模块

Tool 公共规范改造完成后，第一轮 Run 计划使用已有仓管和生产计划能力做只读校准，目标停在 `LOCAL_VERIFICATION`。

执行顺序如下：

1. Explorer 从代码、Skill、接口、规范和测试建立 Tool 基线。
2. Domain Modeler 独立还原领域模型、Tool Catalog 和 Skill Topology。
3. Evaluator 根据合同设计 Scenario，并与现有测试对照。
4. Implementer 只修复 Agent TOML、Loop 文档和交接协议，不改业务实现。
5. 主 Agent 输出 Team 验证报告。

验证里还会注入几类通用故障：证据缺失、领域规则歧义、合同冲突、实现测试失败、Judge 与硬断言冲突、环境不可用。验收目标是确认失败能退回正确阶段，而非证明某个仓管样例可以跑通。

Team 通过校准后，再进入 BOM 和物料管理等新模块。这样能先暴露角色 Prompt、交接字段和状态路由的问题，避免把 Team 缺陷混进首个新模块的业务代码。

## 这套设计增加了哪些维护成本

四个角色会产生更多交接。模块较小、规则清楚、只改一个 Tool 时，完整 Loop 可能比单 Agent 慢。MVP 保留四个角色，不继续拆分代码 Explorer、UI Explorer、部署者或独立 Judge 角色。

`sourceBaselines` 需要记录和复核版本。它解决的是并行工作流造成的规范漂移，不承担通用依赖管理。公共协议稳定后，这部分开销会下降。

LLM Judge 会增加调用成本和非确定性。硬约束继续放在确定性断言，Judge 只处理语义判断，可以控制这部分影响。

多个员工使用各自的 Codex 账号时，无法共享正在运行的 Sub-agent 树。`run.json` 和阶段产物只支持基于 Git 的异步交接。实时队列、集中锁和统一审计出现明确需求后，再评估独立控制面。

MVP 也不创建 Plugin、不开发新的 Agent RPC、不写单独的线程池或队列。Codex 已经提供 Sub-agent 调度能力，Markdown、TOML 和 JSON 足以完成第一轮验证。

接下来的实现顺序已经收窄为六步：

1. 定义 `contract-protocol.md` 和 `run.json`。
2. 定义 `loop.md` 的状态、门禁和失败路由。
3. 创建四个 Agent TOML。
4. 创建 Loop `SKILL.md`。
5. 定义 `evaluation-protocol.md`，接入现有 Scenario 仓库。
6. 对仓管和生产计划做只读校准。

做到第六步，才能判断这支 Team 是否值得接手第一个新 ERP 模块。

## 相关资料

- [Codex use cases](https://developers.openai.com/codex/use-cases)
- [Codex Subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents)
- [Build skills](https://learn.chatgpt.com/docs/build-skills)
- [Custom instructions with AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
