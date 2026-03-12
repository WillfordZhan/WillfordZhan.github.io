---
title: "把知识库检索参数交给 LLM，是一条错误的分层"
date: 2026-03-12 17:51:16
categories:
  - "AI"
tags:
  - "AI"
  - "知识库"
  - "RAG"
  - "复盘"
  - "AI工作日志"
source_archive:
  id: 20260312-llm-retrieval-params
  rel_path: source_materials/posts/20260312-llm-retrieval-params
  conversation_file: conversation.jsonl
---

线上知识库查询突然开始报参数错误，日志里看着像是 `knowledge.search` 接口坏了。再往前翻一层，会看到编排器已经把这轮调用打回了 `CLARIFY`，理由是 `invalid_arg:score_threshold`。用户只是想查知识库，结果系统先追问了一个相似度阈值。

这类问题最烦的地方不在于报错本身，而在于它表面上像工具执行失败，实际上是工具暴露面设计错了。知识库查询真正需要用户表达的只有“查什么”。`score_threshold`、`top_k`、`search_method`、`reranking_enable` 这些值，属于检索策略，不属于用户意图。把它们也当成模型要规划的参数，等于让 LLM 顺手接管了一部分 RAG 调参。
真正出问题的地方不在 Java 检索接口，而在工具定义。

当时 `knowledge.search` 对模型暴露的参数是这一组：

```java
public ToolResult knowledge_search(
    String query,
    String datasetId,
    Integer topK,
    String searchMethod,
    Double scoreThreshold,
    Boolean rerankingEnable,
    AiRunContext ctx
)
```

看着没什么问题，实际上这里把两类东西混在一起了。

`query` 是用户问题。`dataset_id` 也还能算业务参数。后面那几个不是。`top_k`、`search_method`、`score_threshold`、`reranking_enable` 都是检索侧自己该决定的值。

更尴尬的是，方法内部本来就已经给了默认值：

- `top_k=5`
- `search_method=semantic_search`
- `score_threshold=0.3`
- `reranking_enable=false`

也就是说，后端其实已经知道该怎么查了，只是又把这些值公开给了模型。

前面我们为了修另一个问题，把 planner 输入里的工具定义从裁剪版改成了完整 schema。这个改动本身没错，字段名终于对齐了，模型不太会再乱猜。但副作用也很直接：它开始顺手补更多参数。

知识库查询本来只传 `query` 就够了。模型一旦多填一个 `score_threshold`，而且这个值不符合 schema，这轮调用就会在 Python 的参数校验阶段被拦下来。用户看到的现象就变成了：查知识库失败，系统反过来问他阈值该填多少。

这时候再往 Python 侧补容错，其实已经有点晚了。可以做，但那是在给一个不该暴露出来的参数擦屁股。今天是 `score_threshold`，后面就会轮到 `top_k` 和 `search_method`。

最后的改法很简单，直接把这几个检索参数从工具签名里拿掉，只给模型保留 `query` 和 `dataset_id`。检索策略继续留在后端。

然后把默认值收进配置：

- `ai.kb.dify.retrievalTopK`
- `ai.kb.dify.searchMethod`
- `ai.kb.dify.scoreThreshold`
- `ai.kb.dify.rerankingEnable`

这样改完以后，线上行为稳定了不少。相同查询不会因为模型这次多说了一句，就把整轮调用打回澄清。调检索效果时也不用再碰工具契约，改配置就行。

这次问题不算复杂，真正麻烦的是它很像“模型又犯错了”。顺着这个方向走，很容易继续在 planner、校验器、澄清文案上补补丁。回头看，这次该收的不是模型输出，而是工具参数本身。

知识库工具最后留给模型的，应该尽量只剩“查什么”。像 `score_threshold` 这种值，还是老老实实放在后台更省事。
