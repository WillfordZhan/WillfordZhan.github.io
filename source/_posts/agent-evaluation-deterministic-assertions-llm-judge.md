---
title: "把 Agent 评测器落到代码里：确定性断言、Golden 与双 LLM Judge"
date: 2026-08-18 11:13:12
categories:
  - "AI"
tags:
  - "AI Agent"
  - "自动化测试"
  - "LLM 评测"
  - "Pi"
  - "Java Runtime"
  - "AI工作日志"
source_archive:
  id: 20260818-agent-eval-deterministic-judge
  rel_path: source_materials/posts/20260818-agent-eval-deterministic-judge
  conversation_file: conversation.jsonl
---

现有评测仓库已经能登录 Java Gateway，创建 Pi 会话，再检查 Tool 调用次数、Tool 名和内部字段泄露。仓库里目前有 7 组 Scenario、20 个 Case，评测框架自身的 20 个离线测试可以全部通过。

双 LLM Judge 还没有进入运行链路。配置模板里虽然有 `judge` 节点，`Config`、`Runner` 和报告对象都没有读取或执行它。Golden 也只是一个 `type + note` 的文字说明，尚不能作为机器可校验的业务事实。

上一篇《[给 LLM Agent 搭自动化验收：分层用例、双裁判与 Golden 答案](/2026/08/13/agent-auto-test-llm-judge/)》讲了整体思路。这一篇继续往代码里走，把证据怎么采、硬断言怎么执行、Golden 怎么生成、Judge 看什么、最终结果由谁决定写清楚。

## 先看评测请求实际经过哪些模块

当前端到端链路如下：

```text
Scenario YAML
  -> Runner 渲染问题并登录测试账号
  -> POST /api/ai/conversations
  -> Java Gateway 解析当前用户和工厂
  -> Java Gateway 签发可信业务上下文
  -> Pi Runtime /ai/conversations
  -> Pi AgentSession 执行 agent loop
  -> Java MCP Tool 查询 ERP
  -> Pi JSONL 保存原始 SessionEntry
  -> Java Store 镜像 SessionEntry
  -> Runner 读取受保护的原生 SessionEntry
  -> 生成 AgentTrace
  -> 确定性断言
  -> Golden + 双 LLM Judge
  -> CaseReport
```

Java Gateway 仍是用户身份和当前工厂的可信入口。它把 `tenantId/userId` 签进请求头，Pi 的 `http-server.ts` 验签后才创建会话。`runtime.ts` 再把调用人快照写入 `java_gateway_context`，创建 `AgentSession`，并将本轮 Tool Call 和 Tool Result 落进 Pi JSONL。

评测器从 Java Gateway 发起请求，可以覆盖登录、业务上下文、Pi Runtime、Java MCP 和 ERP Tool 的完整链路。直接调用 Pi Runtime 会跳过 Java 身份解析，不适合作为 L2 端到端验收入口。

## 评测证据直接使用原生 SessionEntry

Scenario 不再定义自有消息类型，也不依赖面向 UI 的消息投影。评测器等待 create/chat 请求完成，再从受保护的 Java Store 读取 Pi 原生 `SessionEntry`。HTTP 超时、上游异常和 Store 读取失败直接归入运行错误，不进入 Scenario 的业务期望。

原生 Entry 保留完整 Agent 消息：

```text
assistant.content[].type = toolCall
assistant.content[].name = production_plan_search
assistant.content[].arguments = {...}

toolResult.toolCallId = call-1
toolResult.toolName = production_plan_search
toolResult.content = [...]
toolResult.isError = false
```

现有 `client.py` 已经通过 Java 内部 Store 读取 raw entries，但只提取了 Tool 名。下一步应把这层扩成完整 Trace Collector，同时继续使用内部 Token 和会话 owner 约束。管理台和用户侧消息投影继续服务展示，不进入评测协议。

## 先归一成 AgentTrace

