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

默认文风：

- 诙谐，但不过火。
- 面向开发工程师进阶读者。
- 详实，但不啰嗦。

写作基调：

- 优先写具体对象、具体动作、具体故障点。
- 先把问题、证据、改法、代价讲清楚，再谈判断。
- 判断可以有，但不要摆教师姿态，不要借句型给自己垫权威。
- 让文章像现场复盘，不要像标准答案。
- 语言直接、克制、可信，允许一点幽默，但不要用训话感、拐杖句、盖棺定论句推进全文。

博客场景专属要求：

- 结合当前 conversation 对话记录提取信息，不要脱离真实讨论去凭空扩写。
- 当主题是调试、架构、数据库、中间件、线上问题时，优先写“问题怎么出现、证据是什么、原方案哪里不顺、改法怎么落地、代价在哪”。
- 正文里保留必要的代码、配置、日志片段，但以说明问题为限，不堆大段原始输出。
- 如果讨论里有有价值的追问，整理成 `延伸问答` 或类似小节，不要把关键结论留在对话里。
- 输出博客正文时，直接给完整正文，不要额外输出提纲、摘要、导读、写作说明或元评论。

避免这些表达套路：

- 先反后正：
  - `表面上是……，实际是……`
  - `不是……，而是……`
  - `重点不是……，而是……`
  - `真正的问题不是……，而是……`
  - `问题聊到最后，核心就是……`
  - `说到底就是……`
  - `归根结底……`
  - `本质上还是……`
- 教人做事 / 训话感：
  - `如果……，那就……`
  - `如果……，那么……`
  - `只要你坚持……`
  - `所以你要是……，那么就能……`
  - `别……，先……`
  - `老老实实……再谈……`
  - `那就别自我感动……`
- 结论拐杖：
  - `真正的……，往往在……`
  - `只……，最后还是……`
  - `关键其实就在……`
  - `无非就是……`
  - `原因很简单`
  - `好处很现实`
  - `直接好处是`
  - `结构上大概是`
- 模板化技术博文句头：
  - `很多团队第一次做……`
  - `很多人会误以为……`
  - `官方提供的是三类能力……`
  - `这篇文章会覆盖三件事……`
  - `我来把本质讲清楚……`

生成正文时，把下面这些当成硬黑名单优先处理：

- `表面上是……，实际是……`
- `不是……，而是……`
- `重点不是……，而是……`
- `真正的问题不是……，而是……`
- `如果……，那就……`
- `如果……，那么……`
- `只要你坚持……`
- `所以你要是……，那么就能……`
- `别……，先……`
- `那就别自我感动……`
- `老老实实……再谈……`
- `真正的……，往往在……`
- `只……，最后还是……`
- `说到底就是……`
- `归根结底……`
- `本质上还是……`
- `关键其实就在……`
- `无非就是……`
- `这段代码很土，但土得很有安全感`

推荐改写方式：

- `这一步很关键`
  改成：`这里不单独处理，后面几层日志会串在一起。`
- `原因很简单`
  改成：`我当时主要卡在这两个地方。`
- `最稳的方案是`
  改成：`按这次联调结果，我更倾向这么拆。`
- `文章会覆盖三件事`
  改成：`这次主要把两个地方写透。`
- `真正的问题不是 A，而是 B`
  改成：`A 有影响，链路被拖乱的是 B。`
- `如果你这么做，那么就能……`
  改成：`这里改成这样以后，日志会落到同一个文件里。`

生成后自检：

- 检索黑名单句型，删掉或改写。
- 看前 3 段，确认不是培训材料式开场。
- 抽查 3 段，确认每段都在写具体对象和动作。
- 检查是否写清了“原方案为什么不顺”。
- 检查是否写清了“改完的代价和维护负担”。
- 看结尾，确认没有上价值、升华、训话、发结论口号。
- 再额外检查一次是否保留了足够的工程细节，避免只剩风格正确、信息不够。

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
