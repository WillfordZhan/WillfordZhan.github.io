---
name: hexo-blog-publish
description: Publish WillfordZhan's Hexo blog. Use when writing a new post in `source/_posts/*.md`, building locally, committing to `hexo-src`, and pushing so GitHub Actions deploys the generated site to `master` (GitHub Pages).
---

# Hexo Blog Publish (WillfordZhan)

This skill automates the workflow for the blog repo at `~/Desktop/Project/blog`:

- Source branch: `hexo-src` (Hexo source)
- Publish branch: `master` (generated static site for GitHub Pages)

## Quick Start

- Create a new post: run `bin/new_post.py`.
- Create an AI worklog post for AI tab: run `bin/new_post.py --ai-log ...`.
- Publish: run `bin/publish.sh`.

## Workflow

### 0) Execution mode (mandatory)

Use **Thread-first authoring mode** by default:

- The main agent (current thread) must draft/review/finalize the blog content first.
- A subagent may be used **only for publish execution** (build/commit/push), not for content drafting.
- Do not delegate the writing itself to a subagent unless the user explicitly asks for delegated writing.

Recommended split:

1. Main thread: produce final markdown and confirm target post file.
2. Main thread: print the finalized markdown into the conversation for user preview and wait for explicit publish confirmation.
3. Subagent: run publish workflow (`npm run build`, `bin/publish.sh`) with the finalized file only after confirmation.

This avoids information drift and keeps technical accuracy anchored in the current thread context.

### 1) Create / edit a post

Posts live at `source/_posts/*.md`.

增加希望文风是诙谐的，并结合期望发布的主题根据当前 conversation 对话记录内容详细提取相关信息并整理，以面向开发工程师进阶的角度写一篇详实诙谐但是不啰嗦的(踩坑 / 记录 / 复盘/ 教程等)文档。

Writing standard for technical posts:

- Default to an advanced-but-practical engineering audience when the topic is debugging, architecture, databases, middleware, or production incidents.
- Prefer detailed, traceable explanations over short summaries when the topic contains strong technical lessons.
- Explain the causal chain, not just the final conclusion: symptom -> evidence -> mechanism -> fix -> prevention.
- Include representative code snippets, SQL snippets, config fragments, or processlist/log examples when they materially improve understanding.
- Keep the tone calm and factual. Avoid sensational framing, hindsight ridicule, or exaggerated certainty.
- Keep it detailed without padding. Cut repeated summaries, repeated contrasts, and transitional filler.
- Avoid formulaic AI-sounding phrasing such as:
  - `不是……而是……` used repeatedly
  - `真正重要的不是……`
  - `背后其实包含了一整套……`
  - `这也是为什么……` used as a default transition
  - `很有价值 / 值得` repeated without adding new information
- Prefer direct wording. State the mechanism plainly instead of wrapping each point in rhetorical setup.
- When discussing an incident, separate:
  - observed facts
  - reasoned inferences
  - confirmed root cause
  - residual uncertainty
- Prefer “why this happens” and “why this fix works” sections, because these are usually what make the post valuable to experienced engineers.
- If the discussion produced valuable follow-up Q&A, fold those follow-ups into the post as an explicit section such as `延伸问答` or `常见追问`, instead of leaving the key insights only in chat history.

中文技术长文写作约束（生成博客正文时强制参考）：

- 写法要像一线工程师在复盘自己的实现、联调、踩坑和改法，不要写成培训材料、标准技术分享、讲师讲义、会议纪要，也不要写成“模型很会解释技术”的那种顺滑文章。
- 文章重点放在真实工程问题上，不要停在抽象概念演绎。优先写清楚：
  - 具体问题是什么
  - 为什么到真实系统里会变麻烦
  - 哪个最初方案看起来能做、后来却不顺
  - 为什么改写法
  - 改完解决了什么
  - 改完又带来了什么代价和维护负担
- 多写具体对象和具体动作，少写抽象空词。优先写：
  - 谁负责决定调用
  - 参数谁来校验
  - 失败谁来处理
  - 重试放在哪层
  - 状态放在哪里
  - 调用链怎么串
  - 日志怎么打
  - trace / conversationId / toolCallId 怎么补
  - 线上问题怎么还原
  - 哪个设计让排查变慢
  - 哪个约束让实现变轻
