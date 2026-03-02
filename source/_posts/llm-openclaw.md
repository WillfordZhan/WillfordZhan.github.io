---
title: "从双层意图到单 LLM 自决：OpenClaw 范式与护栏工程化落地"
date: 2026-03-02 17:18:10
categories:
  - "AI"
tags:
  - "OpenClaw"
  - "AI Orchestrator"
  - "Tool Guardrails"
  - "Function Calling"
  - "Memory"
  - "AI工作日志"
---

很多 AI 编排系统一开始都会走到同一个架构：

1. 先做 `intent parser`（判定 chat / tool）
2. 再进入 `ReAct`（plan/act/observe）

这套架构可控，但随着需求复杂化，经常出现三个问题：

1. 决策重复（先判一次 intent，再让 planner 再判一次）
2. 状态割裂（intent 状态和 tool 状态不同步）
3. prompt 分裂（意图 prompt 和执行 prompt 目标不一致）

这篇文章基于 OpenClaw 当前源码，拆解它的“单 LLM 节点 + 护栏保留”范式，并给出如何迁移到业务编排（例如 FastAPI + MCP）的工程化方案。

## 一、OpenClaw 的主链路不是双层：是单入口直入 Agent Loop

先看入口：`agentCommand` 直接调用 `runEmbeddedPiAgent`。

```ts
// src/commands/agent.ts
return runEmbeddedPiAgent({
  sessionId,
  sessionKey,
  prompt: effectivePrompt,
  ...
});
```

接着在 `runEmbeddedPiAgent` 里进入统一的 run loop，核心是持续 `runEmbeddedAttempt(...)`。

```ts
// src/agents/pi-embedded-runner/run.ts
while (true) {
  const attempt = await runEmbeddedAttempt({
    sessionId,
    sessionKey,
    prompt,
    ...
  });
  ...
}
```

再看 attempt 内部：把 tools、session、prompt 组好之后，直接 `activeSession.prompt(...)`。

```ts
// src/agents/pi-embedded-runner/run/attempt.ts
const { builtInTools, customTools } = splitSdkTools({ tools, ... });
({ session } = await createAgentSession({
  tools: builtInTools,
  customTools: allCustomTools,
  ...
}));

await activeSession.prompt(effectivePrompt);
```

这条链路里没有独立的 `intent_router -> policy_engine -> react executor` 分层。模型在同一会话循环内自决：

1. 直接回答
2. 调工具
3. 基于工具结果继续下一轮

OpenResponses 适配层也是同样思路：请求最终还是走 `agentCommand`，如果模型决定调 client tool，就返回 `function_call`。

```ts
// src/gateway/openresponses-http.ts
const result = await runResponsesAgentCommand({ ... });
if (stopReason === "tool_calls" && pendingToolCalls?.length) {
  // 输出 function_call
}
```

并且 `function_call_output` 会在下一轮作为 `tool` 角色拼回 prompt：

```ts
// src/gateway/openresponses-prompt.ts
} else if (item.type === "function_call_output") {
  conversationEntries.push({
    role: "tool",
    entry: { sender: `Tool:${item.call_id}`, body: item.output },
  });
}
```

这就是典型单节点范式：**一个 LLM 会话循环处理意图、工具选择、参数修复、最终回答**。

## 二、关键不是“要不要单节点”，而是“护栏是否完备”

很多团队把“单节点”理解成“放飞模型”。OpenClaw 的做法正相反：单节点决策，但护栏分层很重。

### 1) Tool Schema 护栏（调用前）

OpenClaw 会先做 schema 规范化，兼容不同 provider 的 JSON schema 约束。

```ts
// src/agents/pi-tools.schema.ts
export function normalizeToolParameters(...) {
  // schema 规范化
}
```

然后在工具执行层做参数归一化与必填校验，缺参直接抛错。

```ts
// src/agents/pi-tools.read.ts
assertRequiredParams(record, requiredParamGroups, tool.name);
```

这层作用：

1. 防止模型参数漂移直接打爆工具
2. 把错误尽量收敛成“可观测、可恢复”的结构化异常

### 2) before_tool_call 护栏（调用时）

每个工具都会被 `wrapToolWithBeforeToolCallHook(...)` 包装。

```ts
// src/agents/pi-tools.ts
wrapToolWithBeforeToolCallHook(tool, {
  agentId,
  sessionKey,
  loopDetection: resolveToolLoopDetectionConfig(...),
})
```

在 hook 内可以做两类动作：

1. `block`（直接拒绝）
2. 参数改写（归一化/补充）

```ts
// src/agents/pi-tools.before-tool-call.ts
const hookResult = await hookRunner.runBeforeToolCall(...)
if (hookResult?.block) return { blocked: true, reason: ... }
```

### 3) Tool Loop Detection 护栏（调用后/全局）

OpenClaw 的 loop detection 不是简单“重复 N 次就停”，而是识别模式：

