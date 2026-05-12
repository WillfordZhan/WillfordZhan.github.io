---
title: "给 Agent 读的 LLM-wiki：业务文档自管理系统设计"
date: 2026-05-12 18:40:48
categories:
  - "AI"
tags:
  - "LLM-wiki"
  - "Agent"
  - "文档治理"
  - "RAG"
  - "架构设计"
  - "AI工作日志"
source_archive:
  id: "20260512-llm-wiki-agent-doc-governance"
  rel_path: "source_materials/posts/20260512-llm-wiki-agent-doc-governance"
  conversation_file: "conversation.jsonl"
---

最近在设计一个给 coding agent 使用的业务文档自管理系统。问题不是“要不要写文档”，而是：代码已经是运行行为的第一事实源，文档如果只是人工补充说明，很快会漂移；但如果完全不写文档，很多业务前提、取舍和禁区又不会自然出现在代码里。

这套系统最后收敛成一个比较小的模型：代码负责表达当前怎么跑；wiki 负责表达代码之外的业务语义和设计取舍；脚本负责稳定发现影响范围；agent 只处理语义判断和文档聚合，不把所有事情都交给模型猜。

## 为什么不是普通文档库

普通文档库的问题是没有生命周期。

一篇设计文档写完之后，代码可能经历多次提交、返工、合并和交付。交付之后，设计文档里长期有效的内容应该进入稳定的业务主题页；临时的任务清单、调研过程、开发蓝图则不应该继续污染长期知识库。

所以这个系统一开始就区分两个事实源：

```text
code
  当前运行行为事实源

llm-wiki
  代码之外的业务语义、边界、取舍和稳定入口
```

文档漂移也不定义成“文字和代码不一致”。更准确的定义是：文档里的业务判断已经无法被当前代码事实支撑，或者代码新增了业务能力但没有被长期 wiki 承接。

## 最小文档类型

讨论中一开始出现过很多类型：business、design、decision、research、development、runbook。后来全部收掉，只保留两个正式类型：

```yaml
doc_type: topic | change
```

`topic` 是长期主题页，保存当前有效的业务语义、领域边界、稳定规则和代码入口。

`change` 是阶段性变更档案，保存某次 feature、fix、upgrade 或设计调整的背景、方案、取舍和影响范围。它交付后不再作为当前事实源，而是被聚合到相关 topic，自己变成历史档案。

没有单独保留 `decision`，因为大多数决策放在 change 的 `## Decisions` 就够了。只有难回退、未来读者会困惑、确实存在取舍的决策，才需要提升成 ADR。

没有保留 `research` 和 `development`。代码链路调研是 agent 从代码事实生成的临时证据；如果调研发现在业务语义上缺文档，就直接创建或更新 topic。开发 TODO、落地蓝图、临时任务状态也不进正式 wiki，它们的最终产物应该是代码、测试和被聚合后的 topic。

## 状态机

`topic` 和 `change` 的生命周期不同，不能用一套 status 硬套。

```yaml
# doc_type: topic
status: active | superseded | retired

# doc_type: change
status: active | pending_topic_merge | archived
```

`change: active` 表示还在设计、开发、返工或验证中。同一个 change 可以覆盖多次 commit，不需要每次提交都创建一篇文档。

`change: pending_topic_merge` 表示人已经确认功能交付，并且对应代码进入目标集成分支。这个判断不应该由 agent 自己做，因为“是否交付”是项目状态，不是代码文本能完全推出的结论。

`change: archived` 表示长期内容已经聚合到 topic，这篇 change 只作为历史档案保留。

并行开发时有一个关键约束：多个 change 同时影响同一个 topic 时，不能各自随意改 topic。聚合任务必须按 topic 分组串行执行，每次写入前都重新读取当前 topic、相关 change 和目标集成分支上的代码事实。

## 路径就是身份

一开始考虑过 `doc_id`，比如 `业务主题.business` 或 `业务主题-设计`。后面放弃了。

原因是 `doc_id` 和文件路径会变成两套身份系统。人改文件名、移动目录、调整引用时，很容易漏改其中一套。既然目标是人机共读，而且希望兼容 Obsidian 双链，就让路径直接成为身份。

最终规则是：