- 默认读者是有基础的工程师，不要过度科普，不要居高临下，也不要用“纠正常见误区”的教师口吻推进全文。
- 语言要直接、自然、克制、可信。允许有判断，但判断必须落在具体场景、具体代码、具体实现、具体代价上。
- 不要强行写成提纲式技术文，不要用“这篇文章将…… / 本文主要分为以下几个部分…… / 我来把本质讲清楚……”这类开头。
- 不要用公文化、汇报化、标准答案化表达。不要为了显得成熟而频繁总结，也不要为了显得完整而把每段都写成一次归纳。
- 不要机械使用这些连接词组织全文：
  - `首先 / 其次 / 再次 / 最后`
  - `此外 / 同时 / 另一方面`
  - `因此 / 所以 / 总之 / 综上所述`
- 不要为了流畅而频繁使用这些句头或判断句：
  - `原因很简单`
  - `好处很现实`
  - `直接好处是`
  - `结构上大概是`
  - `一开始看起来`
  - `最后发现`
  - `看起来……，实际上……`
- 对以下固定写法做高频自检，尽量不用，尤其不要在一篇文章里重复出现：
  - `不是……而是……`
  - `真正难的地方不是……`
  - `最容易……的不是……`
  - `最需要稳定的不是……`
  - `重点不是……而是……`
  - `真正的问题不是……而是……`
- 对以下“讲师标重点”式表达做高频自检，尽量不用：
  - `这一步很关键`
  - `这点很重要`
  - `这件事非常重要`
  - `这一层的重点是……`
- 对以下“技术博客 AI 模板句头”做高频自检，尽量不用：
  - `很多团队第一次做……`
  - `很多人会误以为……`
  - `文章会覆盖三件事……`
  - `这篇文章记录的就是……`
  - `官方提供的是三类能力……`
- 如果一定要表达技术判断，优先改写成更像工程复盘的说法：
  - 把 `这一步很关键` 改成 `这里要是不单独处理，后面会乱掉。`
  - 把 `原因很简单` 改成 `我当时踩到的是这两个地方。`
  - 把 `不是 A，而是 B` 改成 `A 当然有影响，但真把链路搞乱的是 B。`
  - 把 `最稳的方案是` 改成 `按这次联调下来的结果，这么拆更省事。`
  - 把 `文章会覆盖三件事` 改成 `这次只想把两个地方讲透。`
- 少用、慎用以下抽象词；如果用了，后面必须立刻接具体对象、具体动作、具体故障点，不能空转：
  - `收口`
  - `分层`
  - `边界`
  - `契约`
  - `语义`
  - `运行时`
  - `机制`
  - `取舍`
  - `稳定`
  - `观察驱动 / observation`
- 不要靠 `价值 / 意义 / 维度 / 路径 / 体系 / 生态 / 赋能 / 能力建设` 这类空泛词撑文章。
- 文章推进顺序要自然，优先按“问题出现 -> 原方案不顺 -> 修改后的实现 -> 代价和边界 -> 联调与维护影响”往前走，不要每段都先抽象总结再展开。
- 如果有多种方案，不要默认写成标准答案对比表。要写清楚：
  - 各自省事在哪
  - 各自麻烦在哪
  - 各自把复杂度转移到了哪里
  - 什么场景值得上更重的方案
  - 什么场景简单方案反而更合适
- 要把真实工程里的卡点写出来，比如：
  - 联调时哪一步最容易乱
  - 排查时哪类日志最容易误导
  - 哪种 demo 写法到了线上会拖慢事情
  - 哪个设计在维护时最容易留下尾巴
- 每一节都要有信息增量，不要只是换句话重复上文。
- 结尾自然收住，停在一个具体工程判断、一个适用场景，或者一个很窄的建议上。不要升华，不要展望，不要做宏大总结。
- 生成博客正文时，直接输出完整正文，不要额外输出提纲、摘要、导读、写作说明或元评论。

生成后自检清单（输出正文前必须逐项过一遍）：

- 读开头三段，确认不是培训材料式开场。删掉：
  - `这篇文章将……`
  - `本文主要分为……`
  - `文章会覆盖三件事……`
  - `我来把本质讲清楚……`
- 全文检索固定对照句式，确认 `不是……而是……` 没有高频出现；如果出现 2 次以上，至少改掉一半。
- 全文检索“讲师式重点提示”，删改这些句子：
  - `这一步很关键`
  - `这点很重要`
  - `这件事非常重要`
  - `这一层的重点是……`
- 全文检索“过于顺滑的过渡句头”，尽量删改：
  - `原因很简单`
  - `好处很现实`
  - `直接好处是`
  - `结构上大概是`
  - `一开始看起来`
  - `最后发现`
- 全文检索“AI 技术博文模板句头”，尽量删改：
  - `很多团队第一次做……`
  - `很多人会误以为……`
  - `看起来……，实际上……`
  - `官方提供的是三类能力……`
