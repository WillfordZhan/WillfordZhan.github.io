---
title: "别再把 Tool Result 整包喂给 Answer LLM 了"
date: 2026-03-17 15:05:00
categories:
  - "AI"
tags:
  - "AI工作日志"
  - "AI Agent"
  - "MCP"
  - "Tool Calling"
  - "Function Calling"
  - "架构设计"
source_archive:
  id: "20260317-tool-response-plan-answer-data"
  rel_path: "source_materials/posts/20260317-tool-response-plan-answer-data"
  conversation_file: "conversation.jsonl"
---

最近在收一条 AI 工具链路时，问题不是 tool schema 怎么写，也不是 function calling 到底该不该开，而是一个更容易被忽略的点：tool 调完之后，返回给后续节点的那份结果，到底该长什么样。

一开始最直觉的做法是，tool 查到了什么就把什么整体回传。Java 侧查出一个对象，塞进 `ToolResult.data`；Python 侧拿到这份结果，再把它整个塞给回答节点。看起来最省事，实际上最容易把两类完全不同的字段揉在一起：

- 规划节点需要的 internal 字段，比如 `status`、`planId`、`recipeId`、内部 marker。
- 回答节点需要的展示字段，比如 `statusName`、`planName`、`recipeName`。

这两个集合不是一回事。前者是给 agent 继续决策和串工具用的，后者才是给用户看的。如果 Answer LLM 直接看到了前者，那你很难再理直气壮地说“这些字段绝不会出现在最终回答里”。

## 一、问题不在 schema，而在结果消费边界

Tool schema 解决的是“模型怎么调工具”，不是“工具结果应该怎么分发给后续节点”。这两件事经常因为都长得像 JSON Schema 被混成一件事。

真正的问题是：一次 tool call 的结果，往往天然有两个消费者。

第一个消费者是规划节点。它需要看更全的结果，用来决定下一步要不要继续调工具、调哪把工具、带什么参数。这一层看到 internal id 没问题，甚至很多时候必须看到，不然没法继续串联动作。

第二个消费者是回答节点。它的目标不是做控制流，而是把已经拿到的证据翻成用户可理解的答案。到了这一层，`statusName` 有意义，`status=1` 通常没意义；`recipeName` 有意义，`recipeId` 大多数时候没意义。

如果这两个消费者看到的是同一份原始 tool result，系统就会出现一个很别扭的状态：编排需要更多字段，回答需要更少字段，最后你只能靠 prompt 去提醒模型“不要暴露内部字段”。这种做法能凑合，但不稳。

## 二、更合适的做法：把工具结果拆成双视图

这次收口下来，最顺的方案其实很简单：不要再把 tool result 当成单视图结果，而是直接升级成双视图协议。

我最后给出的结构是：

```json
{
  "ok": true,
  "preview": "找到 3 条计划",
  "payload": {
    "planData": {
      "planId": 12345,
      "status": 1
    },
    "answerData": {
      "planName": "白班计划",
      "statusName": "生产中"
    }
  }
}
```

这里有两个关键判断。

第一，`planData` 不是“内部调试信息”，它是给规划节点消费的业务数据。只要你的 agent 还要继续串 tool、继续决定下一步动作，这层数据就是真实的运行时输入，不是附属日志。

第二，`answerData` 也不是“把整份结果再 trim 一遍”。它是一个单独设计出来的展示视图，目标非常明确：只给回答节点看用户应该知道、也看得懂的字段。

这样处理之后，边界一下就清楚了：

- PlanLLM 看 `planData`
- AnswerLLM 看 `answerData`

不再需要回答节点自己猜哪些字段该说、哪些字段不该说。

## 三、为什么不建议让 Python 再按 schema 二次裁剪

这个问题当时也讨论过：既然 Java 已经有 tool schema，Python 能不能拿到 schema 之后，再根据字段定义把 tool result 做一遍 trim？

结论是不太建议。

原因不复杂。schema 更适合表达结构，不适合表达“哪些字段给规划节点，哪些字段给回答节点”这种多受众语义。如果把这层规则放到 Python 去推断，实际上就会出现两份规则：

