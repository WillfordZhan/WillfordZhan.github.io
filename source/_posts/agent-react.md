---
title: "把多节点 Agent 编排压成单节点 ReAct：一次真实重构复盘"
date: 2026-03-12 10:52:12
categories:
  - "AI"
tags:
  - "LangGraph"
  - "Agent"
  - "ReAct"
  - "架构重构"
  - "复盘"
  - "AI工作日志"
---

前段时间我把一条原本还算“规矩”的 Agent 编排链路，硬生生压成了单节点。

原始版本大概是这种气质：

- `bootstrap`
- `plan`
- `tool_validate`
- `tool_call`
- `clarify`
- `chat`

看起来层次分明，像一张写给评审看的 UML 图。真跑起来以后，感受更像在组装机关枪，每多一个节点，代码体积、状态字段、测试断言和联调排查成本就跟着长。

这篇文章记录的就是一次比较彻底的收口过程：

- 为什么决定从多节点编排改成单节点 Agent loop
- 为什么单 Agent 之后又继续收口成结构化 ReAct
- 为什么很多所谓“工程抽象层”最后都应该删掉
- 以及真实联调里，哪些 case 跑通了，哪些 case 看起来 PASS，实际还藏着坑

文章里的路径、端口、环境名都已经做过公开化处理，重点放在机制和取舍，不放内部实现细节。

## 背景：多节点编排为什么越写越沉

最初的思路很自然：把每个动作拆成节点，流程就会清楚。

比如一轮问答：

1. 先做计划
2. 计划里决定要不要调工具
3. 调工具前再做参数校验
4. 缺参就进澄清
5. 否则回最终答案

问题不在“能不能跑”，问题在于这种结构很容易长成下面这个样子：

```text
query
  -> bootstrap
  -> plan
  -> tool_validate
  -> tool_call
  -> clarify
  -> respond/chat
```

刚开始每层都觉得自己很有道理：

- `bootstrap` 说自己负责初始化
- `plan` 说自己负责决策
- `tool_validate` 说自己负责安全
- `clarify` 说自己负责 HITL
- `chat` 说自己负责最终回答

代码越来越多以后，问题就不是“职责清不清楚”，而是“同一件事到底在哪层改”。

最典型的几个症状：

### 1. prompt 语义被切碎

模型的思考过程本来是一段连续的认知链：

- 我先判断要不要查工具
- 查了之后我再决定下一步
- 工具结果不够我就追问
- 工具结果足够我就回答

拆成多个节点以后，模型的这段认知链被切成了几段模板化动作。代码一多，整个系统会逐渐从“Agent”退化成“带一点模型调用的状态机”。

### 2. 状态字段爆炸

节点一多，就会冒出很多典型字段：

```python
plan_action
plan_reason
plan_answer
plan_tool_calls
tool_validation_error
clarification_question
clarification_context
final_answer
```

字段本身不一定错，问题是很多字段只是为了跨节点传递中间态才存在。一旦节点被删除，这些字段就变成了历史包袱。

### 3. 联调 trace 看起来热闹，实际上噪音很多

一开始很喜欢把每一步都发成事件：

- `llm_request`
- `agent_step`
- `react_plan`
- `tool_call`
- `tool_result`

这类事件在测试阶段很爽，因为你能看到系统“很忙”。  
但对真实前端和真实联调来说，很多内部事件并不产生用户价值，只会让协议越来越重。

### 4. 一层层 service / dto 叠上去以后，真正的业务逻辑反而找不到了

后来最明显的一个信号是：想改单次工具调用的策略，需要同时看这些地方：

- 节点代码
- DTO
- tool service
- adapter
- parser
- state patch
- 测试辅助类

到这个阶段，继续抽象已经没有意义了。最应该做的是删。

## 第一轮收口：先把图压成单节点

最后做的第一步非常朴素：

```text
START -> agent -> END
```

LangGraph 只保留 checkpoint 能力，图本身不再承担“业务分层”的责任。

这样做之后，外层保留的东西很少：

- checkpoint / resume
- conversation store
- 最终事件写入
- 中断恢复

真正的业务决策都收进 `agent.py`。

### 为什么不是完全抛弃 LangGraph

因为我需要的不是“图编排能力”，而是：

- checkpoint
- interrupt/resume
- 状态恢复

这些能力 LangGraph 现成就有，而且已经接进现有会话体系里。  
保留它作为最薄外壳是合理的，再往上叠很多节点就不合理了。

