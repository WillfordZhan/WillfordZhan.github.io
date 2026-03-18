---
title: "AI Agent 前沿调研：软能力下沉为硬能力、Skills、Subagents 与 Workflow 的真实趋势"
date: 2026-03-18 17:27:26
categories:
  - "AI"
tags:
  - "AI Agent"
  - "Workflow"
  - "ReAct"
  - "LangGraph"
  - "Skills"
  - "Subagents"
  - "调研"
  - "AI工作日志"
source_archive:
  id: 20260318-ai-agent-skills-subagents-workflow
  rel_path: source_materials/posts/20260318-ai-agent-skills-subagents-workflow
  conversation_file: conversation.jsonl
---

**结论先行**

这轮跨 `X / Reddit / Linux.do / GitHub / 论文 / 官方文档` 调研后，最清晰的共识不是“让 agent 更自由”，而是：

- 把 **自由裁量缩到少数高价值决策点**
- 把 **执行、验证、补参、审计、回放** 下沉到 runtime / workflow / grader / skill
- 把 **domain-specific 差异** 优先做成 `skills / projectors / facade workflows`，而不是上来拆一堆 domain agent

更尖锐一点说：  
**前沿不是在追求更会 improvisation 的 ReAct，而是在追求更强约束下的 agentic workflow。**

**有可核验来源直接支持的结论**

