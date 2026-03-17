---
title: "从顶级 AI Agent 架构视角看这套 Python Agent 项目"
date: 2026-03-17 21:09:27
categories:
  - "AI"
tags:
  - "AI Agent"
  - "架构评审"
  - "MCP"
  - "Python"
  - "LLM"
  - "AI工作日志"
source_archive:
  id: 20260317-ai-agent-python-agent
  rel_path: source_materials/posts/20260317-ai-agent-python-agent
  conversation_file: conversation.jsonl
---

我先给结论。

这个项目现在不是“做不成事”，而是已经到了一个很典型的拐点：

- 作为单智能体、少量工具、强业务约束的企业 Agent，它已经能跑通主链。
- 但它的可靠性主要靠 `prompt + 少量 runtime 约束 + MCP 双视图` 顶住。
- 一旦继续加工具、加查询类型、加多跳深度，复杂度会明显上升，而且会越来越依赖 prompt 特判。

从顶级 AI Agent 架构视角看，当前最值得做的不是“再补几条提示词”，而是把运行时从“隐式 ReAct 循环”升级成“显式计划/证据/验证”体系。

**一、代码里已经能直接证实的问题**
这些不是推断，是我从代码直接看到的。

1. 现在的主 runtime 仍然是单循环 ReAct 变体，不是显式 planner/verifier。
见 `app/agent/runner.py`。  
当前流程本质上是：
- 组 prompt
- 模型决定是否调工具
- 执行工具
- 再让模型决定是否继续或直接回答

问题是：
- 没有显式 `plan_state`
- 没有显式 `evidence_needed / evidence_satisfied`
- 没有独立 verifier step
- `latest_tool_result` 是单变量，天然更偏“最后一跳驱动回答”

这会导致多跳场景里，“证据是否足够”主要靠模型自己感觉。

2. prompt 里仍然存在明显的特异化规则和 case 式 few-shot。
见 `app/agent/context.py`。  
里面已经不只是通用原则，而是直接写到了：
- 特定 query 模式
- 特定 tool 组合
- 特定业务追问链路
- 特定 few-shot 示例

这能短期提效果，但长期会带来两个问题：
- prompt 越来越像规则仓库
- 泛化能力越来越弱，新增场景容易互相污染

3. answer 层已经做了不错的“语义化 answerData”收口，但规划层没有同等级的结构化约束。
见：
- `app/agent/runner.py`
- `app/mcp_client.py`

现在你们已经有：
- `planData`
- `answerData`
- `answerSchema`

这在“防字段泄漏、防 raw DTO 直出”上是对的。  
但 planning 侧仍主要依赖：
- transcript
- tool schema
- prompt instructions

也就是说：
- answer 已经开始结构化
- planning 还没有真正结构化

这会形成不对称：回答越来越稳，规划仍然容易飘。

4. guardrail 目前更像“安全与内部信息泄漏防护”，不是“事实性/证据充分性/输出合规性”全套验证器。
见 `app/agent/guardrails.py`。

当前 guardrail 做得好的地方：
- prompt 泄漏
- 内部工具清单泄漏
- reasoning dump
- secret-like 内容

但明显没做系统化的：
- groundedness / hallucination check
- schema compliance check
- evidence sufficiency check
- answer-vs-tool-result consistency check

所以它现在是“安全 guardrail”，不是“质量 verifier”。

5. 评测体系还不够 agent-native。
从依赖和测试看：
- 没有 trace grading / dataset eval / regression scoring
- 主要还是单测 + 真实联调脚本
见：
- `requirements.txt`
- `tests/`

这说明当前测试能发现协议/回归问题，但对“规划是否正确”“多跳是否必要”“何时过早停止”这类 agent 问题，缺少体系化衡量。

6. `langgraph` 还在依赖里，但当前主编排已经完全不用它。
见 `requirements.txt`。  
这不是功能 bug，但说明技术栈有历史包袱，容易误导后续维护者。

**二、和业界 SOTA 对照后的判断**
这部分我明确区分“公开资料支持的事实”和“我基于你们代码做的架构判断”。

**公开资料能直接支持的点**

1. 工具描述质量非常重要，但不是全部。  
Anthropic 官方明确强调，tool description 应详细说明：
- 做什么
- 什么时候用
- 什么时候不用
- 参数含义
- 限制条件  
来源：
- Anthropic tool use docs: https://platform.claude.com/docs/en/agents-and-tools/tool-use/implement-tool-use

2. 多步 agent 更稳的方向是 plan-and-execute / replan，而不是纯 ReAct 循环。  
LangChain/LangGraph 对 planning agents 的公开总结很明确：  
`planner -> task execution -> joiner/replan or finish` 是提升多步任务质量和效率的主流范式。  
来源：
- LangChain planning agents: https://blog.langchain.com/planning-agents/

