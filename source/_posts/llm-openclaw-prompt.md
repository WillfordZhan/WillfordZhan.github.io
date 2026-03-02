---
title: "单 LLM 节点不是简化：OpenClaw Prompt 注入范式与护栏工程化重构"
date: 2026-03-02 17:49:34
categories:
  - "AI"
tags:
  - "OpenClaw"
  - "Agent Engineering"
  - "Prompt Injection"
  - "Guardrails"
  - "Memory"
  - "ReAct"
  - "AI工作日志"
---

## 前言

这篇文章写给已经在做 Agent 编排、并且踩过“意图层拆太多 + Prompt 越改越乱 + 护栏和主流程耦合”坑的工程师。

核心观点先摆在前面：

1. 单 LLM 节点不是“把所有事都丢给模型”。
2. OpenClaw 的关键价值，不在“单节点”，而在“模型自决 + 工程护栏 + Prompt 注入可插拔”。
3. 真正可维护的实现，必须把 `决策`、`注入`、`护栏`、`记忆` 四层切开。

---

## 一、单节点到底是什么：不是少一步，而是少一层重复决策

很多团队把“单节点”理解成：

- 删掉 intent parser
- 直接让模型函数调用

这通常会带来两种反噬：

1. 没护栏：模型乱调工具、无限重试、参数污染
2. 没注入层：每次改策略都得改 orchestrator 主流程

OpenClaw 的实现思路相反：**决策集中（单节点），控制分层（护栏与 hook）**。

---

## 二、OpenClaw 的 Prompt 处理主链路（典型代码）

### 1) 先组装统一系统提示词

`run/attempt.ts` 里先汇总 runtime/tooling/skills/safety/memory 等信息，构建 system prompt：

```ts
const appendPrompt = buildEmbeddedSystemPrompt({
  runtimeInfo,
  tools,
  skillsPrompt,
  sandboxInfo,
  memoryCitationsMode,
  ...
});
```

### 2) 覆盖并注入到会话 Session

```ts
const systemPromptOverride = createSystemPromptOverride(appendPrompt);
applySystemPromptOverrideToSession(session, systemPromptText);
```

这一步把“系统行为约束”固定在会话级，而不是散在每次 prompt 调用里。

### 3) 在发送给模型前，运行注入 hook

```ts
const hookResult = await resolvePromptBuildHookResult({
  prompt: params.prompt,
  messages: activeSession.messages,
  hookCtx,
  hookRunner,
});
if (hookResult?.prependContext) {
  effectivePrompt = `${hookResult.prependContext}\n\n${params.prompt}`;
}
```

这相当于提供了一个“Prompt 中间件层”：不用改主循环，也能注入租户策略/上下文。

### 4) 最后进入模型调用

```ts
await activeSession.prompt(effectivePrompt);
```

这个流程非常朴素，但工程边界很清晰。

---

## 三、当前业务编排实现（ats_iot_ai）的典型形态

当前形态已经很接近单节点 ReAct，但仍有明显的“半收敛”特征：

### 1) Prompt 分裂为三套角色

```python
_REACT_PLAN_PROMPT = """..."""
_REACT_SUMMARY_PROMPT = """..."""

# _direct_answer() 里还有一套内联 system prompt
```

这意味着同一 run 内，模型会在 Planner/Summarizer/Direct Answer 三种角色间切换。

### 2) 护栏在主流程中内联分支

```python
validation = _validate_tool_call(call=call, tool_definition=tool_definition)
if validation.blocking:
    observations.append({"type": "tool_schema_validation_failed", ...})
    continue
```

功能上可用，但策略扩展会继续膨胀 `orchestrator.py`。

### 3) 短期记忆每 step 事件回放构建

```python
events = await self._store.get_recent_events(
    run_id=run_id,
    event_types=["user_message", "final", "tool_result"],
)
```

能工作，但每轮重建、每步重复，后期会成为性能和一致性负担。

---

## 四、尖锐评判：问题不是模型，而是边界

如果让我直说，这类系统的主要风险不是“LLM 不够聪明”，而是“工程边界未解耦”：