- 官方框架都在把 agent 定义成“workflow + tools + memory + logic + evals”，不是单纯 ReAct。OpenAI `Agents / Agent Builder` 直接把 `logic nodes / tools / guardrails / knowledge / workflows` 放进同一个构建面里。[OpenAI Agents](https://developers.openai.com/api/docs/guides/agents) [Agent Builder](https://platform.openai.com/docs/guides/agent-builder)
- LangChain / LangGraph 已经显式分层：`create_agent` 是高层 agent API，底层 runtime 是 LangGraph；`create_react_agent` 已被弱化/弃用，不再是主范式。[LangChain v1](https://docs.langchain.com/oss/python/releases-v1) [LangGraph v1](https://docs.langchain.com/oss/python/releases/langgraph-v1) [LangChain Agents](https://docs.langchain.com/oss/python/langchain/agents)
- Anthropic 在 2025-11-24 的 advanced tool use 里，直接把三类“硬能力”推到前台：
  - `Tool Search` 解决工具库过大和上下文膨胀
  - `Programmatic Tool Calling` 让代码而不是自然语言协调多步执行
  - `Tool Use Examples` 解决 “JSON Schema 只能校验结构，不能表达使用模式” 的问题  
  这和你问的“证据语义层怎么硬化”高度相关。[Anthropic advanced tool use, 2025-11-24](https://www.anthropic.com/engineering/advanced-tool-use)
- 同一篇 Anthropic 文档明确给出一个很关键的事实：他们见过工具定义在优化前就占掉 `134K tokens`，而且常见失败不是 schema invalid，而是“选错工具 / 参数用法错”。这直接说明“只靠 schema + prompt”不够硬。[Anthropic advanced tool use](https://www.anthropic.com/engineering/advanced-tool-use)
- Anthropic 在 2026-01-09 的 evals 文档里把 agent eval 定义成：`task / trials / grader / transcript / outcome / harness`，还明确说研究类 agent 要用 `groundedness / coverage / source quality` 组合 grader。这个方向本质就是把“证据充分性”从 prompt feeling 变成可执行评测契约。[Demystifying evals for AI agents, 2026-01-09](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)
- Anthropic 的 `Building Effective AI Agents` ebook 和 PDF 明确把模式拆成：
  - single-agent
  - multi-agent centralized / decentralized
  - workflow sequential / parallel / hybrid
  - skills  
  并强调 workflow 是静态结构，agent 是动态行为，两者是互补不是替代。[Anthropic ebook](https://resources.anthropic.com/building-effective-ai-agents) [PDF](https://resources.anthropic.com/hubfs/Building%20Effective%20AI%20Agents-%20Architecture%20Patterns%20and%20Implementation%20Frameworks.pdf?hsLang=en)
- GitHub 2025-05-19 发布 Copilot coding agent 时，核心卖点不是“更聪明”，而是 `integrated / steerable / verifiable`，并且默认走 PR、日志、审批边界。[GitHub Coding Agent, 2025-05-19](https://github.com/newsroom/press-releases/coding-agent-for-github-copilot)
- GitHub 2025-12-18 正式上了 `Agent Skills`，定义成“instructions + scripts + resources，会在相关任务时自动加载”。这基本已经把 domain-specific few-shot/链路从 prompt hack 推向了 skill 机制。[GitHub Copilot Agent Skills, 2025-12-18](https://github.blog/changelog/2025-12-18-github-copilot-now-supports-agent-skills/)
- Anthropic 的 `subagents` 文档也同样把特定任务、独立上下文、工具约束、并行研究、链式 delegation 做成了正式能力，而不是临时 prompt 技巧。[Claude Code subagents docs](https://code.claude.com/docs/en/sub-agents)
- 论文侧也在强化这条路：
  - `ReAct` 是基线：reasoning/action 交替。[ReAct](https://arxiv.org/abs/2210.03629)
  - `QualityFlow` 强调由质量检查控制的 agentic workflow 优于静态流程和单次生成。[QualityFlow](https://arxiv.org/abs/2501.17167)
  - `FlowAgent` 直接瞄准 workflow agent 的 compliance + flexibility。[FlowAgent](https://arxiv.org/abs/2502.14345)
  - `Plan-Then-Execute` 说明显式规划对协作和控制有价值，不是多余 ceremony。[Plan-Then-Execute](https://arxiv.org/abs/2502.01390)

**社区讨论层面的高频信号**

这些不是学术真理，但跨社区重复出现，值得重视。

- Reddit 上已经有很明确的工程派声音：`workflow as a tool`，一旦选中 workflow，就让 runtime 接管，不让 LLM 在执行中途继续乱 steering。这和“软能力下沉为硬能力”完全同向。[r/AI_Agents, 2026-01-22](https://www.reddit.com/r/AI_Agents/comments/1qk2l7g/taking_execution_out_of_the_llm_exposing/)
- Reddit 另一条高频观点是：真正能工作的 agent，本质就是 `FSM + memory + tools`，workflow 不是 weakness，而是 why they work。[r/LocalLLaMA, 2025-07-10](https://www.reddit.com/r/LocalLLaMA/comments/1lwniq0/workflows_arent_a_weakness_in_ai_agents_theyre/)
- 业务落地者在 Reddit 里反复提到：最佳实践是“把 agent 当 decision assistant 放进 workflow”，而不是让 agent 取代 workflow。[r/LangChain](https://www.reddit.com/r/LangChain/comments/1o3w8ll/anyone_here_building_agentic_ai_into_their_office/)
- Linux.do 的中文讨论，2026 年明显更偏 `上下文工程 / Plan 模式 / HITL / 工程化 / 可观测性`，而不是早期那种“多智能体越多越高级”。[上下文工程](https://linux.do/t/topic/1543944) [AI 编程长文](https://linux.do/t/topic/1590572) [Agent 成熟度讨论, 2026-03-04](https://linux.do/t/topic/1687389) [LangGraph HITL 讨论, 2025-07-16](https://linux.do/t/topic/792435)
- X 上能看到两个明显趋势，但证据强度弱于论文/官方文档：
  - “Spec / Plan first” 在 coding agent 社区升温，比如 MassGen 的 `Spec Plan Mode`
  - skills / agents / rules 被明确区分，且“接太多 MCP 会掉质”成为一线经验  
  这些更像一线 builder 的经验汇总，不应当当成学术共识。[MassGen X snippet](https://x.com/massgen_ai/status/2026727701751685267) [日本开发者关于 `.claude/skills/.claude/agents` 的 X 讨论](https://x.com/unikoukokun/status/2026262279172558992)

**全球 vs 国内的差异**

- 全球官方/前沿框架更强调：
  - runtime substrate
  - tool search
  - code-based orchestration
  - eval harness
  - skills/subagents
  - mission control / auditability  
  代表来源是 OpenAI、Anthropic、LangChain、GitHub。
- 国内公开讨论更强调：
  - context engineering
  - HITL
  - 端到端产品化
  - 多智能体产品而不只是 SDK  
  代表信号包括 Linux.do 讨论，以及京东开源的 JoyAgent-JDGenie 在 GitHub 上自述的 `plan and executor + react + workflow memory` 产品路线。  
  但注意：JoyAgent README 属于项目方自述，不应等同于独立评测结论。[JoyAgent-JDGenie](https://github.com/jd-opensource/joyagent-jdgenie)

**基于这些来源，我给你的工程判断**

- `goal / subquestions / step text` 不应该被硬化。它们只适合做 trace，不适合做 authoritative orchestration state。
- 真正该硬化的是：
  - `intent_type`
  - `slot bindings`
  - `evidence requirements`
  - `execution boundary`
  - `outcome checks / graders`
- 你的 `plan_state` 如果继续围绕自然语言 `goal/evidence_needed/missing_evidence` 设计，长期还是软的。前沿趋势更像：
  - `PlannerTrace`：保留 LLM 说过什么
  - `OrchestrationState`：只保留 runtime 真正能验证和推进的结构化状态
- `证据语义层` 不该做成“让 LLM 再判断一次证据够不够”，而应该做成：
  - `IntentFrame`
  - `SlotState`
  - `EvidenceRequirement`
  - `EvidenceItem`
  - `RequirementMatcher`
  - `OutcomeGrader`
- `few-shot / domain chain` 默认不该上来拆成 domain agent。优先级应该是：
  1. `domain skill / domain pack`
  2. `workflow facade tool`
  3. 只有在工具宇宙、权限边界、memory、SLA、规划语义都显著不同的时候，才拆 `domain agent`
- 也就是说：  
  **domain-specific 知识适合放 skill；稳定执行链路适合放 facade workflow；只有独立“执行宇宙”才值得独立 domain agent。**

**一句最核心的总结**

跨这些前沿讨论源，真正收敛出来的不是：

- “让 agent 更像人一样自由发挥”

而是：

- “让 agent 在更强 workflow、skills、subagents、tool search、programmatic execution、evals、audit trail 约束下工作”

**小红书部分的说明**

小红书这轮公开可检索结果里，我没有找到足够高信号、可核验的 agent 架构前沿讨论；搜到的大多是开放平台/商家/开发文档页面，而不是技术社区对 agent runtime 的系统讨论。因此这部分不能给强结论。公开索引样本主要是官方开放平台页，如 [小红书开放平台首页](https://school.xiaohongshu.com/en/open/index.html) 和 [小程序开放平台](https://miniapp.xiaohongshu.com/)。这部分证据不足，我不拿它来支撑架构判断。

如果你愿意，我下一条可以直接输出一版：
**“把你当前 `plan_state + clarify + verify` 重构成硬能力编排层的数据结构和状态机设计”**，按你的仓库形态来写。
