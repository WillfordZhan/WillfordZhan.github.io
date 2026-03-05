---
title: "Dify 知识库 Tool 集成策略：Java MCP 与 Python 双路径"
date: 2026-03-05 19:30:41
categories:
  - "AI"
tags:
  - "Dify"
  - "MCP"
  - "知识库"
  - "架构"
  - "AI工作日志"
---

## 背景

在 iot-framework 的 AI 链路里，我们已经有一条稳定的工具调用架构：

- Java AI Gateway 对外暴露 `/api/ai/*`
- Python `ats_iot_ai` 负责编排与执行（LangGraph + SSE）
- Java MCP 负责 `/ai/mcp/tools/list` 与 `/ai/mcp/tools/call`

这次目标是把 Dify 知识库检索接成一个 tool，纳入现有 tool list。

## 现场排摸结论（2026-03-05）

### 1) 页面地址不是检索 API

给出的 URL：

- `https://ai-studio.allthinkstars.com:10443/datasets/{dataset_id}/documents`

这是 Console 页面（HTML），不是后端服务调用用的检索接口。

### 2) 真正检索接口是 `/v1/datasets/{dataset_id}/retrieve`

最小可用方式：

```bash
curl -k -X POST 'https://ai-studio.allthinkstars.com:10443/v1/datasets/<dataset_id>/retrieve' \
  -H 'Authorization: Bearer <DATASET_API_KEY>' \
  -H 'Content-Type: application/json' \
  -d '{"query":"铸造工艺优化"}'
```

### 3) Console 会话 token 不能替代 API Key

排摸中验证到：

- 浏览器 Cookie / Console access_token 可以访问 `GET /console/api/datasets/.../documents`
- 但不能用于 `POST /v1/datasets/.../retrieve`，会返回 `401 Access token is invalid`

结论：服务端 tool 接入必须使用 Dify API Key（Bearer），不能用账号密码或浏览器会话。

### 4) 版本兼容点：Dify 1.13.0 的 `score_threshold_enabled`

在该实例上，若请求体带 `retrieval_model` 但缺少 `score_threshold_enabled`，可能报：

- `500 internal_server_error: 'score_threshold_enabled'`

所以请求模板建议显式带：

```json
{
  "query": "铸造工艺优化",
  "retrieval_model": {
    "search_method": "semantic_search",
    "reranking_enable": false,
    "top_k": 5,
    "score_threshold_enabled": true,
    "score_threshold": 0.3
  }
}
```

## 集成策略

## 方案 A：接入 Java MCP（推荐为正式方案）

把 Dify KB 查询实现为 Java MCP 的一个标准工具（例如 `knowledge.search`）。

### 为什么推荐放 Java MCP

- 统一工具治理：继续沿用 `tools/list -> tools/call` 单入口
- 统一安全能力：密钥管理、审计、租户边界、限流/熔断集中在一层
- 编排层解耦：Python 不承载 Dify 协议细节，保持“编排器”角色
- 可替换性更好：后续换向量库或别的 KB Provider，只改 MCP 实现

### 建议 Tool Contract

输入参数：

- `query`（required）
- `dataset_id`（optional，默认取配置）
- `top_k`（optional）
- `score_threshold`（optional）
- `search_method`（optional：`semantic_search | keyword_search | hybrid_search`）

输出参数（建议标准化）：

- `items[]`
- `items[].document_id`
- `items[].document_name`
- `items[].score`
- `items[].snippet`
- `provider`（`dify`）
- `dataset_id`

错误映射：

- 参数校验失败 -> `ARGUMENT_ERROR`
- 上游 4xx/5xx -> `UPSTREAM_ERROR`
- 超时 -> `TIMEOUT_ERROR`

配置建议：

- `DIFY_BASE_URL`
- `DIFY_API_KEY`
- `DIFY_DATASET_ID_DEFAULT`
- `DIFY_DATASET_ID_WHITELIST`（可选）
- `DIFY_TIMEOUT_MS`

## 方案 B：接入 Python（推荐仅 PoC）

可直接在 Python 侧新增 `dify_knowledge_search` 工具函数并挂入编排。

优点：

- 改动快，能快速验证召回质量与业务价值

缺点：

- 破坏当前“Python 编排、Java 工具治理”的边界
- 密钥与重试熔断能力会在双端分散
- 后续迁回 Java MCP 会产生二次改造

建议：PoC 可 Python 先行，正式上线收敛回 Java MCP。

## 分阶段落地计划

### Phase 1：最小可用

- Java MCP 新增 `knowledge.search`
- 固定单 dataset（配置读取）
- 返回裁剪后的 `items[]`，避免超长原文直接灌给模型

### Phase 2：可运营

- 支持 `dataset_id` 入参 + 白名单校验
- 增加超时、重试、熔断与指标
- 加调用审计字段（tenantId/userId/requestId）

### Phase 3：可扩展

- 抽象 provider SPI（Dify / OpenSearch / Milvus）
- 提供统一工具语义，不改变上层 prompt/tool 使用方式

## 安全注意事项

- 不在代码或日志中打印完整 API Key
- 已在聊天或工单中暴露过的 key 需要立即轮换（revoke + recreate）
- 账号密码和浏览器 token 不进入服务端配置
- 在公开文档中只保留接口结构，不保留真实密钥与内部主机细节

## 可直接落地的开发 Tips

- `score_threshold_enabled` 和 `score_threshold` 建议总是成对下发，不要依赖默认值。不同 Dify 版本在 `retrieval_model` 的默认行为并不稳定。
- `knowledge.search` 的返回数据要做“面向 LLM 的裁剪”，尤其是 `snippet` 长度。建议限制在 200~500 字符，避免一次 tool_result 过大导致后续回答质量下降。
- `dataset_id` 建议支持“参数覆盖 + 默认值 + 白名单”三层策略：调用灵活、运行安全、配置可控。
- 上游错误要做语义映射，不要透传 HTTP 文本。建议统一为 `tool_auth_error`、`tool_upstream_error`、`tool_args_invalid` 等稳定错误码。
- 工具审计日志建议只记录 `dataset_id`、`hit_count`、`latency_ms`、`status`，不要记录 query 全量文本，最多记录短 preview。
- 调试顺序建议固定：先 `tools/list` 看 schema 是否生效，再 `tools/call` 跑最小 query，最后再测异常路径（401/429/timeout）。
- 回归测试里至少覆盖 6 类场景：参数缺失、参数越界、白名单拒绝、鉴权失败、上游异常、正常命中并标准化返回。

## 小结

这次接入的关键不是“能不能请求到 Dify”，而是“把知识库能力放到正确的治理层”。

在当前 iot-framework AI 架构下，正式方案应优先选择 Java MCP 接入，Python 保持编排层纯净；若要快速试验，可以 Python 先跑通，但应预留迁回 Java MCP 的路径。
