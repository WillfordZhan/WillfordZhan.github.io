---
title: "把 LLM-wiki 从设计稿推进到可跑的治理脚手架"
date: 2026-05-13 17:47:41
categories:
  - "AI"
tags:
  - "LLM-wiki"
  - "Agent"
  - "文档治理"
  - "开发回顾"
  - "AI工作日志"
source_archive:
  id: "20260513-llm-wiki-governance-cli-mvp"
  rel_path: "source_materials/posts/20260513-llm-wiki-governance-cli-mvp"
  conversation_file: "conversation.jsonl"
---

上一篇文章先把 LLM-wiki 的文档模型收住了：`topic` 保存长期业务事实，`change` 保存一次变更过程，代码通过 `code.path` 反向索引文档。这次没有继续加概念，而是把它落成一个能跑的 Python CLI，然后拿真实提交试了一次。

试跑结果很直接：基础校验能跑，代码影响分析也能跑，但一笔多加料终端、多吊钩秤的提交没有命中任何正式 wiki 文档。工具只返回了一批 `uncovered_files`，还没有把它提升成“这次提交缺少对应业务文档”的强告警。这个缺口比脚手架本身更重要。

## 从文档模型到 CLI

这版 MVP 只保留两个核心文档类型：

- `topic`：长期存在的业务知识页，描述稳定的业务概念、规则、边界和相关代码入口。
- `change`：一次需求、修复或设计调整的过程记录，交付后应该内化到相关 `topic`，再归档。

文档身份不再单独维护 `doc_id` 字段，而是使用 Obsidian 风格的 vault-relative wikilink：

```yaml
refs:
  related_topics:
    - "[[topics/炉前加料多终端]]"
  archived_changes:
    - "[[changes/多加料终端配置能力]]"
```

目录也故意压得很少：

```text
docs/topics/
docs/changes/
docs/guides/
```

`topic` 和 `change` 都可以声明 `code` 索引：

```yaml
code:
  - path: src/main/java/.../ChargeTerminalService.java
  - path: src/main/java/.../hook_scale/
```

这里没有要求精确到方法。大部分业务代码只需要到路径级别，只有通用类、公共工具类或特别宽泛的文件，才需要补 `symbols`。这个选择是为了降低维护成本：文档索引要能稳定辅助定位，而不是变成另一套脆弱的代码镜像。

基于这个模型，先做了一版 `scripts/wiki.py`。它不是一个内置 LLM 的系统，而是给 agent 用的确定性治理工具：

```text
wiki validate
wiki index
wiki calc-impact
wiki detect-merge
wiki lint
wiki status
wiki new-change
```

`drift-review` 和 `merge-topic` 先保留为显式 LLM harness 的入口，但没有在搜索、校验、索引这些基础命令里调用模型。

这个边界很关键。wiki CLI 的第一职责不是“代替 agent 思考”，而是稳定地产出可解析的结构化信号。真正要不要读哪篇文档、要不要继续 drill down、要不要触发文档更新，应该交给上层 coding agent 决策。

## MVP 先闭合确定性链路

第一版先做了几个低争议能力。

`validate` 检查 frontmatter、`doc_type`、`status`、wikilink、`code.path` 是否符合约定。

`index` 把 `docs/topics/` 和 `docs/changes/` 下的文档解析成结构化索引，后续 search、impact、merge 都基于这个索引走。

`calc-impact` 根据代码变更文件反向匹配文档里的 `code.path`，返回可能受影响的 topics 和 changes。

`detect-merge` 找出 `pending_topic_merge` 状态的 change，并检查它是否声明了 `refs.related_topics`。

`lint` 做一些治理层面的约束，比如 topic 的状态是否合法、change 进入待内化阶段前是否有目标 topic、是否有 code refs。

`new-change` 用于快速创建一份符合 schema 的 change 文档草稿。

这套能力先不追求“聪明”，只追求稳定、可重复、适合挂 hook。因为文档治理最怕的问题不是模型不会写，而是系统没有确定性边界，最后每次都靠人临时想起要补文档。

