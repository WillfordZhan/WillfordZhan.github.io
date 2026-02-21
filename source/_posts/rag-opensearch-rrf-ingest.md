---
title: "RAG可插拔改造复盘：OpenSearch混合检索、RRF与增量Ingest"
date: 2026-02-21 21:28:48
categories:
  - "AI"
tags:
  - "RAG"
  - "OpenSearch"
  - "工程复盘"
  - "STAR"
  - "AI工作日志"
---

## 一句话结论

这轮我把 RAG 从“单一本地检索”改造成“可插拔检索链路”：新增 OpenSearch Provider（BM25+向量+过滤）、Hybrid RRF、低置信/复杂 Query 的 rerank 触发、分钟级增量 ingest + upsert，并通过 fallback + 默认开关关闭确保 `/ai/runs` 主链路稳定不受影响。

## Done 标准

- [x] 检索 Provider 可插拔：本地内存与 OpenSearch 可切换。
- [x] OpenSearch 支持 BM25 + 向量召回 + 租户/可见性过滤。
- [x] 支持 Hybrid RRF 融合，且可开关。
- [x] 低置信或复杂 Query 才触发 rerank，避免全量增延迟。
- [x] ingest 支持分钟级调度、增量检测、文档删除同步与 upsert。
- [x] OpenSearch 异常时自动 fallback 到本地检索。
- [x] 默认开关关闭，且 `/ai/runs` 主链路回归通过。

## Situation（背景）

现状是 AI Control Plane 已有稳定的 `/ai/runs` 异步链路，同时 RAG 只有本地内存检索能力。业务目标是把检索能力升级为可插拔且可渐进上线，但不能把风险引入主链路。

证据锚点：
- 主链路仍以 `/ai/runs` 为核心接口：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/README.md:4`
- RAG 与主链路并存：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/README.md:13`
- 应用入口中 `/ai/runs` 保持既有定义：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/api.py:98`

## Task（任务）

在不破坏现有 `/ai/runs` 行为的前提下，完成 RAG 可插拔改造，覆盖以下能力：

1. OpenSearch Provider：BM25 + 向量 + 过滤。
2. Hybrid RRF 融合策略。
3. 低置信/复杂 Query rerank 触发机制。
4. 分钟级增量 ingest + upsert。
5. fallback 到本地检索，默认开关关闭。

证据锚点：
- 开关默认关闭：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/config.py:17`
- 统一读取环境变量开关：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/config.py:66`

## Action（行动）

### 1) 抽象 RetrievalManager，落地 Provider 可插拔

- 通过 `RetrievalManager` 注入 `local_provider` 和 `opensearch_provider`，把“检索策略编排”与“具体检索实现”解耦。
- 默认仍可只用本地检索，避免强依赖 OpenSearch。

证据锚点：
- 管理器依赖注入点：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/retrieval_manager.py:141`
- OpenSearch provider 延迟初始化（按开关启用）：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/retrieval_manager.py:263`

### 2) 新增 OpenSearch Provider（BM25 + 向量 + 过滤）

- BM25 使用 `multi_match`，向量使用 `knn`，两路都带 `tenant_dept_id` 与 `visibility` 过滤，保证多租户隔离语义一致。
- 通过 `OpenSearchClient` 封装 `search / bulk upsert / delete_by_query`。

证据锚点：
- BM25 构造：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/opensearch/query_builder.py:20`
- 向量查询与 filter：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/opensearch/query_builder.py:47`
- Provider 双路召回：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/retrieval_manager.py:96`
- OpenSearch 客户端能力：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/opensearch/client.py:46`

### 3) 加入 Hybrid RRF（可开关）

- OpenSearch 两路结果先并行召回，再按开关选择：
  - 开启：`reciprocal_rank_fusion`
  - 关闭：`combine_by_best_score`
- 这样可以在“相关性融合效果”与“实现复杂度”之间保留调优空间。

证据锚点：
- RRF 实现：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/hybrid_rrf.py:8`
- Manager 中融合开关：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/retrieval_manager.py:227`

### 4) 只在必要时触发 rerank（低置信/复杂 Query）

- 触发规则：
  - 置信度低（如 `low`）直接触发；
  - 或 Query 足够复杂（token/长度/关键词/标点特征）。
- 目标是避免对所有请求统一加 rerank 延迟。

证据锚点：
- 触发策略定义：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/rerank/trigger.py:33`
- 检索流程中条件触发：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/retrieval_manager.py:186`

### 5) 增量 ingest + upsert（分钟级）

- 用 `IngestOffsetTracker` 对文档签名做差分，只处理变更/删除文档。
- `RAGIngestScheduler` 支持周期触发（默认 60 秒）与手动触发。
- upsert 路径先更新本地索引，再尝试 OpenSearch 同步，失败不阻塞本地可用性。

证据锚点：
- 调度器执行与 delta 计算：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/ingest/scheduler.py:97`
- 偏移签名与提交：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/ingest/offset_tracker.py:22`
- OpenSearch replace/upsert：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/opensearch/ingest_adapter.py:13`
- 分钟级配置默认值：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/config.py:48`

### 6) 稳定性保护：fallback、本地优先可用、默认关闭

- OpenSearch 检索异常时自动 fallback 到本地检索，避免请求失败。
- OpenSearch ingest 异常仅记日志，不影响本地索引完成更新。
- 所有新能力默认开关为 `False`，采用“显式开启”策略。

证据锚点：
- 检索 fallback：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/retrieval_manager.py:240`
- ingest 异常降级：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/retrieval_manager.py:198`
- 默认关闭：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/config.py:17`

