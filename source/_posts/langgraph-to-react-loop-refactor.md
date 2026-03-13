---
title: "把 LangGraph 黑盒编排重构成精简 React Loop"
date: 2026-03-13 20:51:17
categories:
  - "AI"
tags:
  - "LangGraph"
  - "Agent"
  - "React Loop"
  - "Function Calling"
  - "重构"
  - "复盘"
  - "AI工作日志"
source_archive:
  id: 20260313-langgraph-react-loop-refactor
  rel_path: source_materials/posts/20260313-langgraph-react-loop-refactor
  conversation_file: conversation.jsonl
---

这次重构之前，`ats_iot_ai` 的编排层已经有明显的黑盒感了。想改 prompt，不知道最终是在哪一步组装进去的；想追一轮对话历史，不知道该看 event、LangGraph state、checkpoint，还是 memory projection；想改一条澄清链路，最后会同时碰到 graph 节点、checkpoint 恢复、事件回放和 guardrail。

这套东西一开始是为了把更早的一坨逻辑收进框架里，后来又在框架外面补了自己的状态、事件和恢复。结果就是同一轮对话有多套载体，真正的运行时真相反而越来越难找。继续在这上面补节点、补 prompt、补 guardrail，维护成本只会往上走。

这次重构做的事很直接：把主运行时从 `LangGraph + checkpoint` 拉回到显式的单智能体 loop，按 transcript 驱动工具调用和补参，把历史、上下文、提示词、工具和输出边界重新收口。改完以后，主链路终于能顺着读下来，真实联调也能稳定复现和定位。

## 原来的阻力落在哪

最难受的地方不是代码量大，而是链路没有一个稳定的心智模型。

当时线上和联调里能持续看到这几类问题：

1. 改 prompt 的入口不单一。一个回合里会同时碰到 planner prompt、security prompt、chat prompt，还可能混进节点级补丁逻辑。
2. 会话历史来源不单一。`ConversationEvent`、LangGraph `state["messages"]`、checkpoint、memory manager 各自都像“真相”，排查时要来回对照。
3. `clarify` 和 `interrupt` 依赖框架内部状态。业务需要补参，最后却要沿着 checkpoint 去猜当前挂起在哪。
4. 工具调用是“模型吐 JSON，Python 再修 JSON”。能跑，但很容易在边界场景里变得又脆又绕。

这几个点叠在一起以后，编排层变成了一种很典型的状态：每一层都不算完全错，但任何改动都会牵出多层配套逻辑。

## LangGraph 在这个项目里为什么越用越重

LangGraph 擅长的是工作流图、显式节点状态和中断恢复。真要做多阶段审批、长时挂起、多 agent 分叉合流，这类能力很有用。

这次项目的主问题不在这里。`ats_iot_ai` 的主流程更接近标准单智能体 ReAct：

```text
用户输入
-> 结合历史与上下文决定下一步
-> 需要证据就调工具
-> 工具结果回灌
-> 继续推理
-> 终止回答或补参
```

这条链路天然更适合一个显式 loop，而不是一层 graph 再套一层 checkpoint。框架继续留在中间，收益主要是“形式上有节点”，代价却是：

- 对话历史被框架内部状态吸走
- 中断恢复带出更多黑盒语义
- 一轮执行的关键判断不在一个地方
- 想做精简重构时，第一步还得先搞清楚框架到底替你保存了什么

所以这次没有再尝试“把 LangGraph 用得更优雅”，而是直接承认这里的范式不匹配。

## 这次重构具体砍掉了什么

最开始先做的是事实源收口。

会话历史不再依赖 LangGraph checkpoint 作为主来源，而是回到显式 transcript。运行时需要看的历史，只从事件存储里恢复，再投影成模型可消费的消息序列。这样一来，排查时终于能回答一个很关键的问题：这轮 prompt 里到底塞了哪些历史。

然后是主运行时收口。

原来的 `bootstrap -> plan -> tool_validate -> tool_call -> clarify -> chat` 这条图式编排，被压回显式 loop。主逻辑变成下面这种更直白的样子：

```text
load transcript
-> build context/messages
-> call llm
-> if tool_calls:
     execute tool
     append observation
     continue
-> if request_clarification:
     生成澄清话术
     保存 pending_action
     结束本轮
-> else:
     content 作为最终回答
```

这一步把主执行链路重新拉回到了工程代码里。谁决定继续调工具，谁落澄清事件，谁把 observation 回灌给下一轮，代码路径都能直接看到。

## 从 JSON planner 改到原生 function calling

这次最值的一刀，是把“模型输出 JSON，再由 Python 解析动作”的链路换成了原生 function calling。

旧链路的问题不在“结构化输出”这件事本身，而在它要求系统维护一套额外的 planner 协议：

- prompt 要约束模型只返回特定 JSON
- Python 要做 JSON 解析和容错修复
- `CALL_TOOL / CLARIFY / RESPOND` 是系统自己定义的动作层
- 多轮工具调用靠 planner JSON 一轮轮接着吐

这套东西能跑，但复杂度一直存在。

切到 function calling 以后，主协议回到了模型原生接口：

- 带着 tools 调 LLM
- 有 `tool_calls` 就执行
- 执行结果作为 `tool` message 回灌
- 没有 `tool_calls` 就把 `content` 当最终输出

这里还保留了一个本地虚拟工具：`request_clarification`。

它不是真的去调后端，而是用来显式声明“现在缺什么参数”。我最后选它，而不是让模型在普通 `content` 里同时混用“补参话术”和“最终回答”，主要是为了保住运行时语义：