```text
docs/ 是 Obsidian vault root
文档身份 = docs/ 下的 vault-relative refPath
refs 使用 Obsidian wikilink
```

目录保持简单：

```text
docs/
  topics/      # 长期主题页
  changes/     # 变更档案
  guides/      # 给人读的导航页
```

引用长这样：

```yaml
refs:
  related_topics:
    - "[[topics/业务主题]]"
  archived_changes:
    - "[[changes/业务主题-某次改造]]"
```

`guides/` 只服务人类阅读路径，比如按业务层级组织“子设备”“报表”“成本”等入口。它不承担事实源职责，也不应该决定 topic 的身份。

## 元数据边界

topic 示例：

```yaml
---
doc_type: topic
status: active
description: 某个长期业务主题的语义、边界、规则和稳定代码入口。
tags: [业务标签, 配置, 设备]
refs:
  related_topics: []
  archived_changes:
    - "[[changes/业务主题-某次改造]]"
code:
  - path: src/domain/example/
  - path: src/config/BusinessConfig.java
    symbols: [IMPORTANT_CONFIG_KEY]
---
```

change 示例：

```yaml
---
doc_type: change
status: pending_topic_merge
description: 某次变更的背景、方案、取舍和交付验证。
refs:
  related_topics:
    - "[[topics/业务主题]]"
code:
  - path: src/domain/example/
---
```

`refs.related_topics` 只在 `pending_topic_merge` 阶段成为强约束，表示这篇 change 必须聚合到哪些 topic。`refs.archived_changes` 是 topic 上的历史档案入口。

`code` 是反向索引的基础。代码变更后，脚本可以通过 `code.path` 找到可能受影响的 topic 或 change，再把候选交给 agent 判断是否漂移。

这里刻意不区分 `owned_code` 和 `referenced_code`。这类归属很容易变成主观维护负担。第一版只保留一个中性字段 `code`。

`symbols` 也不默认强制。领域相关代码通常写到 path 就够了；只有通用类、配置类或特别宽的文件，才用 symbols 缩小阅读范围。

## 聚合不是摘要

change 聚合到 topic，不是把 change 摘要复制过去。

聚合时 agent 至少要同时看三类输入：

```text
change.code
topic.code
target branch diff
```

`change.code` 是本次变更的证据范围，可以比 topic 更宽。`topic.code` 只保留长期稳定入口。聚合的目标是把长期有效的业务语义、边界、关键取舍和稳定代码入口吸收到 topic，临时开发细节不应该留下。

这也是为什么不能让 hook 直接唤起模型自动改文档。hook 更适合做确定性事情：扫描 frontmatter、解析 Obsidian refs、校验 status、根据 changed files 生成影响清单。真正的语义判断和聚合可以交给 agent，但入口要由脚本约束。

第一版 harness 可以很小：

```bash
scripts/wiki check
scripts/wiki index
scripts/wiki impact --changed-file-list <file>
scripts/wiki pending-topic-merge
scripts/wiki validate-ref "[[topics/业务主题]]"
```

hook / cron / agent workflow 都只调用这个统一 CLI，不把逻辑散在各个 hook 里。

## 这套 wiki 到底解决什么

它的价值不是“让人少读代码”。强一点的 coding agent 本来就能搜代码、读调用链、跑测试。

真正重要的是三件事。

第一，保存代码外事实。代码能说明当前系统怎么跑，但很难说明为什么业务上必须这样、哪些词不能混用、哪些方案被否过、哪些边界是人确认过的。

第二，给 agent 一个语义控制面。topic、change、refs、code refs、status 这些结构让 hook、RAG、diff 分析和文档聚合有稳定入口，而不是每次靠全库搜索和 prompt 临时发挥。

第三，降低错误检索和上下文噪声。省 token 是收益之一，但不是第一目标。更关键的是让 agent 先读对材料，知道哪些文档是当前事实源，哪些只是历史档案。

人类阅读仍然重要，但不应该主导身份设计。人类阅读路径交给 `guides/`；机器身份交给 Obsidian refPath；生命周期交给 `doc_type` 和 `status`；语义判断交给 agent；确定性约束交给脚本。

这个边界清楚之后，llm-wiki 就不再是“多写一些文档”，而是一套围绕代码事实、业务语义和变更归档的轻量治理系统。