1. Prompt 组装和流程控制耦合，导致策略演化慢且风险高。
2. 护栏不成 pipeline，新增规则会持续污染主循环。
3. 记忆没有门面层，短期与长期能力无法平滑扩展。

一句话：**你需要的不是更多 Prompt 技巧，而是更干净的运行时架构。**

---

## 五、可落地的简洁方案（奥卡姆剃刀版）

目标：不引入多余层级，只做“最少必要重构”。

### 方案总览

1. 一个决策脑：仅保留 `CALL_TOOL|CLARIFY|RESPOND` planner 合约
2. 一条 Prompt 管线：`SystemPromptBuilder + PromptPayloadBuilder + PromptMiddleware[]`
3. 一条护栏管线：`SchemaGuardrail + ClarificationGuardrail + LoopGuardrail`
4. 一个记忆门面：`MemoryFacade`（短期增量 + 长期检索）

---

## 六、关键设计细节

### 1) PromptBuilder：稳定层与动态层分离

```python
system_prompt = system_builder.build(
    rules=...,
    tool_policy=...,
    safety=...,
)
payload = payload_builder.build(
    query=query,
    short_memory=short_memory,
    pending_tool=pending_tool,
    observations=observations,
    tools=tool_catalog,
)
ctx = PromptBuildContext(system_prompt=system_prompt, payload=payload)
for mw in middlewares:
    ctx = mw.before_plan_prompt(ctx)
```

收益：

1. 业务策略注入不改 orchestrator 主干
2. 灰度实验可以按 middleware 开关控制

### 2) 统一 Planner 输出契约

```json
{
  "action": "CALL_TOOL|CLARIFY|RESPOND",
  "reason": "string",
  "tool_name": "string or empty",
  "arguments": {},
  "missing_slots": [],
  "clarification_question": "string or empty",
  "answer": "string or empty",
  "goal_satisfied": true
}
```

建议配合 schema 校验（即使底层模型不支持 strict schema，也在本地做强校验）。

### 3) 护栏独立为 pipeline

`pre_tool`：

1. schema/required/unknown 校验
2. 日期等参数归一化
3. 工具白名单校验

`post_tool`：

1. `ARGUMENT_ERROR` -> pending state
2. `clarification_needed` 事件
3. `/input` 合并后 `tool_retry`

`loop`：

1. 记录 `tool + args_hash + result_hash`
2. warning 与 critical 分级阻断

### 4) MemoryFacade：先简单再增强

先做短期增量：

1. `run_state.short_memory_turns` 维护最近 20 轮
2. 每轮结束增量写入，planner 直接读取

再做长期检索：

1. `search(query, k)`
2. `get(doc_id, spans)`
3. `append(entry)`

这样后续换向量库不会动 orchestrator 主流程。

---

## 七、迁移路线（推荐）

### Phase A（1-2 天）

1. 抽 `prompt_builder.py` + `plan_engine.py`
2. 保持事件协议不变

### Phase B（1-2 天）

1. 抽 `guardrails.py`
2. 实装 loop detection 并持久化 run_state

### Phase C（1-2 天）

1. 引入 `memory_facade.py`
2. 将短期记忆改增量快照

### Phase D（0.5-1 天）

1. 清理残留模块（intent router/parser/clarification）
2. 更新测试夹具与 API 注入参数

---

## 八、工程验收指标（别只看“能跑”）

最少跟踪这 6 个指标：

1. `avg_steps_per_run`
2. `tool_schema_validation_failed_rate`
3. `clarification_needed_rate`
4. `clarification_success_rate`
5. `loop_block_rate`
6. `final_success_rate`

如果你做了单节点改造，但这些指标没有改善，说明只是“改写代码”，不是“改进系统”。

---

## 九、给进阶工程师的最后建议

不要把“单 LLM 节点”当成产品特性，它其实是架构约束：  
**模型负责决策，系统负责约束。**

当你把下面这四层切开，系统才会开始真正可维护：

1. `Decision`（planner）
2. `Prompt Injection`（builder + middleware）
3. `Guardrails`（pre/post/loop/approval）
4. `Memory`（short/long facade）

这就是 OpenClaw 范式最值得借鉴的地方，也是业务 Agent 从 Demo 走向工程化的分水岭。