断言逻辑直接操作原始 Entry，会逐渐堆出重复的遍历和关联代码。中间增加一个只负责归一化的 `AgentTrace`，后续断言和 Judge 都消费它。

```python
@dataclass(frozen=True)
class ToolExecution:
    call_id: str
    name: str
    arguments: dict[str, object]
    result: object | None
    is_error: bool


@dataclass(frozen=True)
class AgentTrace:
    conversation_id: str
    answer_text: str
    tool_executions: list[ToolExecution]
    caller_context: dict[str, str]
```

Trace Collector 的处理顺序保持固定：

```text
等待 create/chat 请求完成
  -> 读取原生 SessionEntry
提取最后一条 assistant 文本
  -> answer_text
提取 toolCall 名称、参数和 toolResult
按 tool_call_id 关联调用与结果
  -> 缺失结果标记为 incomplete
读取 java_gateway_context
  -> 取得会话创建时的 tenant/user 快照
输出不可变 AgentTrace
```

Trace 保留 `incomplete`，因为测试报告需要区分业务 Tool 返回失败、网络中断和没有配对结果。这项判断来自原生 Tool Call 与 Tool Result 的关联，不依赖额外消息类型。

## Scenario 只描述输入、硬约束和语义目标

当前 Scenario 可以表达单轮问题和几项基础断言：

```yaml
id: pp-detail-001
query: "查询今天 3 号炉的炉次安排"
expects:
  min_tools: 2
  tools:
    - production_plan_search
    - production_plan_detail
  ordered_tools: true
```

这个结构足够跑第一批只读 Case。多轮澄清、prepare-confirm、动态 Golden 和 Judge 还缺少稳定入口。扩展后的 Scenario 可以收成四块：

```yaml
id: pp-detail-001
stability: P0

input:
  turns:
    - user: "查询今天 3 号炉的炉次安排"

expects:
  tools:
    mode: subsequence
    names:
      - production_plan_search
      - production_plan_detail
  tool_results: all_success
  leakage_policy: erp_public_answer

golden:
  provider: db_query
  query_ref: production_plan_by_furnace_and_date
  params:
    furnace: "3号炉"
    date: "${today}"

judge:
  rubric: erp_answer_v1
  required: true
```

YAML 不存 SQL、Python 表达式或任意代码。`query_ref` 指向代码中登记并评审过的只读 Golden Provider。复杂领域校验继续写成有名字的断言函数，避免把 Scenario DSL 扩成另一门编程语言。

Tool 序列使用显式模式：

| 模式 | 语义 | 适用场景 |
| --- | --- | --- |
| `exact` | 名称和顺序完全一致 | 固定的 prepare-confirm 协议 |
| `subsequence` | 期望序列按顺序出现，允许中间多一次辅助查询 | 多跳查询 |
| `set` | 只要求调用集合，不关心顺序 | 可并行的独立查询 |
| `none` | 不允许调用 Tool | 闲聊、缺参数澄清 |

现有 `ordered_tools: true` 采用完整数组相等。Agent 多调用一次无害的主数据查询也会失败。`subsequence` 能表达“先搜索计划，再查详情”这类业务约束，同时不给每一步辅助动作写死位置。

## 确定性断言负责硬事实

确定性断言在 Judge 之前执行。失败后直接结束当前 Case，LLM 没有权力覆盖这些结果。

### 运行错误和链路完整性

```text
create/chat 请求完成，并能读取原生 Entry
  -> 继续执行 Trace 断言
HTTP 超时 / 上游失败 / Store 读取失败
  -> Case = ERROR
只有 tool_call，没有配对 tool_result
  -> Case = FAIL 或 ERROR，由 failure_kind 决定
```

`FAIL` 表示 Agent 行为违反期望，`ERROR` 表示测试基础设施、网络或被测服务没有完成一次可判定运行。两者分开后，发布报告不会把环境故障统计成模型能力下降。

### Tool 调用与结果

通用断言至少覆盖：

