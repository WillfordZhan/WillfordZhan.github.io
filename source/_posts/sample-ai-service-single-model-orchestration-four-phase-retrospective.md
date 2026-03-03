---
title: "单模型编排四阶段改造复盘：从提示词、护栏到记忆与清理"
date: 2026-03-02 23:57:58
categories:
  - "AI"
tags:
  - "AI编排"
  - "FastAPI"
  - "MCP"
  - "Prompt Engineering"
  - "Guardrails"
  - "Memory"
  - "工程复盘"
  - "AI工作日志"
---

这次复盘对应 `sample_ai_service` 近期一轮比较完整的单模型编排内核治理。目标不是“再做一套新框架”，而是在不改外部 API 契约、不打乱 SSE 事件语义的前提下，把原本耦合较重的编排实现，收敛成可以继续演进的 runtime 分层。

先给结论：这轮改造真正完成的，不是几个 helper 函数的搬家，而是把项目推进到了“单 LLM 编排 + Java MCP 工具执行”的清晰架构上，并且把 prompt、guardrail、memory、cleanup 四个层面的改造都做到了可回归、可审计、可继续扩展。

## 一、STAR 总览

### S: Situation

改造开始前，项目虽然已经具备完整的 AI run 生命周期：

- `POST /api/mock-ai/runs`
- `GET /api/mock-ai/runs/{run_id}/events`
- `POST /api/mock-ai/runs/{run_id}/conversation-input`

但内核层面有四个明显问题：

1. Prompt 构建分散在 `orchestrator` 内部，planner、summary、direct answer 各写各的。
2. 护栏逻辑和事件编排、状态持久化强耦合，`orchestrator.py` 过重。
3. 短期记忆主要依赖事件回放，没有统一门面，也没有增量快照。
4. 历史遗留模块还在仓库里，容易误导后来的人以为旧链路仍在生产路径上。

换句话说，当时的系统是“能跑的单模型编排器”，但还不是“适合持续迭代的单模型编排内核”。

### T: Task

这一轮任务不是推倒重写，而是在几个硬约束下做渐进式重构：

1. 不改变对外 API 契约。
2. 不破坏已有 SSE 事件名和关键事件顺序。
3. 不重新引入第二套 intent/router 主流程。
4. 每个 phase 都要独立提交、独立回归、独立复盘。

所以这次工作的真实目标，是把单文件大编排器拆成“主循环 + runtime 组件”，同时给后续的 prompt 注入、护栏增强、长期记忆、兼容逻辑收敛留出明确落点。

### A: Action

## 二、四个 Phase 的改造亮点

| Phase | 目标 | 关键提交 | 亮点 |
|---|---|---|---|
| Phase 1 | Prompt Pipeline | `ab4168a` | 把 planner / summary / direct answer 的 prompt 收口成统一 runtime |
| Phase 2 | Guardrail Pipeline | `2d0e86c` | 把 schema、clarification、loop、final answer 护栏从主流程里抽离 |
| Phase 3 | Memory Facade | `95971aa` | 给短期记忆建立统一 facade，并支持 runtime state 快照 |
| Phase 4 | Cleanup and Convergence | `bb69e01` | 删除无引用遗留模块，真正完成结构迁移 |

### Phase 1：提示词流水线运行时化

关联提交：`ab4168a feat(编排): 抽取提示词流水线运行时`

这一阶段最重要的动作，是把 prompt 相关职责从 `orchestrator.py` 中拆出来：

- 新增 `prompt_builder.py`，统一 planner / summary / direct answer 的 prompt 常量与 payload 组装。
- 新增 `plan_engine.py`，封装 planner 的 LLM 调用，并复用已有纯函数解析能力。
- 把 `_plan_step()`、direct answer、summary 等 prompt 拼装行为改为委托 runtime 组件完成。

这一 phase 的价值不只是“代码更整洁”，而是建立了 prompt 的统一收口点。后续如果要加租户策略注入、实验 prompt、中间件式 prompt augmentation，不需要再回头撕主编排流程。

### Phase 2：护栏流水线显式化

关联提交：`2d0e86c refactor(编排): 抽取护栏处理流水线`

这一阶段新增了 `guardrails.py`，把以下能力纳入统一 pipeline：

- `SchemaGuardrail`
- `ClarificationGuardrail`
- `LoopGuardrail`
- `FinalAnswerGuardrail`

同时，`run_state` 的 runtime 维度也开始收口，至少承载了：

- `pending_tool_call`
- `tool_loop_signatures`

这一阶段的关键收益是：护栏逻辑不再散落在编排分支里，`orchestrator` 只保留事件顺序控制和主流程推进，真正开始像 orchestration，而不是“所有逻辑都堆在一个文件里”。