- 抽查每一节开头，确认没有反复使用“先立抽象判断，再列三四条”的同一模板。如果连续两节都这么写，至少改一节。
- 抽查每个小节结尾，确认没有都在做标准答案式收束。删掉那种“一句话盖棺定论”的结尾，换成具体工程判断、限制条件，或者直接收住。
- 全文检索抽象词高频堆叠。如果 `收口 / 分层 / 边界 / 契约 / 语义 / 运行时 / 稳定 / 取舍 / 机制` 在短距离内反复出现，至少改掉一部分，换成具体对象和具体动作。
- 抽查三到五段，确认段落里写的是具体东西，而不是抽象结论。每段至少回答下面问题里的一个：
  - 谁决定调用
  - 参数在哪校验
  - 状态放在哪
  - 日志怎么打
  - trace 怎么串
  - 哪一步联调最容易乱
  - 哪个设计让排查变慢
- 检查全文有没有“把问题讲得很完整，但没有写清楚为什么原方案不顺”的情况；如果有，补上失败点、返工点、误判点。
- 检查全文有没有“只写改法，不写代价”的情况；如果有，补上：
  - 改完增加了什么复杂度
  - 哪些场景不适用
  - 哪些维护动作会变烦
- 检查结尾，确认没有升华、展望、上价值。结尾最好停在一个具体建议、一个适用边界，或者一个明确的工程判断上。
- 最后通读一遍，判断作者声音是否太稳定、太工整、太会总结；如果像“成熟技术博客模板”，就把最顺的几句改钝一点，改成更像现场复盘的写法。

Preferred: use the script (creates frontmatter + safe filename):

- `python3 bin/new_post.py --title "..." --tags "工具技巧,远程办公"`
- AI worklog post (auto publish to AI tab):
  - `python3 bin/new_post.py --title "..." --ai-log --tags "MCP,复盘"`
  - This auto adds:
    - `categories: ["AI"]` (for `/categories/AI/`)
    - `tags: ["AI工作日志", ...]`

### 1.5) Sanitize before publish

Before building or pushing, scrub public-facing content for sensitive data. This is mandatory for posts derived from work logs, terminal output, config files, or internal code.

- Replace internal domains, IPs, ports, webhook URLs, usernames, namespace names, tenant identifiers, and local absolute paths with placeholders such as `example.com`, `127.0.0.1`, `/path/to/project`, or generic labels.
- Do not publish secrets or secret-like values: tokens, API keys, passwords, signing secrets, private repo URLs, SSH config details, or anything copied from `.env`, Nacos, CI, or production config.
- Prefer minimal illustrative snippets over large raw diffs. Keep only the logic needed to explain the solution.
- If a command output contains internal project names, branch names, hostnames, or customer-specific data, rewrite it as a summarized example instead of pasting the raw output.
- When the repo already has unrelated modified files, do not blindly run a publish flow that stages everything. Commit only the files relevant to the current post unless the user explicitly asks to publish all pending blog changes.

### 1.6) Archive source conversation before publish

Before any build, commit, or push, archive the source conversation log into a **private source-material directory inside the blog repo** so the post can be regenerated later from the original chat record.

Rules:

- Store source materials outside Hexo public content paths. Use a private directory such as:
  - `source_materials/posts/<archive_id>/`
- Do **not** convert the conversation log to markdown by default.
- Copy the original conversation log file as-is, using:
  - `conversation.jsonl`
- Do **not** publish or embed the raw conversation log in the article body.
- Use a stable `archive_id` for the folder name. Do not use the article title itself as the folder name because titles/slugs may change later.
- The archive must support two-way lookup:
  - article frontmatter -> source archive directory
  - source archive metadata -> article file

Minimum archive contents:

- `conversation.jsonl`
- `meta.json`

Recommended minimal `meta.json` shape:

```json
{
  "archive_id": "20260312-mcp-function-calling",
  "post_name": "聊聊 MCP、Function Calling 和你这套 AI 工具链到底像谁",
  "post_rel_path": "source/_posts/mcp-function-calling.md",
  "conversation_file": "conversation.jsonl",
  "archived_at": "2026-03-12T22:10:00+08:00"
}
```

Recommended frontmatter linkage in the post:

```yaml
source_archive:
  id: 20260312-mcp-function-calling
  rel_path: source_materials/posts/20260312-mcp-function-calling
  conversation_file: conversation.jsonl
```

Execution order:

1. Finalize the target post file path and title.
2. Generate a stable `archive_id` from date + slug-like identifier.
3. Create `source_materials/posts/<archive_id>/`.
4. Copy the original conversation log file into that directory as `conversation.jsonl`.
5. Write `meta.json` with `post_name`, `post_rel_path`, and `archived_at`.
6. Update the post frontmatter with `source_archive`.
7. Only after archive + linkage are ready, continue to preview/build/publish.