## 第二轮收口：把单 Agent 再收成结构化 ReAct

单节点之后，一开始仍然存在一个问题：

虽然已经是 loop 了，但语义上还是偏“单步判决”：

- 这一步是 `CALL_TOOL`
- 或者 `CLARIFY`
- 或者 `RESPOND`

这种写法能跑，但它对多步工具调用不够友好。  
尤其是遇到“先查今天，再查昨天，再比较”这种问题时，模型很容易在第一步就选择澄清，根本不给自己收集 observation 的机会。

所以后面又做了一步升级：从单步决策改成**结构化 ReAct**。

### 这里的关键不是 ReAct 这个词

关键是这四个角色被明确了：

- `Thought`
- `Action`
- `Observation`
- `Respond`

但这里没有走经典的文本 ReAct：

```text
Thought: ...
Action: ...
Observation: ...
```

这种格式在生产里有两个问题：

1. 解析脆弱
2. 容易变成“请输出完整思维链”

所以我最后采用的是**结构化 ReAct**：

```json
{
  "thought": {
    "summary": "需要先获取今天和昨天的数据再比较",
    "need_more_evidence": true,
    "confidence": "high"
  },
  "action": {
    "type": "CALL_TOOL",
    "reason": "需要先取证",
    "tool_calls": [
      {
        "tool_name": "today_furnace_batches",
        "arguments": {
          "fnCode": "1",
          "date": "2026-03-12"
        }
      }
    ]
  }
}
```

这套格式有几个好处：

- `thought.summary` 可以写日志，但不进 SSE
- `action.type` 仍然强约束
- `tool_calls` 支持多调用
- 可以兼容旧的平铺 JSON 输出

### 为什么不让 Thought 进入事件流

因为我想要的是“调试信息”，不是“对外暴露的推理过程”。

最终保留的原则是：

- 内部有 `thought`
- 只记日志
- 不作为前端协议的一部分

这件事非常重要。不然系统最后会一边说自己安全，一边把推理摘要作为事件往外吐，多少有点精神分裂。

## 删掉了哪些其实没必要的层

这次收口里，删得最痛快的一层是工具调用链路上的重复包装。

原先大概有这种结构：

```text
Orchestrator
  -> ToolService
    -> HttpToolAdapter
      -> MCPClient
```

看起来很规范，实际上 `ToolService` 在单 Agent 版本里已经没什么存在意义了。

原因很简单：

- 工具名匹配在 agent 里做了
- 参数归一化和 schema 校验也在 agent 里做了
- 进入工具执行阶段以后，本质只剩一次传输代理

所以后来直接收成：

```text
Orchestrator
  -> HttpToolAdapter
    -> MCPClient
```

`HttpToolAdapter` 也只保留两件事：

- 拉工具描述
- 发工具调用

其余那套给 LangChain StructuredTool 准备的动态模型、二次校验、工具索引，都删了。

这类层如果当前主链路不用，留着就是噪音。

## 一个容易踩坑的点：别把 unknown args 都当错

这次工具参数校验还顺手修了一个很烦的问题。

早期有一种过严逻辑：

- 只要模型多带了 schema 里没写的字段
- 就直接判成 `unknown_arg`
- 然后强制澄清

这在一些 case 里表现得很蠢。模型只是多传了一个无害字段，系统就一脸严肃地要求用户补充信息。

后面改成按 JSON Schema 语义走：

- 如果 `additionalProperties: false`
  - 未知字段算错误
- 否则
  - 保留宽松透传

这个改动非常值钱，因为它把“严格”从拍脑袋变成了遵循 schema 的通用能力。

## 真实联调里，哪些 case 过了，哪些还没完全对

这次不是只跑单测，真实联调也一起做了。

本地验收过程包括：

- Python 服务起在独立端口
- 使用真实工具清单
- 跑完整 `典型case`
- 看 SSE 终态事件

### 跑通的部分

以下类型是稳定的：

- 简单问候直接 `final`
- 明确缺参时走 `clarification_needed`
- 知识库 miss 时直接 `final`
- interrupt / resume 能继续走
- checkpoint 恢复后还能产生终态事件

### 仍然暴露问题的两个 case

#### case3：比较类问题仍然过早澄清

问题是：

> 今天 1 号炉生产情况怎么样，和昨天比炉次数量有什么变化

这类问题理论上应该：

