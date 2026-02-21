---
title: "Java/Python MCP 401 排查里程碑：Token 对齐与方案简化"
date: 2026-02-22 00:45:55
categories:
  - "AI"
tags:
  - "MCP"
  - "401排查"
  - "Python"
  - "Java"
  - "里程碑"
  - "AI工作日志"
---

本篇记录本次 Java/Python MCP 401 问题的收敛结论、方案调整与发布证据。

## 里程碑结论

- 401 根因已确认：Java 侧与 Python 侧在 MCP 鉴权 token 上不一致，导致请求头 `X-AI-MCP-TOKEN` 校验失败。
- 方案已简化：Python 侧仅保留一个配置入口 `MCP_API_TOKEN`，默认值固定为 `AAA`，移除复杂 fallback 链路，减少歧义与隐式行为。

## 方案变更说明（单一目的）

本次变更目标只有一个：让 Python MCPClient 的 token 来源明确、默认行为稳定，避免再次出现“配置看似生效但实际不一致”的 401。

- 配置入口：`MCP_API_TOKEN`
- 默认值：`AAA`
- 行为：若未显式设置环境变量，统一走默认 `AAA`；若设置了 `MCP_API_TOKEN`，严格使用该值。

## 验证证据

### 1) 直连 probe（MCP 可达性 + 工具数量）

命令：

```bash
curl -sS -X POST 'http://127.0.0.1:10001/ai/mcp/tools/list' \
  -H 'Content-Type: application/json' \
  -H 'X-AI-MCP-TOKEN: AAA' \
  -d '{}'

curl -sS 'http://127.0.0.1:8000/system/mcp/status?refresh=true'
```

结果要点：

- `tools/list` 返回 `code=200`
- `system/mcp/status` 返回：
  - `connected=true`
  - `tool_count=10`
  - `detail="ok (tools=10)"`

### 2) Python 单测

命令：

```bash
pytest tests/test_mcp_client.py
```

结果要点：

- `collected 5 items`
- `5 passed`
- 核验覆盖了：
  - 未设置 `MCP_API_TOKEN` 时默认 `AAA`
  - 设置 `MCP_API_TOKEN` 时优先使用环境变量值

## 回滚与风险说明（按 SPEC）

### 可追溯

- 结论、命令、结果均已固化在本工作日志。
- 验证入口固定：`/system/mcp/status?refresh=true` 与 `tests/test_mcp_client.py`。

### 可回退

若线上出现不兼容，可按最小改动回退：

1. 回退 Python 侧本次 token 简化提交（仅回退 token 配置相关变更）。
2. 恢复旧配置逻辑后，立即执行：
   - `pytest tests/test_mcp_client.py`
   - `curl .../system/mcp/status?refresh=true`
3. 以 `connected`、`tool_count`、401 告警是否消失作为回退验收。

### 单一目的变更

- 本次只处理 MCP token 对齐与默认值策略，不扩展到工具路由、SSE、RunStore 等其他模块。
- 遵循最小变更面，降低联动回归风险。

## 后续观察项

- 统一各环境（dev/test/prod）`MCP_API_TOKEN` 注入方式，避免“本地默认可用、环境变量缺失”导致偏差。
- 监控 Java MCP 401/403 比例，作为 token 配置漂移的早期信号。