3. 生产级 agent 需要 trace、eval、workflow-level grading。  
OpenAI 官方现在明确把：
- full trace
- trace grading
- datasets/evals  
作为 agent 优化主线。  
来源：
- Agents SDK: https://developers.openai.com/api/docs/guides/agents-sdk
- Trace grading: https://developers.openai.com/api/docs/guides/trace-grading
- Agent evals: https://developers.openai.com/api/docs/guides/agent-evals

4. guardrail 应是分层防御，而不是单点规则。  
OpenAI 的 practical guide 明确强调 layered guardrails，包括：
- rules-based
- LLM-based
- tool safeguards
- output validation  
来源：
- OpenAI practical guide PDF: https://cdn.openai.com/business-guides-and-resources/a-practical-guide-to-building-agents.pdf

5. 类型化输出、验证重试、tool call limit 这类 runtime 能力已经被框架产品化。  
PydanticAI 官方直接把这些能力做成一等公民：
- `output_type`
- retries
- `ModelRetry`
- `tool_calls_limit`  
来源：
- PydanticAI docs: https://ai.pydantic.dev/agent/

6. 国内企业实践对“完全依赖模型自主规划”是谨慎的。  
阿里云 RDS AI 助手公开复盘里明确说，他们在严肃场景里发现“完全依赖模型自主拆解规划”效果不稳，最后对高确定性场景采用了更强的人工规划/SOP/混合架构。  
来源：
- 阿里云 RDS AI 助手实践: https://developer.aliyun.com/article/1685962

7. 国内企业问数/分析型产品强调企业语义知识和分析思路注入。  
Quick BI 官方文档明确强调接入企业知识库、分析思路和业务知识，以让模型输出更贴合企业语境。  
来源：
- 阿里云 Quick BI 企业知识库: https://help.aliyun.com/zh/quick-bi/user-guide/enterprise-knowledge-base

**基于这些资料，我对你们项目的架构判断**

1. 你们当前路线不算落后，但还停在“第一代企业 agent runtime”。
也就是：
- 手写 loop
- 手写 tool bridge
- 手写 guardrails
- 手写 event trace

这条路可控，但当系统复杂度上来后，会越来越缺：
- typed plan state
- verifier
- eval flywheel
- tracing-aware debugging

2. 你们最强的资产不是 prompt，而是 Java MCP + 双视图返回 + 事件存储。
这三样是非常对的基础设施：
- Java MCP 把企业能力和鉴权边界封住了
- `planData/answerData` 已经开始分离机器视图和回答视图
- event store 已经天然适合做 trace/eval

这说明你们**不应该推翻重来**，而应该在现有 runtime 上升级“planning/verifier/eval”层。

3. 现在最不该继续扩大的，是 prompt 中的业务规则仓库。
`app/agent/context.py` 里那种规则越多，后面越难维护。  
SOTA 方向不是把越来越多的行为写进 prompt，而是把：
- 计划
- 证据
- 验证
- 展示
尽量搬到结构化 runtime。

**三、尖锐一点的总评**
如果不做架构升级，继续沿当前方式加功能，未来大概率会出现这几个问题：

1. prompt 变成“第二套代码”
业务规则、特例、工具边界、few-shot 混在一起，最后没人敢动。

2. 多跳正确率提升会越来越依赖样例，而不是依赖能力
今天是 `search -> detail`，明天是 `compare -> detail -> aggregate`，后天又是另一套。

3. 真实联调成本持续上升
因为很多问题只有在复杂上下文里才会暴露，而单测很难覆盖。

4. answer 越来越稳，但 planner 越来越不稳
你们已经在 answerData 方向走对了，但 planning 还没同步升级。

**四、我建议的优化方向**
不是“全重写”，而是分层升级。

**A. 第一优先级：给 runtime 增加显式 plan/evidence/verifier**
这是最值钱的。

建议新增最小状态对象：
- `goal`
- `subquestions`
- `evidence_needed`
- `evidence_collected`
- `can_answer`

然后在每轮 tool 后，不直接让模型决定结束，而是加一个 verifier/replan 小步骤。  
这会比继续堆 prompt 规则更泛化。

这部分最接近：
- LangGraph planning agents
- OpenAI trace-oriented orchestration
- 阿里云强调的“确定性规划”

**B. 第二优先级：把 prompt 里的业务特例逐步下沉成 runtime policy**
比如现在很多规则可以迁到：
- tool metadata
- evidence requirement
- answer projection
- sanitizer/verifier

目标不是“prompt 变短”本身，而是让 prompt 只负责行为原则，不负责业务流程细节。

**C. 第三优先级：把 event store 升级成真正的 trace/eval 基础设施**
你们已经有事件流，这是优势。

建议下一步做：
- trace dataset
- workflow-level graders
- regression suite
- 关键路径评分项  
例如：
- 是否过早停止
- 是否遗漏必要 detail tool
- 是否暴露内部字段
- 是否 answer grounded in answerData

这和 OpenAI 的 trace grading 路线非常一致。

**D. 第四优先级：把 guardrail 扩成“安全 + 质量”的双层体系**
现在 guardrail 只做安全还不够。

