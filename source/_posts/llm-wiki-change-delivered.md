---
title: "LLM-wiki：把交付事实从 code ref 里拆出来"
date: 2026-05-14 18:44:46
categories:
  - "AI"
tags:
  - "LLM-wiki"
  - "Agent"
  - "文档治理"
  - "开发回顾"
  - "AI工作日志"
source_archive:
  id: "20260514-llm-wiki-change-delivered"
  rel_path: "source_materials/posts/20260514-llm-wiki-change-delivered"
  conversation_file: "conversation.jsonl"
---

前两篇把 LLM-wiki 的文档模型和治理 CLI 跑起来了：`topic` 承接长期业务知识，`change` 承接一次需求或修复过程，`code.path` 让代码变更可以反向找到文档。今天继续往前推了一步，主要解决一个更细的问题：`change.code` 到底是不是交付事实源。

结论是：不是。`change.code` 应该只是索引快照，真正证明一个 change 已经交付的事实源应该是 commit。基于这个判断，新增了 `delivery` 和 `wiki change-delivered`，把“交付事实”和“代码索引”拆开。

## 原来的问题

之前的规则是：`change: pending_topic_merge` 必须声明 `refs.related_topics` 和 `code`。

这在简单场景下够用，但一旦 change 横跨多个 domain，`code` 的粒度就会变得别扭。

如果 `change.code` 直接 ref 整个文件，后续这个文件任何地方变更都会被 `calc-impact` 命中，哪怕这次 change 只轻触碰了其中一个方法。这样会带来噪音。

如果 `change.code` 强行细到 symbol，又会依赖 Agent 判断“这次到底算核心改造还是轻触碰”。模型能力不同，判断就可能不稳定。

更麻烦的是，`change.code` 和 git diff 的职责开始重叠。一个 change 最终由哪些文件改出来，Git 本来就知道；文档再维护一份细粒度列表，容易变成第二份不完全同步的 diff。

所以问题需要重新拆开：

```text
commit
  证明这次 change 最终交付了什么

change.code
  帮 Agent 在开发期、检查期、聚合期快速定位代码

topic.code
  长期 wiki 的稳定代码入口
```

这三个东西不能混成一个字段。

## delivery 成为交付事实源

新的 change frontmatter 增加 `delivery`：

```yaml
delivery:
  target_branch: integration
  commits:
    - abc12345
```

`target_branch` 说明这次 change 交付到了哪条长期基线。单独记录 commit id 还不够，因为一个 commit 在 feature 分支上存在，不等于它已经进入要维护的业务知识基线。

`commits` 记录最终交付提交。第一版先按普通 commit 或 squash commit 处理。merge commit、冲突解决、source commits 这些更复杂的归因先不展开，等真的遇到案例再做。

这样 `pending_topic_merge` 的硬条件变成：

```text
refs.related_topics 必填
delivery.target_branch 必填
delivery.commits 必填
code 可为空
```

`related_topics` 维持原规则不变。没有它，pending 队列无法按 topic 分组，也不知道要把长期知识聚合到哪里。

`code` 则降级为可选。它仍然有价值，但不是交付事实源。

## change-delivered 只做交付门禁

新增命令：

```bash
python3 scripts/wiki.py change-delivered docs/changes/xxx.md \
  --target-branch integration \
  --commits abc12345
```

这个命令默认 dry-run，只输出报告，不写文件：

```text
will_update:
  status: active -> pending_topic_merge
  delivery.target_branch: integration
  delivery.commits: [abc12345]

code_validation:
  existing_code_refs: 2
  unsupported_refs: []
```

确认无误后，加 `--write` 才真正写入：

```bash
python3 scripts/wiki.py change-delivered docs/changes/xxx.md \
  --target-branch integration \
  --commits abc12345 \
  --write
```

它只回答一个问题：

```text
这个 active change 是否已经由这些 commits 交付到目标分支？
```

它不负责把 topic 写好，也不负责生成 code refs。

## 不自动补 code ref

讨论中一度考虑过让 `change-delivered` 根据 commit diff 自动生成 code refs。后来砍掉了。

原因很简单：这个命令是交付门禁，不是 code ref 生成器。它应该越稳定越好。

第一版规则收敛成：

```text
如果已有 code:
  每个 code.path 必须能被 delivery.commits 的 diff 支撑
  不支撑就失败，不自动修

如果 code 为空:
  不失败
  输出 warning，提示 merge-topic 前需要从 commits 生成候选
```

这里故意只校验到 path 粒度。`symbols` 仍然可以保留在文档里，帮助 Agent 缩小阅读上下文，但第一版不做方法级 diff 证明。

这种设计保留了两条线：

```text
delivery.commits
  可审计、可验证、可长期保存

change.code
  可为空、可重算、可被人工调整
```

## drift review 的默认范围

今天也顺带明确了 drift review 的默认口径。

默认不应该全量扫所有 topic，也不应该只扫 change。更合理的是先通过 diff 或 commit 找出 impacted topics，再审查这些 topic 是否漂移。

也就是：

```text
calc-impact / delivery commits
  -> impacted topics
  -> drift-review impacted topics
```

全量 topic drift review 成本太高，第一版不默认做。`change` 的 drift 检查则更多发生在进入 `pending_topic_merge` 前：已有 `change.code` 必须能被 commits 证明，否则说明文档和交付事实之间已经不一致。

## code ref 粒度先别过度设计

围绕 `code.path` 和 `symbols` 也讨论了很久。

一个直觉方案是做打分机制：分数高就 ref 整文件，分数低就 ref symbols。这个方向长期是对的，但第一版不急着落。因为真正的问题不是“分数公式怎么写”，而是 `change.code` 的职责有没有摆正。

现在先定一个更朴素的原则：

```text
active change:
  code 可作为开发期索引，允许不完美

pending_topic_merge:
  commit 是事实源
  code 如果存在，必须被 commit diff 支撑

topic merge:
  基于 delivery.commits、change.code、topic.code 重新生成候选
```

后续如果要做精细的 ref 粒度打分，应该放到 topic 聚合前，而不是让 `change-delivered` 提前承担这件事。

## 这次落地的边界

这次实现主要包含几件事：

- `scripts/wiki.py` 支持 `delivery` 字段校验。
- `pending_topic_merge` 不再强制要求 `code`。
- 新增 `wiki change-delivered`，默认 dry-run，`--write` 才改文档。
- 已有 `change.code` 会被 commits diff 校验，不匹配则阻止状态切换。
- `raise-a-change` skill 仍然只登记 active change，不手动改 pending 状态。

这个版本没有做：

- 自动生成 code refs。
- symbol 级 diff 证明。
- merge commit 的复杂归因。
- generated/manual code provenance。
- topic 聚合时的 ref 粒度打分。

这些都可以后续加，但不应该挡住第一版闭环。

## 结果

现在 LLM-wiki 的 change 生命周期更清楚了：

```text
raise-a-change
  创建 active change

change-delivered
  写入 delivery
  active -> pending_topic_merge

merge-topic
  把长期内容聚合到 topic
  change -> archived
```

关键变化是：文档不再假装自己是 Git。Git 提供交付事实，wiki 维护业务语义和可检索索引，Agent 在二者之间做语义聚合。

这比继续加字段更重要。字段可以慢慢补，但事实源的边界一旦混了，后面的 drift 检查和 topic 聚合都会变得不稳。