- Tool 调用数量的上下限。
- `exact/subsequence/set/none` 序列策略。
- 禁止调用的 Tool。
- 每个 `tool_call_id` 都有且只有一个结果。
- `toolResult.isError` 是否符合期望。
- 动态参数是否来自前一步结果。

最后一项适合 prepare-confirm。`prepare` 返回的 `preparationId` 每次不同，Scenario 不应硬编码具体值。Trace Collector 先捕获返回值，再校验 confirm 参数引用了同一个 ID：

```text
prepare_purchase_order.result.preparationId
  -> capture: preparation_id
confirm_purchase_order.arguments.preparationId
  -> assert equals capture(preparation_id)
```

这种关联检查验证的是通用协议，没有依赖某个样例 ID。

### tenant/user 与业务上下文

Runner 登录后已经能取得当前 `userId/deptId`。Trace Collector 再从 `java_gateway_context` 读取会话快照，两者必须一致：

```text
登录身份
  -> expected tenant/user
会话 raw entries
  -> actual java_gateway_context
expected == actual
  -> 上下文传播通过
```

Tool 的 tenant/user 不应来自 LLM 参数。需要验证 Tool 执行范围时，应读取 Java 服务端审计信息或受保护 Trace，不能在 Prompt 里要求模型复述内部 ID。

### 内部字段泄露

当前 Case 会重复配置 `planId`、`statusName`、`fnCode`。新增 Tool 后容易漏配。更稳定的做法是给 Tool 输出字段增加投影策略：

```text
PUBLIC       可进入最终回答
BUSINESS     需转换为业务语义后展示
INTERNAL     禁止进入最终回答
SENSITIVE    禁止进入 Judge 输入和最终回答
```

评测器根据 Tool Schema 元数据和模块级 `leakage_policy` 自动生成禁用字段集合。Scenario 的 `no_leak` 只补少量特殊词，不再复制整份字段黑名单。

## Golden 要保存事实，不保存一段“标准作文”

现有 Golden 只有一段 `note`：

```yaml
golden:
  type: fixture
  note: "返回今天的生产计划，状态使用中文表达"
```

这段文字能帮助人读用例，无法让 Judge 核对数量、状态和时间范围。Golden Provider 应输出结构化快照：

```json
{
  "source": "db_query",
  "queryRef": "production_plan_by_furnace_and_date",
  "generatedAt": "2026-08-18T11:00:00+08:00",
  "scope": {
    "tenant": "current-test-tenant"
  },
  "facts": [
    {"id": "fact-1", "field": "planCount", "value": 1},
    {"id": "fact-2", "field": "batchCount", "value": 5},
    {"id": "fact-3", "field": "status", "value": "IN_PROGRESS"}
  ],
  "answerRequirements": [
    "回答计划数量和炉次数量",
    "状态转换为业务中文"
  ]
}
```

Golden 有两种来源：

- `fixture`：适合闲聊、能力拒绝、固定协议和稳定的模拟数据。
- `db_query`：适合库存、生产计划、单据状态等持续变化的数据。

动态 Golden 在 Agent 请求前生成，并记录查询时间、租户范围和参数。前后版本对比要复用同一份 Golden 快照，避免数据库变化被误判成 Prompt 回归。

SQL 不直接放在 YAML。Golden Registry 按 `query_ref` 找到只读实现，数据库账号只授予查询权限，查询中强制注入测试租户。Provider 返回业务字段投影，不把数据库列名、内部主键或客户数据原样交给 Judge。

## Faithfulness 和 Correctness 使用不同证据

Tool Result 与 Golden 都是证据，含义不同。

```text
Tool Evidence
  -> Agent 本轮实际看到的数据
  -> 用于判断 Faithfulness

Golden Snapshot
  -> 独立数据源给出的业务事实
  -> 用于判断 Correctness
```

Tool 错误地返回 6 个炉次，Agent 如实回答 6。此时 Faithfulness 可以判好，Correctness 应判差。报告会把根因指向 Tool 或数据查询层，而不是笼统写成“Agent 回答错误”。