1. 先取今天数据
2. 再取昨天数据
3. 再比较

但当前版本仍然倾向在第一步先问更多上下文。  
这说明“先取 observation 再澄清”的优先级还不够高。

#### case4：知识库主题已明确，但仍然先问“哪个知识库”

用户已经给出：

> 铸造工艺优化

这种情况下，如果系统里存在知识检索工具，第一步更合理的动作是先试检索，而不是先追问“你说的是哪个知识库”。

这反映的是**工具优先级策略**还偏保守，不是 loop 能力不够。

## 为什么这些问题不是靠“再加节点”解决

很容易有人看到 case3/case4 失败，就开始想：

- 要不要加一个 compare node
- 要不要加一个 retrieval planner
- 要不要加一个 kb_router

我的结论很明确：先别。

因为这两个问题本质上都还是单 Agent 策略问题：

- 什么时候先取证
- 什么时候允许一问多调用
- 什么时候 observation 足够终止

这些都属于同一个决策域。

如果为了修 case3/case4 再拆回多个节点，本质就是把刚删掉的复杂度又请回来。

## 当前最值得继续优化的两个方向

这也是我在后续 review 里最认同的两个增强点。

### 1. 提高“先取 observation 再澄清”的优先级

做法不是硬编码匹配某个问题文本，而是把规则写进当前单节点 ReAct contract：

- 只要工具所需参数已经满足，就优先 `CALL_TOOL`
- 如果用户已经给出明确主题/对象，不要因为潜在歧义先澄清
- observation 不足时先补 observation

### 2. 提高“一问多调用”的容忍度

对比、趋势、跨日期问题本来就应该允许多次调用。

比如一个动作里直接返回：

```json
{
  "action": {
    "type": "CALL_TOOL",
    "tool_calls": [
      {"tool_name": "today_furnace_batches", "arguments": {"fnCode": "1", "date": "2026-03-12"}},
      {"tool_name": "today_furnace_batches", "arguments": {"fnCode": "1", "date": "2026-03-11"}}
    ]
  }
}
```

然后把两个 tool result 都喂回 observation，让下一轮回答。

这件事不需要加节点，只需要：

- prompt contract 允许
- validator 接受
- executor 顺序执行

## 这次重构我最后留下的原则

整理下来，最后保留的原则非常少：

### 1. LangGraph 只保留 checkpoint 壳

不要让图承担业务抽象层的责任。

### 2. Agent 决策域尽量内聚

prompt、解析、工具调用、回合控制尽量在一个地方闭合。

### 3. 工具策略优先于 prompt 花活

清晰的工具描述、清晰的 schema、清晰的边界，通常比一大段提示词更有用。

### 4. 删除不用的层，比再抽一个新层更重要

尤其是在已经进入“service / dto / adapter / patch model 到处飞”的阶段。

### 5. 真正的验收永远不是 pytest 绿了

单测能证明：

- 结构没炸
- 兼容没丢

真实联调才能证明：

- case 到底怎么走
- observation 有没有真的接上
- checkpoint / resume 有没有活
- 工具链是不是只是在 mock 世界里成立

## 延伸问答

### 单 Agent 之后 trace 会不会更差

不会消失，但不会像多节点那样“天然清楚”。

如果内部 Thought 和 Action 都变成结构化日志，其实可追踪性仍然是够的。  
只是它不再是节点事件，而是 agent loop 的 step log。

### 单 Agent 会不会让系统不受控

不会，只要你把“自由”限制在决策层，把边界放在代码层：

- schema 校验
- 最大 step 数
- 最大 tool round
- checkpoint / interrupt
- 安全护栏

这样系统还是受控的，只是不再被多节点状态机切碎。

### 要不要直接上更重的 Agent 框架

当前这套场景里没必要。

如果现有系统已经有：

- checkpoint
- store
- 工具桥接
- 安全护栏

再上一个更重的 agent runtime，通常只会把层级重新堆回来。

## 结语

这次重构最有意思的地方，不是把系统改成了单 Agent，而是终于承认了一件事：

很多“看起来规范”的层，在单 Agent 场景下其实只是历史遗留的安慰剂。

删掉它们以后，代码并没有失控，反而更容易看明白：

- 这一轮要不要取证
- 取什么证
- 证据回来了怎么继续
- 什么时候停

对 Agent 系统来说，这种清晰度比多几个节点名字重要得多。