## Result（结果）

功能结果：

1. RAG 路由与主链路解耦并可独立启停，满足“可插拔”。
2. OpenSearch 双路召回 + RRF + rerank 触发链路完整打通。
3. ingest 具备分钟级增量 upsert 与删除同步能力。
4. fallback 生效，默认不开启 OpenSearch 依赖。
5. `/ai/runs` 主链路回归通过，未出现行为回归。

证据锚点：
- RAG 初始化失败时降级为空检索器，避免应用启动失败：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/api.py:49`
- `/ai/runs` 创建/事件/输入端点存在且逻辑闭环：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/api.py:98`
- `/ai/runs` 回归测试：`/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/tests/test_runs.py:107`

## 验收证据（测试命令与结果）

执行日期：2026-02-21

1. RAG 可插拔核心能力测试
- 命令：`cd /Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service && pytest -q tests/test_rag_retrieval_manager.py tests/test_rag_ingest_scheduler.py tests/test_rerank_trigger.py tests/test_rrf.py`
- 结果摘要：`11 passed in 0.15s`
- 覆盖点：fallback、RRF 融合排序、rerank 触发、增量 ingest 行为。

2. `/ai/runs` 主链路回归测试
- 命令：`cd /Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service && pytest -q tests/test_runs.py tests/test_sqlite_store.py`
- 结果摘要：`11 passed in 0.50s`
- 覆盖点：run 创建、SSE replay/tail、`Last-Event-ID` 校验、`/input` 追加、权限隔离。

3. 全量回归
- 命令：`cd /Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service && pytest -q`
- 结果摘要：`36 passed in 0.64s`

## 风险与假设

风险：

1. 当前向量向量化为 `pseudo_embedding`（占位实现），语义召回上限受限。
2. OpenSearch 依赖索引 mapping/knn 插件正确配置；若环境不一致会触发 fallback。
3. ingest offset 文件是本地文件状态，在多实例并发部署下需做共享状态治理。

假设：

1. 生产环境具备可用 OpenSearch 集群与网络连通性。
2. 文档源（JSON）更新频率与分钟级调度策略匹配。
3. rerank 服务后续可替换为真实模型实现（当前默认 `Noop`）。

## 回滚路径

优先走运行时回滚（无需改代码）：

1. 关闭 RAG 新能力开关并重启服务：
- `RAG_OPENSEARCH_ENABLED=false`
- `RAG_HYBRID_RRF_ENABLED=false`
- `RAG_RERANK_ENABLED=false`
- `RAG_INGEST_SCHEDULER_ENABLED=false`
2. 验证 `/ai/runs` 与 `/rag/retrieve` 基础可用：
- `pytest -q tests/test_runs.py tests/test_sqlite_store.py`
- `pytest -q tests/test_rag_retrieval_manager.py`
3. 如需代码级回退，回退文件集合：
- `/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/rag/`
- `/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/app/api.py`
- `/Users/willfordzhan/Desktop/Work/ats_iot_ai-rag-service/tests/test_rag_*`

## 后续改进项（责任人/截止建议）

1. 接入真实 embedding + reranker 模型，替换占位实现  
责任人建议：RAG 后端负责人  
截止建议：2026-03-06

2. 增加 OpenSearch 索引模板与启动自检（mapping/knn/字段一致性）  
责任人建议：平台/运维负责人  
截止建议：2026-03-01

3. 为 ingest 调度补充多实例一致性方案（如 Redis 锁 + 共享 offset）  
责任人建议：基础架构负责人  
截止建议：2026-03-08

4. 增补线上可观测性：检索命中率、fallback 率、rerank 命中率与时延分位  
责任人建议：可观测性负责人  
截止建议：2026-03-10

## 面试陈述版（60-90秒）

这轮我主导了 RAG 的可插拔改造，核心目标是“能力升级但不影响主链路”。技术上我把检索抽象成 Manager + Provider：默认本地检索，按开关接入 OpenSearch 双路召回（BM25+向量+过滤），再通过 Hybrid RRF 做融合；同时对 rerank 采用条件触发，只在低置信或复杂问题执行，控制延迟成本。数据侧我补了分钟级增量 ingest + upsert，支持变更与删除同步。稳定性上设计了两层降级：OpenSearch 检索失败回落本地、OpenSearch ingest 失败不影响本地索引。最终验证上，RAG 与主链路测试全部通过：RAG 核心 11 项、`/ai/runs` 回归 11 项、全量 36 项通过，达成可上线的灰度前置条件。