建议加：
- answer groundedness check
- schema/answerData compliance check
- no-internal-field leak check
- evidence sufficiency check

其中一部分可规则化，一部分可小模型化。

**E. 第五优先级：清理技术栈包袱**
最直接的是：
- 如果不再用 `langgraph`，从依赖移除
- 把 runtime 设计和历史 graph 心智彻底切干净

这不是大问题，但会提高团队认知一致性。

**五、哪些现成组件值得考虑**
我分“建议引入”“不建议全量替换”两类。

**建议认真考虑的**

1. `PydanticAI`
适合作为“typed runtime 能力增强件”，不是整套替换。  
优点：
- typed tools / typed outputs
- output validation
- retry / model retry
- tool call limit  
它很适合你们当前这种 Python 单智能体 runtime，因为你们本来就重视 schema 和契约。

我不建议全量替换 orchestrator，但很建议借它的思路，甚至局部接入它的 typed output / retry 机制。

2. `OpenTelemetry + agent-aware tracing/evals`
你们已经有事件流，但缺标准化 observability。  
建议最少做：
- trace id 贯通
- tool span
- llm span
- verifier span
- eval hooks

不一定非上某一家平台，但这个层一定值得补。

**可以借鉴，但不建议直接整仓切换的**

1. `OpenAI Agents SDK`
优点：
- trace / handoff / guardrails / evals 路线完整  
但我不建议现在全量迁移，原因是：
- 你们主模型不是原生 OpenAI 栈，而是 LiteLLM + Qwen
- 你们已经有自定义 MCP 契约、event store、双视图返回
- 直接替换会动太大

我的建议是“借鉴它的 trace/eval/guardrail 思路”，不是整仓迁。

2. `LangGraph`
你们依赖里还有它，但当前主链路已经不用。  
我不建议“为了 SOTA 再切回 LangGraph”。  
因为你们现在的问题不是“缺图”，而是“缺显式计划与验证状态”。这可以在现有 runtime 上补，不一定要引入 graph runtime。

3. `Mastra`
从产品能力上看很强，尤其是：
- workflows
- MCP
- observability
- evals  
但它是 TypeScript 生态。你们当前 Python + Java 架构下，不适合作为直接替换件，更适合作为产品和平台能力参考。

**六、推荐的演进方案**
我建议三阶段，不推翻现有系统。

**Phase 1：架构收口**
- 引入 `plan_state`
- 引入 verifier/replan
- 把 prompt 里的明显 case 规则逐步迁到 runtime
- 移除 planning 对 preview 的依赖
- 清理 `langgraph` 残留依赖

**Phase 2：质量体系**
- 用现有 event store 做 trace dataset
- 增加 workflow graders
- 建回归集，不再只靠典型 case shell 脚本
- 把“过早停止”“字段泄漏”“错误多跳”做成评分项

**Phase 3：能力平台化**
- 把高频稳定多跳查询沉淀成 facade/workflow tools
- 但不是把所有逻辑都做成 facade
- 保留 runtime planner 处理长尾问题，facade 处理高频确定性问题

这条路线兼容：
- 你们已有 Java MCP
- 你们已有 answerData 双视图
- 你们已有 event store
- 你们现有 Python runtime

**七、我最建议优先做的 5 件事**
1. 在 `app/agent/runner.py` 引入显式 `plan_state + verifier`
2. 在 `app/agent/context.py` 清理 query-specific 规则，把它们迁成通用 planning policy
3. 在 `app/agent/guardrails.py` 增加 answer groundedness / schema compliance checks
4. 基于现有 event store 做 trace-level eval
5. 清理 `langgraph` 依赖和历史心智

**一句话总结**
这个项目的方向是对的，基础设施也不差，真正的问题不是“缺框架”，而是：

你们已经有了企业级 Agent 的外壳，但还没有把“规划、证据、验证、评测”这四个核心能力做成一等公民。

如果你要，我下一步可以继续直接给你一版：
- 面向当前代码的具体重构路线图
- 哪些文件先改
- 哪些 prompt 规则该迁移
- verifier / eval / tracing 怎么落最省成本

**参考**
- Anthropic tool use: https://platform.claude.com/docs/en/agents-and-tools/tool-use/implement-tool-use
- LangChain planning agents: https://blog.langchain.com/planning-agents/
- OpenAI Agents SDK: https://developers.openai.com/api/docs/guides/agents-sdk
- OpenAI trace grading: https://developers.openai.com/api/docs/guides/trace-grading
- OpenAI agent evals: https://developers.openai.com/api/docs/guides/agent-evals
- OpenAI practical guide PDF: https://cdn.openai.com/business-guides-and-resources/a-practical-guide-to-building-agents.pdf
- PydanticAI: https://ai.pydantic.dev/agent/
- 阿里云 Quick BI 企业知识库: https://help.aliyun.com/zh/quick-bi/user-guide/enterprise-knowledge-base
- 阿里云 RDS AI 助手实践: https://developer.aliyun.com/article/1685962