## 拿真实提交试跑

脚手架跑通后，正好有一笔多加料终端、多吊钩秤相关的代码提交。用 `calc-impact` 对这次提交做检测，核心结果是：

```text
matched_topics: []
matched_changes: []
uncovered_files: 16
```

代表性文件集中在几个区域：

```text
comm_v2/hook_scale/
service2/ChargeTerminalService.java
service2/feature/
service2/furnace_charge/
socket/udp_broadcast/UdpBroadcastPayload.java
```

这个结果不是脚本失败，反而是第一轮治理最有价值的信号：正式 wiki 里还没有覆盖这块业务，也没有一份 change 文档承接这次提交。

换句话说，代码已经前进了，业务文档系统没有跟上。

## 真正暴露的问题

第一版 `calc-impact` 的输出还不够强。

它能列出 `uncovered_files`，但没有把这些文件组织成文档治理动作。对 agent 来说，`uncovered_files: 16` 只是事实；更高质量的输出应该直接告诉它：

```text
documentation_warnings:
  - type: missing_wiki_coverage
    severity: warn
    files: [...]
    suggested_actions:
      - create_change_doc
      - create_or_update_topic_doc
```

这就是这次试跑后得到的第一个明确改进点：当一批代码提交没有命中任何 `change` 或 `topic` 时，wiki 系统必须 warn 创建文档。否则系统只是在“发现漂移”，没有真正“治理漂移”。

这里也能看出 `topic` 和 `change` 的分工。影响分析不应该只看长期 topic，因为新功能在交付前本来就可能还没有内化到 topic。它也不应该只看 change，因为 change 最终会归档。合理的判断是：

- 已有代码区域命中 topic：说明长期知识已有入口。
- 本次改动命中 active change：说明当前变更有过程文档承接。
- 两者都没有命中：说明 wiki 覆盖缺口，需要创建文档。

## 当前边界

这版 MVP 还没有解决所有问题，边界需要明确。

搜索还没有做。后续可以做纯 CLI search，先走 frontmatter、description、tags、code path、全文关键词的打分排序，再考虑 BM25 和向量混合检索。search 本身不需要调用 LLM，它只负责返回候选文档和命中理由。

漂移审查还没有真正自动化。`drift-review` 应该是一个显式、可控、可计费的 LLM harness，而不是每次 diff 都全量扫所有文档。初期更适合从 impacted change 开始，再逐步扩展到指定 topic 或全量 topic。

topic 的人工编辑暂时不纳入治理闭环。人直接补 topic 是现实存在的，但第一版先不为它设计复杂同步机制，避免过早把系统做重。

change 到 topic 的内化也还没自动做。原因很简单：功能是否已经交付，很多时候需要人判断。工具可以发现 `pending_topic_merge`，可以提示 related topics，可以辅助合并，但不应该擅自决定业务已经完成。

## 下一步

下一步不是马上做 RAG，也不是把 LLM 塞进每个命令。

更优先的是把 `calc-impact` 的缺口信号做扎实：当 diff 文件无法映射到任何 wiki 文档时，输出明确的 `documentation_warnings`，同时按目录聚合出建议的 `code.path`，让 agent 能直接创建一份 change 草稿。

然后再为这次多加料终端、多吊钩秤的提交补一份 change 文档，并判断是否需要创建长期 topic。这样 wiki 系统才真正进入闭环：

```text
代码变更
  -> impact 发现受影响文档或覆盖缺口
  -> 缺口触发 change/topic 创建
  -> 交付后 change 内化到 topic
  -> topic 继续作为下一轮代码影响分析的业务索引
```

LLM-wiki 的重点不在“多写一些文档”，而在让文档进入工程系统。它必须能被脚本验证、被 diff 反向索引、被 hook 触发、被 agent 读取和更新。只有这样，业务知识才不会只是某次讨论之后留下的一堆 markdown。