### Phase 3：记忆门面落地

关联提交：`95971aa feat(编排): 增加记忆门面运行时`

这一阶段新增 `memory_facade.py`，把短期记忆的读写路径显式化：

- `build_short_memory()`
- `append_turn_artifacts()`
- `search()` 预留长期记忆扩展点

更重要的是，短期记忆的读取策略从“只靠事件回放”变成：

1. 优先读 `run_state.short_memory_turns`
2. 缺失时再回退 event replay

这意味着 `run_state` 不再只是“待补参状态袋子”，而开始变成真正的 runtime state 容器。后续如果要接长期记忆、做更强的检索式上下文召回，调用点已经固定在 facade 上，不需要再分散改业务流程。

### Phase 4：清理遗留兼容模块

关联提交：`bb69e01 refactor(编排): 清理遗留兼容模块`

这一阶段做的是最容易被忽视、但对长期维护最关键的工作：真正把已经退出生产链路的模块删掉。

清理内容包括：

- 删除无引用的 `app/runtime_core/clarification.py`
- 删除无引用的 `app/runtime_core/intent_router.py`
- 更新 `app/runtime_core/__init__.py`
- 收敛 `orchestrator.py` 中的兼容逻辑，只保留当前仍有意义的恢复点

很多重构都会出现“新结构已经有了，但旧模块继续躺在仓库里”的情况。这次 Phase 4 的价值就在于，它不是只做抽离，还把真正无用的旧结构一并清场，减少后续维护误判。

### R: Result

## 三、结果与验证

### 1. 主编排器职责真正收敛了

改造完成后，`orchestrator.py` 的职责更接近一个真正的 orchestrator：

- 控制流程推进
- 控制事件写入顺序
- 装配 runtime 组件
- 承接 tool call 与最终收口

而 prompt、guardrail、memory 的主体实现，已经转移到 `app/runtime_core/runtime/`。

### 2. Runtime 分层已经成型

当前 runtime 层至少已经稳定包含：

- `prompt_builder.py`
- `plan_engine.py`
- `guardrails.py`
- `memory_facade.py`

这一点很关键，因为它意味着后续扩展可以围绕“能力层”推进，而不是继续在大文件里堆条件分支。

### 3. 当前总体架构已经有了清晰结论

结合 `当前项目总体架构` 文档，这个项目现在的定位已经比较明确：

- Python 服务负责 run 生命周期、SSE 事件流、ReAct 编排主循环，以及 prompt / guardrail / memory runtime。
- Java MCP 服务负责工具目录查询、工具执行和具体业务能力落地。

也就是说，这次四阶段改造不是孤立动作，而是在把仓库真正推进到“单 LLM 编排 + Java MCP 工具执行”的拆分架构上。

### 4. 测试结果是可追溯、可校验的

这里需要把两个时间点分开写清楚：

- 以复盘收口提交 `1a668f8` 为准，在临时 worktree 中执行 `pytest -q`，结果是 `46 passed`。
- 截至 2026 年 3 月 2 日，当前主线 HEAD 再次执行 `pytest -q`，结果已经是 `48 passed`。

这两个数字并不冲突。前者是这次四阶段改造复盘口径下的全量回归结果，后者说明主线在此之后又新增了测试覆盖。

### 5. 这次改造最值得复用的方法论

如果只看代码层面，这轮工作像是在做“分层重构”；但从工程方法上看，更重要的有三点：

1. 按 phase 逐段推进，而不是一次性重写。
2. 每个 phase 都有明确 commit，可审计、可回放、可回归。
3. 兼容路径是显式保留的，不是默认假设没人依赖旧行为。

这也是为什么这轮改造能在不打断现有 API 和 SSE 语义的前提下完成结构升级。

## 四、仍然保留的边界

这次改造完成的是“内核骨架重整”，不是所有问题都一次性收尾。当前仍有几个边界：

1. `_recover_pending_from_call_plan()` 仍是兼容型启发式逻辑。
2. `MemoryFacade.search()` 目前还是空实现。
3. `guardrails.py`、`memory_facade.py` 还可以继续补模块级单测。
4. `RunStore.set_run_state()` 仍是整包覆盖语义，runtime 层仍需谨慎处理状态合并。

这些边界不影响这轮改造的成立，但它们决定了后续迭代的优先级。

## 五、一句话结论

这次四阶段改造，完成的不是几个局部优化，而是把 `sample_ai_service` 从“可运行的单模型编排实现”，推进成了“具备清晰 runtime 分层、统一状态落点和后续演进空间的单模型编排内核”。