- 业务工具调用表示需要更多证据
- `request_clarification` 表示参数不全
- 无 tool call 的普通内容才表示最终回答

这比只看自由文本稳很多。

## 补参文案没有继续写死在工具 schema 里

这次还有一处我很满意的收口，是把补参的话术生成和工具 schema 解耦了。

早期链路里，工具 schema 带过一些 `x-clarification` 之类的扩展字段，想直接把“问用户的话”写在 schema 里。这个方向后来越来越重：

- schema 里会出现大量面向用户的话术模板
- Java 和 Python 两边都要理解这些扩展字段
- 改一条澄清口径，很容易变成改工具元数据，而不是改对话策略

现在换成了两步：

1. `request_clarification` 只返回结构化缺参信息，比如缺哪个字段、中文业务名是什么。
2. 运行时再起一次很轻的 LLM 调用，把这些缺参元数据转成自然中文补参句子。

这样做以后，工具 schema 只负责表达参数语义，补参对话由模型统一生成。后面 Java schema 也顺势做了一轮精简，像 `x-label` 这种扩展字段迁回 `title`，`x-clarifyTemplate` 和 `x-normalizationRule` 这类冗余元数据就可以删掉了。

## LLM 接入和工具接入也一起变薄了

另一个明显收益是 provider 和 tool runtime 都不再各自带一套奇怪协议。

LLM 侧接入了 LiteLLM，把原来专门绑在 Qwen 客户端上的调用路径拆掉了。这样模型层至少回到了正常 provider 形态，后面换模型不用再改一堆编排代码。

工具侧也从“graph 节点里做一次、service 里做一次、校验层里再补一次”这种分散写法，收成了更单一的 runtime 门面。工具 schema 快照、参数校验、工具执行都回到了 loop 可直接理解的范围里。

这里没有照抄 `nanobot` 的 event bus。对比过它的实现以后，我最后只借了它最有价值的那部分：单一 loop、单一上下文构造器、单一 provider 接口。`ats_iot_ai` 还是 HTTP 会话控制面，不需要为了“更像 agent 框架”再多做一个 bus。

## 代码量变化很实在

这次不是那种“抽象层变多、文件名变优雅”的伪重构，代码量下降是实打实的。

按中间阶段的 diff 统计，这轮主重构大概是：

```text
70 files changed, 3010 insertions(+), 5943 deletions(-)
```

净删除接近三千行。

关键提交链大概是这样：

- `37358e7` 用显式 agent loop 替换 LangGraph 主编排
- `b37c286` 清理旧 LangGraph 残留
- `7f5502b` 接入 LiteLLM 并移除 Qwen 专用客户端
- `92de920` 重构原生函数调用编排链路
- `3c19504` 继续收敛上下文与编排骨架
- `9bf7bb9` 优化提示词与工具 schema 稳定性
- `ce58eda` 合并激进编排重构分支

对我来说，更重要的收益还不是删了多少行，而是编排层重新出现了“一个主入口 + 一条可读主链路”。

## 真实联调结果

这次验收没有只停在 pytest。

我把真实联调脚本也一起改了，先登录 Java 侧拿真实 token，再拉当前用户的真实 `userId`、`deptId` 和可见炉体列表，典型 case 里的炉体不再写死成 `1号炉`，而是动态注入当前账号能看到的首个炉体。这样不同环境下也能复用同一套联调脚本。

在这套新 runtime 上，典型用例里至少这几类已经稳定跑通：

- 普通问候
- 缺参数时进入业务化澄清
- 今天/昨天炉次对比这类多步取证
- 知识库检索命中并收口成最终回答

这里我比较看重的一点是：以前一旦出错，排查很容易被“当前图走到哪个节点”“checkpoint 到底存了什么”带偏。现在联调失败时，主要就回到三个问题：

- 这轮 transcript 里有什么
- 模型到底返回了什么 tool call
- observation 回灌以后下一轮为什么停了

问题空间小很多。

## 这次改造留下来的代价

这次不是没有代价。

第一，很多框架兜底能力要自己接回来。比如补参恢复、对话挂起、有限轮次循环上限、工具结果如何压缩成 observation，这些以前多少能借一点框架壳子，现在都要自己明确定义。

第二，prompt 和 tool schema 的质量更重要了。主运行时简化以后，系统行为的稳定性更依赖工具描述、字段语义、停止条件这些基础约束。后面一段时间，精力会更多落在提示词和 schema 的持续打磨上。

第三，显式 loop 对“过度工程化”有天然抵抗力，但也意味着后面再引入多 agent、复杂审批、多分支长流程时，要重新判断这条骨架还够不够用。至少在这次项目范围内，它是够的。

## 这次重构值在哪

我最后觉得这次改造值，不是因为它把某个框架换掉了，而是它把控制权从黑盒里拿回来了。

编排层这种地方，一旦历史、上下文、动作协议和恢复语义都不在一个人能顺着读下来的范围内，后续每次“加一条规则”“调一个 prompt”都会越来越痛苦。把主运行时重新压回一个显式 loop，看起来很朴素，但对维护者来说，收益非常大。

这类单智能体、单主链路、以工具取证为核心的控制面，我现在会更偏向这种做法：

- transcript 是历史真相
- loop 是主运行时
- function calling 是动作协议
- `request_clarification` 只声明缺参
- 对用户的话术由单独渲染步骤生成

这套骨架不花哨，但至少后面继续改的时候，不用先去猜框架心里到底藏了什么。