- Java 一份，决定 tool 返回了什么。
- Python 一份，决定工具结果该怎么再裁。

这类逻辑一旦分散，过几个月一定会漂。某个字段 Java 新加了，Python 没跟上；某个字段 Java 觉得是 internal，Python 还在往回答节点里喂。最后排查时你会发现，问题不在模型，而在你自己系统的边界已经裂开了。

更稳的分工是：

- Java 负责定义字段属于哪个视图，并产出双视图结果。
- Python 负责按节点职责选择消费 `planData` 还是 `answerData`。

也就是说，Python 不负责“理解字段语义”，只负责“选择哪份结果给谁”。

## 四、Java 侧要不要硬写 `llmResult` 字段

另一个容易走偏的点，是把结果字段直接命名成 `llmResult`。

这听起来很自然，但其实把协议语义绑死在了当前实现细节上。今天是 PlanLLM 和 AnswerLLM，明天也许会拆成 planner、solver、renderer，或者某个 tool 结果还要给前端卡片组件消费。到那时，`llmResult` 这个名字就会越来越含糊。

所以更稳的命名不是“按技术实现命名”，而是“按消费语义命名”。

这也是为什么最后收口成了：

- `planData`
- `answerData`

这两个名字直接回答了“谁消费它”，而不是“当前是哪个模型在看”。

## 五、Java 侧更通用的做法：在 VO 上打字段受众注解

如果每个 tool 都自己手工构造 `planData` 和 `answerData`，短期能跑，长期一定会乱。因为每个 tool 都会再发明一遍裁剪逻辑，最后没有统一能力。

更合适的做法，是在返回对象的 VO 上直接标字段受众，然后让统一 projector 去做投影。

例如：

```java
public enum ToolFieldAudience {
    PLAN,
    ANSWER
}
```

```java
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.FIELD)
public @interface ToolField {
    ToolFieldAudience[] visibleTo();
}
```

VO 上这么标：

```java
public class ProductionPlanSearchItemVo {

    @ToolField(visibleTo = {PLAN})
    private Long planId;

    @ToolField(visibleTo = {PLAN, ANSWER})
    private String planName;

    @ToolField(visibleTo = {PLAN})
    private Integer status;

    @ToolField(visibleTo = {ANSWER})
    private String statusName;
}
```

然后由统一 projector 输出：

```java
ToolPayload payload = ToolPayloadProjector.project(vo);
```

这样，tool 主逻辑里真正保留下来的就只有两件事：

1. 调业务 service
2. 把业务 DTO 映射成统一的返回 VO

投影这件事不再散落在各个 tool 里。

## 六、这和主流 agent 编排思路其实并不冲突

这套做法看起来像是自己发明了一层协议，其实和现在主流 agent/runtime 的思路是一致的，只是收得更彻底。

图编排系统一般都会把“运行时状态”和“给模型看的消息”分开。状态里可以有更多内部字段，消息里则更偏向模型真正需要消费的内容。只不过很多项目没有明确把这件事收敛成 tool response 协议，最后还是让工具结果直接流进消息历史。

你如果已经走到了“两阶段 LLM”这一步，也就是：

- 前一段负责规划和决策
- 后一段负责回答和表达

那工具结果继续维持单视图，实际上是和架构本身不一致的。节点已经分工了，数据却还没分工。

## 七、对这次改造的最终判断

这次最有价值的收获，不是又整理了一版 tool schema，也不是给回答 prompt 多补了一句“不要暴露内部字段”。

真正有价值的，是把工具结果的消费边界正式拉出来了：

- 规划节点看的，不等于回答节点看的
- Tool result 不应该再是单一视图
- Python 不该再负责猜字段语义
- Java 侧应该提供统一的受众投影能力

如果系统还只是 demo，这件事看起来像“多做了一层”。但一旦工具变多、节点变多、链路开始稳定跑起来，这层边界会直接决定后面是继续可维护，还是每次排查都要回到 prompt 上打补丁。

所以这次的结论可以收成一句话：

不要再把 Tool Result 整包喂给 Answer LLM。  
先把它拆成 `planData` 和 `answerData`，再让不同节点各看各的。
