# Source Material

- Date: 2026-03-19
- Repo: `ats_iot_ai`
- Topic: 把知识问答从本地 `knowledge.search` 编排改成 Dify App 终态委派

## Context Summary

- 原链路里 `tool_result` 会进入 transcript history。
- 知识库搜索结果较大时，后续 `plan / loop / verify / answer` 会重复回放这些历史，导致 `llm_request` payload 快速膨胀。
- 现场观测到单次请求体积从 200KB 级增长到 500KB 级。

## Decision

- 不继续在当前仓库里补完整 retrieval compression / memory projection 能力。
- 直接接入外部 Dify App 作为知识问答终态回答器。
- 每次调用 Dify `chat-messages` 时不传 `conversation_id`，确保每次新建 conversation。
- 本地只保存最终 answer 到 `final` history，不保存中间 SSE chunk。

## Code Changes

- 新增 `app/dify_app.py`
- 修改 `app/agent/runner.py`
- 修改 `app/agent/orchestrator.py`
- 新增 `tests/test_dify_app.py`
- 修改 `tests/test_turn_runner_planning.py`

## Local Config

- 新增 `DIFY_APP_ENABLED`
- 新增 `DIFY_APP_BASE_URL`
- 新增 `DIFY_APP_API_KEY`
- 新增 `DIFY_APP_TIMEOUT_SECONDS`
- 新增 `DIFY_APP_USER_PREFIX`