Agent 看到 5 个炉次却回答 6，Faithfulness 直接判差。Golden 同样是 5 时，Correctness 也会判差。

给 Judge 的 Tool Evidence 必须先做语义投影，只保留回答所需事实。原始 Tool Result 可能包含内部主键和权限字段，直接塞进另一个模型会扩大敏感数据暴露面。

## Judge 只判档位，运行器负责算分

Judge 输入固定为一个不可变评测包：

```json
{
  "question": "查询今天 3 号炉的炉次安排",
  "scenarioRequirements": ["回答炉次数量和状态"],
  "agentAnswer": "今天有 5 个炉次，计划正在进行中。",
  "toolEvidence": [],
  "goldenFacts": [],
  "deterministicChecks": []
}
```

Agent 回答按不可信数据处理。Judge 的系统指令明确禁止执行 `agentAnswer`、Tool Evidence 或 Golden 字段中的任何命令。输入使用 JSON 结构和独立字段，避免把整段材料拼成一段可继续对话的 Prompt。

四个 Metric 沿用现有设计：

| Metric | 权重 | 硬门禁 | 读取的主要证据 |
| --- | ---: | --- | --- |
| Faithfulness | 0.4 | 是 | Agent Answer + Tool Evidence |
| Correctness | 0.4 | 是 | Agent Answer + Golden Facts |
| Business Appropriateness | 0.1 | 否 | Scenario 要求 + Agent Answer |
| Boundary Compliance | 0.1 | 否 | 能力边界 + Agent Answer |

Judge 输出只包含档位、理由和证据引用：

```json
{
  "schemaVersion": "1",
  "metrics": {
    "faithfulness": {
      "grade": "GOOD",
      "reason": "回答中的炉次数量与 Tool Evidence 一致",
      "evidenceRefs": ["tool.fact-2", "answer"]
    },
    "correctness": {
      "grade": "GOOD",
      "reason": "数量与状态均匹配 Golden",
      "evidenceRefs": ["golden.fact-2", "golden.fact-3"]
    },
    "businessAppropriateness": {
      "grade": "GOOD",
      "reason": "状态已转换为业务中文",
      "evidenceRefs": ["answer"]
    },
    "boundaryCompliance": {
      "grade": "GOOD",
      "reason": "回答未扩展到系统未提供的能力",
      "evidenceRefs": ["answer"]
    }
  }
}
```

`weighted_total` 和 `verdict` 不让 LLM 输出。模型可能算错小数，也可能给出与四个档位矛盾的结论。运行器校验 JSON Schema 后统一计算：

```python
GRADE_SCORE = {"GOOD": 10, "PARTIAL": 5, "BAD": 0}


def score(metrics: dict[str, MetricGrade]) -> JudgeScore:
    total = sum(GRADE_SCORE[item.grade] * WEIGHTS[name]
                for name, item in metrics.items())
    hard_fail = any(metrics[name].grade == "BAD"
                    for name in ("faithfulness", "correctness"))
    verdict = "FAIL" if hard_fail else "PASS" if total >= 8.0 else "WARN"
    return JudgeScore(total=total, verdict=verdict)
```

这段计算需要普通单元测试覆盖全部档位组合。Judge 只提供语义判断，算术、阈值和发布门禁继续由确定性代码掌握。

两个模型共用一个很薄的 Provider 接口：

```python
class JudgeClient(Protocol):
    def judge(self, package: JudgePackage, rubric: Rubric) -> JudgeOutput:
        ...
```

Qwen 和 Codex Adapter 只处理鉴权、模型参数、请求发送与结构化响应解析。Rubric、Schema 校验、计分、重试和聚合不能分别写进两个 Adapter，否则同一个 Case 会被两套规则解释。

Judge 请求关闭 Tool、文件读取和网络搜索，只允许单轮结构化输出。它们与被测 Agent 使用不同的会话和上下文，也不继承 Pi 的 Skill、Java MCP Tool 或历史消息。

