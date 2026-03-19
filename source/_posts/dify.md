---
title: "把知识问答下沉到 Dify 终态回答器"
date: 2026-03-19 11:24:24
categories:
  - "AI"
tags:
  - "Dify"
  - "RAG"
  - "Agent"
  - "开发回顾"
  - "AI工作日志"
---

这次改动不复杂，判断比实现更重要。

我们原来的知识问答链路是本地 Agent 自己调 `knowledge.search`。问题不是它查不到东西，而是查出来的结果太大，`tool_result` 又会进 transcript，后面的 `plan`、`loop`、`verify`、`answer` 几轮都会把这包结果再塞回 prompt。实际看下来，单次 `llm_request` 很快就从两三百 KB 涨到五百多 KB，最后上下文窗口被检索结果自己吃掉了。

现场证据很直接：一轮知识库搜索成功后，后续 `llm_request` 事件体持续膨胀；而且这些体积不是答案本身长，而是历史里重复带了大块检索结果。这个问题继续在本地 RAG 上修，也不是不能修，但要补的不是一个小 patch，而是一套完整的 `retrieve -> rerank -> compress -> memory_view / answer_view` 分层。短期要止血，这条路太重了。

所以这次我把知识问答改成了另一种收口方式：命中知识问答后，不再让本地 runner 继续走 tool/planner 链路，而是直接把问题委派给一个 Dify App，让它自己完成内部知识检索和最终生成。本地只保留三件事：输入护栏、终态路由、最终回答落库。

## 原链路卡在哪里

原来这条链路的问题主要有三个。

第一，`tool_result` 既承担审计职责，又承担 prompt memory 职责。知识库结果一大，审计层和运行时上下文层就绑死了。要查问题时确实方便，但代价是模型每一轮都在反复吞老的检索结果。

第二，本地 runner 对知识检索没有单独的高层能力边界。`knowledge.search` 更像一个“裸检索工具”，返回的还是偏 raw 的证据包。Planner、Verifier、Answer 阶段都要自己再消费这包结果，链路很容易越跑越肥。

第三，这个问题不是简单调小 `top_k` 就能解决。只改召回数只能止一点血，真正没处理的是结果投影和上下文回放边界。换句话说，问题落在“检索结果怎么进 Agent”，不只落在“检索结果召回多少”。

## 为什么直接下沉到 Dify

这次没有继续在本地把 RAG 链路做厚，而是直接把知识问答下沉到 Dify App，当成知识问答的终态回答器。

原因很现实。

一是它已经有现成的知识库和生成链路，不需要再在当前仓库里补一套完整的 retrieval workflow。

二是它的 App API 支持 `blocking` 和 `streaming` 两种模式。对我们当前这条链路来说，`blocking` 更合适：本地只拿最终答案，不把外部流式中间 chunk 再写回 transcript。

三是它天然把“外部 RAG 细节”和“本地会话历史”隔开了。这个边界一旦立住，至少不会再出现一轮知识搜索把后续几轮上下文一起拖爆的情况。

## 这次怎么落

这次实现没有大拆主编排，只是在 runner 前面加了一个终态委派分支。

新增了一个 `DifyAppClient`，专门负责调外部 Dify App 的 `POST /chat-messages`。这里固定用了 `response_mode=blocking`，而且请求体里明确不传 `conversation_id`。这样做的目的只有一个：每次询问都让 Dify 新建一轮 conversation，不复用它上一轮 API 对话上下文。

本地 runner 命中这个分支后，会直接走 Dify 终态委派，不再进入原来的 `tool_catalog.load -> plan -> loop -> verify -> answer` 链路。Dify 返回最终 answer 后，本地只做输出护栏，再按现有 `final` 事件格式把结果写进 history。

这里我刻意没有把 Dify 的中间 SSE chunk 或整包原始响应写进本地 transcript，只把最终 answer 和必要 metadata 落到 `final`。这样消息历史还是干净的，前端回看不会看到一堆碎片，后面的多轮也不会被这些中间结果污染。

为了后续排查，`final.metadata` 里还是保留了几项外部标识：

```json
{
  "source": "dify_app",
  "delegate": "dify_terminal",
  "dify_conversation_id": "...",
  "dify_message_id": "...",
  "dify_task_id": "..."
}
```

这个 `dify_conversation_id` 只用于审计，不会在下一轮再传回 Dify。真正保证“每次新会话”的不是保存不保存这个字段，而是调用 `chat-messages` 时根本不传 `conversation_id`。

## 代码落点

这次主要改了这几个点：

- 新增 `app/dify_app.py`，封装 Dify App 调用
- 在 `app/agent/runner.py` 前置 Dify 终态委派分支
- 在 `app/agent/orchestrator.py` 注入 `DifyAppClient`
- 增加 `tests/test_dify_app.py`
- 更新 `tests/test_turn_runner_planning.py`

环境变量也补了一组新的：

```env
DIFY_APP_ENABLED=true
DIFY_APP_BASE_URL=https://example.com/v1
DIFY_APP_API_KEY=app-xxxx
DIFY_APP_TIMEOUT_SECONDS=60
DIFY_APP_USER_PREFIX=ats-iot-ai
```

这里的 key 和域名在公开文章里都应该打码，不要直接把内网配置或真实 token 发出去。

## 这次方案解决了什么

直接收益有两个。

第一，本地 history 只保存最终回答，不再保存知识检索的肥大中间结果。后面的多轮上下文会干净很多。

第二，本地 runner 从“自己处理知识问答证据压缩”退回到“做路由和收口”。当前仓库的职责边界更清楚，也少了一条继续膨胀的半成品 RAG 编排链。

## 代价也很明确

这次方案是止血优先，不是假装它没有代价。

最大的代价是，知识问答这一路的中间证据链和生成策略更多地下沉到了 Dify 内部。本地现在能看到的是最终 answer 和一部分 metadata，控制粒度不如自建完整 retrieval workflow 高。

另一个代价是，当前实现还是“启用即全量终态委派”。如果后面要保留双路能力，还得再补一层知识路由，只让知识问答走 Dify，业务查询继续留在本地 runner。

但按这次现场问题看，这个权衡是值得的。原链路的问题已经不是某个小参数不对，而是检索结果进入 Agent 的边界没收住。先把知识问答收敛成外部终态，再慢慢考虑本地是不是还要重建更完整的 RAG 能力，这个节奏更稳。