Source conversation file resolution:

- Prefer a conversation log file path explicitly provided by the user.
- If the current workflow/tooling already exposes a concrete local conversation export file, use that exact file.
- Do not reconstruct a fake transcript from memory when the original `jsonl` file is unavailable.
- If no original conversation log file can be located, stop and ask the user for the source file path before publishing.
- Do not load large candidate conversation files into the LLM just to inspect them. Prefer file-content search tools first, using keywords, distinctive phrases, or highly related text fragments from the current discussion to narrow candidates.
- Choose the search root based on the current chat runtime instead of mixing every client/app history together:
  - If the current conversation is a Codex session, search Codex history/index/session files first, such as `~/.codex/history.jsonl`, `~/.codex/session_index.jsonl`, and `~/.codex/sessions/**`.
  - If the current conversation is a Claude session, search Claude project/session exports first, such as `~/.claude/projects/**` or other Claude-managed local transcript stores.
  - If another app/runtime is in use, prefer that app's native local conversation storage before falling back to generic filesystem search.
- Recommended locating flow:
  1. Extract 3-6 distinctive keywords / phrases / question fragments from the current conversation topic.
  2. Search the active client's history/index files for those fragments to identify likely session ids or export references.
  3. Search the active client's raw session directory for the matched session id or the same distinctive fragments.
  4. Verify the candidate file with a small local preview (`head`, `rg -n`, etc.) rather than loading the full transcript into the model.
  5. Use the original raw session `.jsonl` as the archive source.
- When multiple candidate files exist, prefer the one that:
  - is explicitly tied to the current post/topic
  - is the most recently updated relevant conversation export
  - is in the native raw conversation format (`.jsonl`) rather than a transformed derivative
- Record the original source file path in `meta.json` when it is available locally. Example:

```json
{
  "source_file": "/abs/path/to/original/conversation.jsonl"
}
```

### 1.8) Preview gate before publish

Before any build, commit, or push:

- Print the finalized article markdown into the conversation for user preview.
- Call out the exact target post file path that will be published.
- Call out the exact source archive directory that was created for this post.
- Wait for explicit user confirmation such as `发布`, `继续发布`, or equivalent approval.
- If the user requests edits after preview, update the file first and preview again when the changes materially affect the article content.
- Do not start `npm run build`, `bin/publish.sh`, `git commit`, or `git push` until confirmation is received.

### 2) Local build (optional but recommended)

- `npm ci`
- `npm run build`

### 3) Publish (commit + push to `hexo-src`)

- `bash bin/publish.sh -m "post: ..."`

This script:

- Checks repo path, remote, and branch
- Runs `npm ci` + `npm run build`
- Commits changes to `hexo-src`
- Pushes to `origin/hexo-src`

GitHub Actions should then deploy to `master` automatically.

### 3.5) Subagent publish handoff (recommended)

When using a subagent for publishing, pass these constraints explicitly:

- Input is the finalized post file from the main thread.
- User preview has completed and explicit publish confirmation has already been obtained.
- Subagent must not rewrite article semantics or structure.
- If sanitization is needed, subagent can only do redaction-safe edits and must report each change.
- Commit scope should be limited to related post changes unless user requested broader publish.

Suggested handoff template:

```text
Publish only. Do not rewrite article content.
Use finalized file: source/_posts/<post>.md
Ensure source conversation archive already exists under source_materials/posts/<archive_id>/ and remains linked in post frontmatter.
Run build + publish, report git status, commit hash, and push result.
```

## Troubleshooting

- **Pushed but site didn’t change**:
  - Confirm you pushed to `hexo-src` (not `master`).
  - Check GitHub → repo → Actions: workflow `Build and Deploy Hexo` should be green.
  - Check GitHub → repo → Settings → Pages: source branch should be `master` and folder `/ (root)`.

- **GitHub SSH auth fails** (`Permission denied (publickey)`):
  - Ensure `~/.ssh/config` has a `Host github.com` block with your GitHub key.
  - Run: `ssh -T git@github.com`.

## Notes

- Do not hand-edit `master` for new posts; treat `master` as build output.
- If you need to change theme/config, do it on `hexo-src`.
- AI tab convention:
  - Navbar tab should link to `/categories/AI/` (configured in `_config.fluid.yml`).
  - All AI worklog summary posts should include `categories: ["AI"]`.
  - Recommended tag baseline: include `"AI工作日志"` for filtering.