## 双 Judge 怎么聚合

Qwen 与 Codex 使用同一份冻结后的评测包，各自独立执行。两边看不到对方的输出。

```text
Judge Package
  -> Qwen Judge -> Schema 校验 -> 本地算分 -> verdict A
  -> Codex Judge -> Schema 校验 -> 本地算分 -> verdict B

A == B
  -> 使用共同 verdict
A != B
  -> 两个 Judge 各自重判一次
  -> 第二轮一致：使用第二轮 verdict
  -> 第二轮仍分歧：WARN + 人工复核
```

Judge 请求失败、超时或 JSON Schema 不合法时，结果记为 `JUDGE_ERROR`。它表示评测基础设施没有产出语义结论，不能写成 Agent `FAIL`。P0/P1 是否允许 `JUDGE_ERROR` 放行，由发布策略单独配置。

每次 Judge 记录这些版本信息：

- provider 和 model ID。
- Judge Prompt 版本与哈希。
- Rubric 版本。
- temperature 等采样参数。
- 原始结构化输出。
- 本地计算出的分数和 verdict。

低温可以降低波动，不能让 LLM 变成确定性函数。双模型、Golden、结构化输出和人工校准都保留。

## prepare-confirm 写操作怎么评

写操作需要多轮 Scenario：

```yaml
input:
  turns:
    - user: "创建一张采购订单"
      expects:
        tools:
          mode: exact
          names: [prepare_purchase_order]
        capture:
          preparation_id: "prepare_purchase_order.result.preparationId"

    - user: "确认创建"
      expects:
        tools:
          mode: exact
          names: [confirm_purchase_order]
        arguments:
          preparationId: "${capture.preparation_id}"
```

第一轮确定性断言检查 prepare 已调用、confirm 未调用，并捕获 `preparationId`。第二轮检查用户明确确认后才调用 confirm，且参数引用同一份 preparation。

副作用验证仍由数据库或业务查询接口完成：

```text
confirm 返回业务单号
  -> 只读查询该单号
  -> 校验租户、单据类型、行数和业务状态
  -> 重复 confirm
  -> 校验只存在一张单据并返回同一 receipt
```

写操作只能运行在隔离测试租户，并使用可追踪的幂等键或测试标识。共享测试数据无法可靠清理时，发布必跑集应保留 prepare，confirm 放进受控验收阶段。

## Runner 的完整执行顺序

```text
加载 Scenario
  -> 校验 DSL 与引用的 policy/query_ref/rubric
  -> 登录并解析测试身份
  -> 生成 Golden Snapshot
  -> 创建或续聊 Pi 会话
  -> 等待 create/chat 请求完成
  -> 读取受保护的原生 SessionEntry
  -> 归一化 AgentTrace
  -> 运行确定性断言
      -> FAIL：停止，不调用 Judge
      -> ERROR：停止，记录环境问题
      -> PASS：继续
  -> 投影 Tool Evidence
  -> 构建冻结 Judge Package
  -> 并行调用两个 Judge
  -> JSON Schema 校验与本地算分
  -> 聚合 PASS / FAIL / WARN / JUDGE_ERROR
  -> 写 CaseReport
```

确定性断言先行还能控制费用。Tool 序列已经错、内部字段已经泄露、上下文已经串租户时，再调用两个模型不会增加判定信息。

## 报告必须能回答“错在哪一层”

`CaseResult` 目前保存 PASS/FAIL/ERROR、回答文本、Tool 次数和断言结果。完整报告还需要补充证据和版本：

```json
{
  "caseId": "pp-detail-001",
  "outcome": "FAIL",
  "stage": "semantic_judge",
  "deterministic": {
    "verdict": "PASS",
    "checks": []
  },
  "golden": {
    "snapshotId": "golden-...",
    "facts": []
  },
  "judges": [],
  "versions": {
    "agentCommit": "<commit>",
    "agentModel": "<model>",
    "toolCatalogHash": "<hash>",
    "skillBundleHash": "<hash>",
    "judgePromptVersion": "erp-judge-v1"
  }
}
```