1. generic repeat
2. known poll no progress
3. ping pong
4. global circuit breaker

```ts
// src/agents/tool-loop-detection.ts
type LoopDetectorKind =
  | "generic_repeat"
  | "known_poll_no_progress"
  | "global_circuit_breaker"
  | "ping_pong";
```

在 `before_tool_call` 阶段就会判断，达到 critical 直接 block。

### 4) 高风险执行审批护栏（Human-in-the-loop）

`exec` 工具会走 allowlist/security/ask 策略，不满足条件进入审批挂起。

```ts
// src/agents/bash-tools.exec-host-gateway.ts
const requiresAsk = requiresExecApproval(...)
if (requiresAsk) {
  const registration = await registerExecApprovalRequestForHostOrThrow(...)
  return { pendingResult: { details: { status: "approval-pending", ... } } }
}
```

这里的 HITL 不是“对话澄清”，而是“执行授权”。

## 三、Memory 不是一个开关，而是两层机制

OpenClaw 的 memory 是“写入机制 + 检索工具”组合。

### 1) session-memory hook：会话结束/重置时沉淀

`session-memory` hook 在 `new/reset` 时把会话摘要写到 memory 文件。

```ts
// src/hooks/bundled/session-memory/handler.ts
if (event.type !== "command" || !isResetCommand) return;
await fs.mkdir(memoryDir, { recursive: true });
await fs.writeFile(memoryFilePath, entry, "utf-8");
```

### 2) memory-core plugin：把 memory 能力暴露成工具

```ts
// extensions/memory-core/index.ts
api.registerTool(... { names: ["memory_search", "memory_get"] })
```

### 3) memory_search/get：运行时检索

```ts
// src/agents/tools/memory-tool.ts
const rawResults = await manager.search(query, { ... })
const result = await manager.readFile({ relPath, from, lines })
```

### 4) 索引配置与同步

memory search 配置可控制 source/store/vector/sync/session 增量行为。

```ts
// src/agents/memory-search.ts
export function resolveMemorySearchConfig(...) {
  // merge + normalize + clamp
}
```

一句话总结：OpenClaw 的 memory 是**被工具化的长期上下文系统**，而不是“自动往 prompt 塞历史”。

## 四、为什么“单节点 + 护栏”更适合中后期工程系统

### 优势

1. 决策收敛：避免 parser 和 planner 双重漂移
2. 上下文一致：模型在同一循环里消费 history/tool output
3. 观测聚焦：只跟踪一条 plan/act/observe 链

### 代价

1. 对 system prompt 质量要求更高
2. 护栏设计要足够硬（否则模型失控）
3. 评估体系要从“分类准确率”转为“任务成功率 + 成本 + 风险率”

## 五、给业务编排系统的迁移蓝图（双层 -> 单节点）

下面这套是我推荐的低风险迁移路径。

### Phase A：收敛决策入口

1. 移除前置 mode/intent 分支
2. 首轮直接进入 planner（输出 CALL_TOOL/CLARIFY/RESPOND）
3. 保留旧事件做兼容开关（便于回滚）

### Phase B：把护栏前置统一

1. 每次 tool call 前固定做 schema/required/unknown 校验
2. argument error 统一进入澄清状态机
3. 引入 loop detector（warning + block 两级）

### Phase C：增加可观测与灰度

建议至少追踪：

1. `tool_schema_validation_failed_rate`
2. `clarification_needed_rate`
3. `tool_loop_block_rate`
4. `avg_steps_per_run`
5. `task_success_rate`

### Phase D：高风险动作审批（可选）

1. 把“危险工具”从普通 tool call 中分离
2. 增加 approval pending/resume 协议
3. UI/审计链路接入

## 六、一个可执行的单节点伪代码模板

```python
for step in range(max_steps):
    plan = llm_plan(query, history, observations, tools)

    if plan.action == "RESPOND":
        return final(plan.answer or summarize(observations))

    if plan.action == "CLARIFY":
        save_pending_state(plan)
        return clarification_needed(plan.question)

    call = normalize_and_validate(plan.tool_name, plan.arguments)
    if call.blocked:
        observations.append(call.feedback)
        continue

    if loop_detector.should_block(call):
        return final("检测到重复无进展调用，已中止并建议改问法")

    result = call_tool(call)
    observations.append(result)

    if result.argument_error:
        pending = build_pending_from_error(call, result)
        return clarification_needed(build_question(pending))
```

核心思想：

- **模型负责决策**
- **系统负责约束**

## 七、结语

“单 LLM 节点”不是去掉工程化，而是把工程化集中在护栏和观测上。

如果你的系统已经因为 `intent parser + react` 出现状态同步负担，建议不是“把 parser 做得更复杂”，而是先收敛成单循环，再把护栏做厚。

这条路线在 OpenClaw 源码里已经是一条可运行、可扩展、可审计的工业化路径。

