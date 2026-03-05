---
title: LangGraph Checkpoint 改造复盘：从内存快照到可恢复执行
date: 2026-03-06 01:20:00
tags:
  - AI工作日志
  - LangGraph
  - Checkpoint
  - 复盘
  - STAR
categories:
  - AI
---

这次改造的目标很朴素：让编排流程别再“断电失忆”。

项目原来已经有 LangGraph `thread_id`，也已经把澄清流程做成了 interrupt/resume 语义。但 checkpoint 用的是进程内内存 saver，服务重启后现场直接蒸发。于是用户问一句“继续”，系统看着你，内心是“我是谁我在哪”。

下面按 STAR 记录这次改造，顺便把关键 QA 和踩坑细节摊开讲清楚。

## S（Situation）场景

现网编排链路是：

- FastAPI API 层（会话 + SSE）
- LangGraph 单轨编排（plan/tool_call/clarify/chat）
- Java MCP 工具执行
- Python 会话事件存储（以及 Java store 适配）

当时的关键问题是：

1. checkpoint 是 `InMemorySaver`，只能活在当前 Python 进程内。
2. `interrupt/final` 路径直接删线程 checkpoint，恢复语义全靠事件层“重来一轮”。
3. 编排代码里同时关心“checkpoint 后端构造”和“清理策略”，职责有点缠在一起。

## T（Task）目标

本轮目标拆成三件事：

1. 接入 **SQLite 持久化 checkpoint**，路径放项目 `db/` 下。
2. 保留 `thread_id=conversation_id`，让恢复语义稳定可追踪。
3. 把“后端接入”与“清理策略”分离：
   - 后端工厂负责给图提供 saver
   - policy 决定 interrupt/final 是否清理 checkpoint

## A（Action）行动

### 1) 工厂化接入：provider 和 policy 解耦

新增了 checkpoint 模块，拆成两类职责：

- `CheckpointSettings`：只管 provider/path
- `CheckpointPolicy`：只管 clear on interrupt/final

关键代码（简化版）：

```python
# app/langgraph/checkpointing.py
@dataclass(frozen=True)
class CheckpointSettings:
    provider: str = "sqlite"
    sqlite_path: str = "db/langgraph_checkpoints.sqlite3"

@dataclass(frozen=True)
class CheckpointPolicy:
    clear_on_interrupt: bool = False
    clear_on_final: bool = True
```

这样 orchestrator 不再关心 sqlite 怎么连，只消费 `saver + policy`。

### 2) Orchestrator 侧只做“调用策略”

编排器只保留三件事：

1. 使用同一 `thread_id` 调 graph。
2. 根据 policy 决定是否删 checkpoint。
3. 在 shutdown 时关闭 checkpointer 资源。

核心逻辑（简化）：

```python
if self._checkpoint_policy.clear_on_interrupt:
    await self._delete_checkpoint_thread(conversation_id)

if self._checkpoint_policy.clear_on_final:
    await self._delete_checkpoint_thread(conversation_id)
```

### 3) 典型 case 补齐

新增 `Case 12：Checkpoint 持久化恢复（服务重启后 resume）`，核心验证点：

1. 首轮触发 `clarification_needed` 并进入等待态。
2. 服务重启后，次轮输入可继续同一会话。
3. 事件链路连续，不出现状态丢失。

对应脚本也补了 `case12_checkpoint_persist_resume` 入口。

### 4) 单测与真实用例

- 单测：`test_checkpointing.py` + `test_orchestrator_langgraph.py`
- 真实脚本：`run_typical_cases.sh` 跑 `case11`、`case12`

## R（Result）结果

### 成果

1. Checkpoint 从内存升级为 SQLite 持久化，落盘到 `db/langgraph_checkpoints.sqlite3`。
2. `thread_id=conversation_id` 统一，恢复执行路径稳定。
3. policy 与 provider 解耦，后续要换 Postgres/Redis 或调整清理策略都不需要改主编排流程。
4. `case11`（interrupt->chat）与 `case12`（checkpoint resume）均可跑通核心链路。

### 残留/边界

- `case12` 如果续问走外部工具，仍可能受上游 MCP 超时影响；这属于工具面 SLA，不是 checkpoint 机制问题。

## 这次踩过的坑（重点）

### 坑 1：同步 SqliteSaver 直接上 async 图

现象：

- `ainvoke/aget_state` 直接报错：
  - `SqliteSaver does not support async methods`

原因：

- 图是 async 执行，必须用 async checkpointer。

修复：

- 切到 `AsyncSqliteSaver` 路径。

### 坑 2：`AsyncSqliteSaver` 与 aiosqlite 版本接口差异

现象：

- 报 `Connection has no attribute is_alive`。

原因：

- `langgraph-checkpoint-sqlite` 在当前组合下依赖了旧接口习惯。

修复：

- 用官方 `from_conn_string` 创建 saver，并加了兼容补丁（缺 `is_alive` 时补一个兼容方法）。

副作用评估：

- 只影响 checkpointer 初始化兼容，不影响业务 state schema。

### 坑 3：拿“工具超时”误判“checkpoint失败”

现象：

- case 恢复后出现 `conversation_failed`。

根因：

- 日志显示是 `mcp request timed out`，并非 checkpoint 恢复失败。

处理：

- 将 checkpoint 验证 case 的续问改为 no-tool 路径，先保证 checkpoint 机制验收干净；
- 工具路径稳定性单独作为 MCP SLA 议题处理。

## 讨论 QA（这次对话里最常见的追问）

### Q1：checkpoint 到底有什么用？

A：保存的是“图执行现场”，不是业务数据库。它让你在中断、重启、故障后能继续执行，而不是重跑整轮。

### Q2：checkpoint 和 memory 是一回事吗？

A：不是。

- checkpoint：流程状态（做到哪一步）
- memory：语义上下文（知道什么）

最佳实践是两者并存。

### Q3：引入 checkpoint 后是不是全自动，不用管了？

A：执行恢复是框架自动；但你仍要做策略治理：

1. thread_id 规范
2. 清理策略（interrupt/final）
3. state 可序列化约束
4. 敏感信息边界

### Q4：支持 MySQL 吗？

A：官方 Python 主路径优先 SQLite/Postgres。MySQL 有社区实现，但生产建议优先官方维护链路。

## 代码改造清单（核心文件）

- `app/langgraph/checkpointing.py`
- `app/orchestrator.py`
- `app/api.py`（shutdown 资源关闭）
- `scripts/run_typical_cases.sh`
- `典型case.md`（新增 Case 12）
- `tests/test_checkpointing.py`

## 后续建议

1. 把 checkpoint 后端再抽象成可观测组件（写入耗时、恢复命中率、清理统计）。
2. 给 MCP timeout 增加路由策略（retry / degrade / clarify），避免工具面抖动直接打断会话体验。
3. 把 `Case12` 的“服务重启动作”做成可插拔 hook（脚本已预留 `RESTART_HOOK`），接入 CI 夜间回归。

这轮改造最大的价值不是“换了个存储”，而是把“能跑”推进到了“能恢复、能解释、能扩展”。
