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
- Publish: first inspect tracked + untracked changes, then choose `bin/publish.sh` or a minimal manual `git add/commit/push`.

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

- 简洁、直接、克制。
- 面向开发工程师，不写成培训材料，也不写成情绪化散文。
- 详实，但优先保证可读性和可执行性。

写作总原则：

- 先把问题、场景、动作、结果讲清楚，再谈判断。
- 优先写具体对象、具体故障点、具体改法，不靠抽象概念和大词撑篇幅。
- 默认不主动追求幽默，不刻意抖机灵，不为了“像人写的”去制造腔调。
- 少类比，少铺垫，少“我来讲清楚本质”式开场。
- 正文直接输出完整成稿，不要额外输出提纲、摘要、导读、写作说明或元评论。

博客场景专属要求：

- 结合当前 conversation 对话记录提取信息，不要脱离真实讨论去凭空扩写。
- 当主题是调试、架构、数据库、中间件、线上问题时，优先写“问题怎么出现、证据是什么、原方案哪里不顺、改法怎么落地、代价在哪”。
- 正文里保留必要的代码、配置、日志片段，但以说明问题为限，不堆大段原始输出。
- 有价值的追问可以整理进正文，但不要机械追加 `延伸问答`；只有确实能帮读者继续判断时才保留。

### 1.1) 根据会话自动判断文章类型

生成正文前，必须先根据当前 conversation 判断这篇文章更接近哪一种类型，再按该类型组织结构和语气。

默认类型：

- `踩坑复盘`
- `开发回顾`
- `架构/技术介绍`

允许识别新类型：

- 如果会话明显不属于上面三类，可以提出一个新的候选类型。
- 只有在和用户确认后，才把新的候选类型当成正式类型长期使用。

类型判断规则：

- `踩坑复盘`
  典型特征：有明确故障、异常、错误现象、排查过程、修复动作、结果验证。
- `开发回顾`
  典型特征：围绕某次实现、重构、联调、交付、迭代，重点是取舍、推进过程和结果。
- `架构/技术介绍`
  典型特征：重点在解释一个方案、协议、组件边界、设计选择、适用场景，不以故障排查为主。

当类型不明显时，优先级如下：

1. 有真实故障和修复过程，归为 `踩坑复盘`
2. 没有明显故障，但有开发推进和取舍，归为 `开发回顾`
3. 主要在解释概念、方案和边界，归为 `架构/技术介绍`

如果自动判断出的类型可能有争议：

- 在预览时明确告诉用户：`当前判断类型为 <type>`。
- 如果还有第二候选，也一并说明。

### 1.2) 各类型写法

#### `踩坑复盘`

目标：

- 让读者快速知道问题怎么出现、怎么确认、怎么修。

建议结构：

1. 开头直接给问题场景和现象
2. 证据或复现方式
3. 原因定位
4. 改法
5. 验证结果
6. 代价、注意事项或残留风险

写作要求：

- 可以自然使用轻量 STAR：
  - `Situation`: 现场是什么
  - `Task`: 当时要解决什么
  - `Action`: 怎么排、怎么改
  - `Result`: 改完有什么变化
- 开头 1-2 段直接进入问题，不写大段背景。
- 每节只回答一个问题。

#### `开发回顾`

目标：

- 让读者看清这次开发是怎么推进的，原方案为什么不顺，新方案为什么这样落。

建议结构：

1. 需求或目标
2. 原实现 / 原流程的阻力
3. 关键改动
4. 结果和收益
5. 成本、维护负担或后续要补的事

写作要求：

- 允许带一点复盘感，但不要把整篇写成流水账。
- 重点写决策和取舍，不要把所有中间过程都展开。

#### `架构/技术介绍`

目标：

- 让读者理解对象是什么、边界在哪、什么时候该用、什么时候不该用。

建议结构：

1. 场景或常见混淆点
2. 对象拆分
3. 边界与差异
4. 当前项目里的落点或建议

写作要求：

- 少用比喻，优先用对象、职责、边界来解释。
- 读者应能在前几段就知道“这篇解决哪个判断问题”。
- 不要把概念辨析写成长篇散文。

### 1.3) 简洁度要求

- 默认优先写成“简洁技术文”，而不是“技术散文”。
- 前两段必须能让读者看出问题或主题，不要长铺垫。
- 每节都要服务一个明确问题。
- 连续两段都在讲抽象概念时，应删减或落回具体对象。
- 对于短文，优先参考 `source/_posts/pycharm-uvicorn-fastapi.md` 这种直接、短句、问题驱动的结构。
- 当需要比参考文更丰富时，增加证据、取舍、结果和代价，不增加抒情和铺垫。

### 1.4) 避免这些表达问题

- 培训材料式开场：
  - `这篇文章会覆盖三件事`
  - `我来把本质讲清楚`
  - `很多团队第一次做……`
- 强行制造戏剧感：
  - 连续比喻
  - 为了显得生动而加入不必要的调侃
  - 为了“像复盘”而写大段心理活动
- 结论晚到：
  - 前几段一直铺背景，迟迟不进入问题和判断
- 只讲概念，不讲动作：
  - 通篇都是边界、抽象、定义，没有落到怎么判断、怎么改、怎么验证

生成后自检：

- 前两段是否直接进入问题、场景或主题。
- 是否能在 30 秒内找到主要结论或主要操作步骤。
- 是否至少写清楚一个失败点、一个改法、一个结果。
- 是否写清了原方案为什么不顺，以及新方案的代价。
- 是否出现连续多段抽象解释，没有落回具体对象。
- 结尾是否克制，没有升华、训话或口号。

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

### 2.5) Mandatory publish-scope check before commit/push

Before running `bin/publish.sh` or any manual git command, inspect both tracked and untracked files:

- `git status --short`
- Verify the target post file exists in status output.
- Verify the source archive directory exists in status output.
- Verify there are no unrelated files that would be accidentally staged by `git add -A`.

Important current repo caveat:

- The current blog `bin/publish.sh` uses `git diff --quiet && git diff --cached --quiet` as its "no changes" gate.
- This does **not** count untracked files.
- Therefore, a brand new post plus a brand new `source_materials/posts/<archive_id>/` directory can be present, and `bin/publish.sh` may still print `No changes to commit.`

Required decision rule:

- If the publish set includes any untracked files for the current post or archive, do **not** rely on `bin/publish.sh` to perform the commit.
- In that case, still do local build if needed, then commit the exact files manually with minimal scope.
- If the publish set is already tracked-only changes, `bin/publish.sh` is acceptable.

Recommended manual minimal-scope publish for new posts:

```bash
git add source/_posts/<post>.md source_materials/posts/<archive_id>
git commit -m "post: ..."
git push origin hexo-src
```

Do not stage unrelated pending files unless the user explicitly asks to publish them together.

### 3) Publish (commit + push to `hexo-src`)

- `bash bin/publish.sh -m "post: ..."`

This script:

- Checks repo path, remote, and branch
- Runs `npm ci` + `npm run build`
- Commits changes to `hexo-src`
- Pushes to `origin/hexo-src`

But for new posts with untracked files, treat it as a build helper, not a reliable commit gate. The skill must fall back to the manual minimal-scope publish path above.

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