`stage` 至少区分：

```text
setup
agent_runtime
deterministic_assertion
golden_generation
semantic_judge
aggregation
```

报告看到 Tool 序列失败，可以先查 Skill、Tool Schema 和 Agent 计划；Tool 数据与 Golden 不一致，进入 Java Tool 或查询口径；Tool 数据正确但 Agent 回答编错，进入 Prompt、模型或上下文；两个 Judge 长期分歧，进入 Rubric 校准。

Prompt、Skill 或 Tool 描述变化时，前后两次运行必须复用同一组 Scenario 和 Golden Snapshot。否则分数变化里会混入业务数据变化，无法说明语义改动带来了什么影响。

## 评测器自身也要测试

评测系统不能只靠线上跑几条 Case 证明自己可用。它至少需要四类测试：

### Trace 和确定性断言

- raw Entry 中 Tool 名和参数的提取。
- `tool_call_id` 与 Tool Result 的配对。
- `exact/subsequence/set/none` 的完整真值表。
- 悬挂调用、重复结果和失败结果。
- tenant/user 快照不一致。
- 投影策略生成的字段泄露集合。

这些都是离线单元测试，不调用真实模型。

### Golden Provider

- `query_ref` 白名单。
- 参数与租户范围强制注入。
- 只读查询限制。
- DB 结果到业务 Facts 的投影。
- 空数据、重复数据和时间边界。

### Judge Contract

- 缺少 Metric、非法 grade、额外字段和坏 JSON。
- 档位到分值的映射。
- 硬门禁和阈值边界。
- 双 Judge 全部聚合组合。
- 超时、限流和重判次数上限。

这里使用假的 Judge Client 返回固定 JSON，普通单元测试不消耗模型 Token。

### Judge 校准集

从真实回归 Case 中保留一批由人标注的 `Judge Package + 期望档位`。修改 Rubric、Prompt 或 Judge 模型后重跑校准集，比较误放行、误拦截和各 Metric 的一致率。

Judge 校准集与业务 Scenario 分开维护。业务 Scenario 检查 Agent，校准集检查 Judge。

## 现有仓库到完整设计还差哪些模块

当前代码已经有：

- Scenario YAML 加载与参数化。
- Java Gateway 登录和 Pi 会话调用。
- 内部 Store Tool 名提取。
- Tool 次数、成功状态、Tool 名和泄露断言。
- JSON 汇总输出。
- 20 个离线单元测试。

后续可以按下面顺序补齐：

1. `TraceCollector`：把原生 SessionEntry 归一成 `AgentTrace`。
2. 确定性断言扩展：Tool 配对、序列模式、上下文、动态值捕获和投影策略。
3. `GoldenProvider`：先支持 fixture，再接只读 DB `query_ref`。
4. `JudgeClient`：两个 Provider 共用同一输入与输出 Schema。
5. `JudgeScorer/Aggregator`：代码侧算分、硬门禁、重判和分歧升级。
6. `CaseReport`：记录证据、版本、失败阶段和 Prompt 前后对比。

README 里的 M2 仍标记为未完成，但 Runner 和基础断言已经存在并通过测试。这类进度漂移也应在实现 Judge 前修正，避免后续 Agent 根据旧清单重复建设。

## 代价和边界

这套设计新增了受保护 Trace 读取、Golden 查询、两个 Judge 调用、重判和报告存储。语义验收会比普通接口测试慢，也会产生模型费用。

Golden 与 Tool Evidence 仍可能受动态数据影响。动态查询要记录时间窗口，回归对比要冻结快照，写操作要隔离测试租户。Judge 仍会误判，发布策略需要保留 WARN 和人工复核入口。

确定性协议继续留在代码里，业务事实进入 Golden，语义质量交给 Judge。三层证据各管一段，评测失败后才能沿着 Pi Runtime、Java Tool、业务数据或 Judge Rubric 继续定位。
