---
title: "从 Playwright 到 CDP：一次语雀文档同步爬虫的登录态踩坑"
date: 2026-05-04 00:33:04
tags:
  - "Playwright"
  - "CDP"
  - "Chrome"
  - "爬虫"
  - "知识库"
source_archive:
  id: 20260504-playwright-cdp-yuque-crawler
  rel_path: source_materials/posts/20260504-playwright-cdp-yuque-crawler
  conversation_file: conversation.jsonl
---

最近做了一个内部文档同步工具，目标很简单：把浏览器里有权限访问的语雀知识库定时同步成本地 Markdown，再给后续 Agent 检索、引用和 RAG 使用。

真正卡住的不是目录解析，也不是 Markdown 入库，而是登录态。Playwright 自带 Chromium、Playwright `channel: "chrome"`、系统 Chrome 独立 Profile 都试过，前两种卡在滑块/风控，第三种又遇到 Profile 锁和会话复用问题。最后稳定下来的路径是：让系统 Chrome 常驻登录，CLI 通过本地 CDP 连接这个已登录页面，在页面上下文里执行 `fetch`。

这篇只记录这条踩坑链路：每种方式怎么做，为什么不顺，最后 CDP 方案的边界是什么。

## 1) 问题场景

语雀文档不是公开页面，直接请求会跳登录页：

```text
GET https://yuque.example.com/group/book/doc
  -> 302 /login?goto=...
  -> 200 login page
```

如果有语雀企业能力或者开放 API Token，最直接的做法当然是走官方 API。但现实里经常会遇到：

- 没有合适的企业 API 权限。
- 账号本身可以在浏览器里访问，但脚本没有机器身份。
- 不希望把 Cookie、Token、密码交给 Agent 或脚本。
- 还要支持批量目录发现、增量同步、本地索引。

所以当时约束很明确：

```text
不能读取 Chrome Cookie 明文
不能导出 token / secret
不能模拟拿个人凭据
可以让用户手动登录一个独立浏览器 Profile
同步器只能复用这个已授权浏览器上下文
```

最终要跑通的是：

```text
doc-search login
  -> 打开登录窗口
  -> 用户手动登录

doc-search sync --scope <scope>
  -> 发现目录
  -> 下载 Markdown
  -> 写 SQLite
  -> 镜像到 data/exported
```

## 2) 第一版：Playwright 自带 Chromium

最自然的第一版是 `launchPersistentContext`：

```js
import { chromium } from "playwright";

const context = await chromium.launchPersistentContext("./data/browser-profile", {
  headless: false,
  viewport: { width: 1440, height: 1000 },
});

const page = await context.newPage();
await page.goto("https://yuque.example.com/group/book/doc");
```

这里的想法是：

```text
第一次：
  Playwright Chromium 打开登录页
  用户手动登录
  登录态保存在 data/browser-profile

后续：
  Playwright 复用 data/browser-profile
  自动访问目录和 Markdown 导出 URL
```

这个方式工程上最顺：

- Playwright 原生支持持久化 Profile。
- 可以统一管理页面、下载、超时、请求。
- 后续跑 headless 也方便。

但实际登录时卡在语雀/阿里系滑块校验。虽然浏览器是有界面的，不是 headless，但它仍然是 Playwright 管理的 Chromium，自动化特征比较明显。

典型现象：

```text
打开登录页
输入登录信息
滑块一直过不去
登录态无法写入 profile
后续 sync 调接口返回 401 或登录页
```

这里要注意一个容易误判的点：**不是只有 headless 才会被识别**。即使 `headless: false`，自动化浏览器仍然可能带有一组和普通 Chrome 不一样的行为特征。

## 3) 第二版：Playwright 启动本机 Chrome

下一步是让 Playwright 不用自带 Chromium，而是用机器上的正式 Chrome：

```yaml
browser:
  channel: chrome
```

代码改成：

```js
const context = await chromium.launchPersistentContext("./data/browser-profile", {
  headless: false,
  channel: "chrome",
  viewport: { width: 1440, height: 1000 },
});
```

这个方案比自带 Chromium 更接近用户日常浏览器：

- 使用本机正式 Chrome。
- 兼容性更接近真实用户。
- 滑块/SSO 理论上更容易通过。

但它仍然是 Playwright 启动的 Chrome。登录阶段依旧有自动化控制痕迹，滑块不稳定，不能作为可靠的同步入口。

这一步的结论是：**换成正式 Chrome 可以降低差异，但不能消除 Playwright 启动链路本身带来的自动化特征。**

## 4) 第三版：系统 Chrome + 独立 Profile

然后换成更接近人工操作的方式：不用 Playwright 打开登录页，而是通过系统命令启动正式 Chrome，并指定一个独立 Profile。

macOS 上大概是这样：

```bash
open -na "Google Chrome" --args \
  --user-data-dir=/path/to/company-doc-search/data/browser-profile \
  --no-first-run \
  --no-default-browser-check \
  https://yuque.example.com/group/book/doc
```

这一步有明显改善：滑块可以通过，用户能正常登录并打开目标文档。

但新的问题出现了：Chrome Profile 是单进程持有的。只要系统 Chrome 窗口还开着，Playwright 再用同一个 `user-data-dir` 启动就会失败：

```text
Failed to create a ProcessSingleton for your profile directory.
This usually means that the profile is already in use by another instance of Chromium.
```

如果让用户登录后关闭 Chrome，再由 Playwright 重新打开同一个 Profile，也不够稳：

- 登录态可能还没完全落盘。
- 某些 SSO/风控状态和当前浏览器进程绑定得更紧。
- Playwright 重新启动 Chrome 时又会带上自动化参数。
- 有时重新打开后又回到登录页。

所以第三版能解决“登录滑块”，但没有解决“同步器如何稳定复用已登录上下文”。

## 5) 最后方案：系统 Chrome 常驻 + CDP 连接

稳定方案是把职责拆开：

```text
系统 Chrome：
  负责真实登录、滑块、SSO、会话保持

同步器：
  不再抢 profile
  不再读取 Cookie
  只通过 CDP 连接已打开的 Chrome
  在已登录页面上下文里执行 fetch
```

启动 Chrome 时加一个本地调试端口：

```bash
open -na "Google Chrome" --args \
  --user-data-dir=/path/to/company-doc-search/data/browser-profile \
  --remote-debugging-port=9223 \
  --remote-allow-origins="*" \
  --no-first-run \
  --no-default-browser-check \
  https://yuque.example.com/group/book/doc
```

用户登录成功后，保持这个 Chrome 窗口打开。CLI 通过 CDP 发现当前页面：

```bash
curl http://127.0.0.1:9223/json/list
```

返回里能看到类似：

```json
[
  {
    "type": "page",
    "title": "文档标题",
    "url": "https://yuque.example.com/group/book/doc",
    "webSocketDebuggerUrl": "ws://127.0.0.1:9223/devtools/page/..."
  }
]
```

同步器连接这个 `webSocketDebuggerUrl`，调用 `Runtime.evaluate`，让页面自己发请求：

```js
const result = await cdp.send("Runtime.evaluate", {
  expression: `
    fetch("https://yuque.example.com/api/xxx", {
      credentials: "include"
    }).then(r => r.text())
  `,
  awaitPromise: true,
  returnByValue: true,
});
```

关键点在 `credentials: "include"`：请求发生在已登录语雀页面的浏览器上下文里，浏览器会自己带上当前会话。脚本没有读取 Cookie 值，也没有把 Cookie 导出到本地配置。

最终链路变成：

```text
doc-search login
  -> 系统 Chrome + 独立 profile + remote debugging port
  -> 用户手动登录
  -> 保持窗口打开

doc-search sync
  -> 访问 127.0.0.1:9223/json/list
  -> 找到 yuque 页面 target
  -> WebSocket 连接 CDP target
  -> Runtime.evaluate(fetch(...))
  -> 拿目录 / Markdown
  -> 写 SQLite / Markdown 镜像
```

## 6) 为什么 CDP 方案能绕开前面的坑

它不是绕过权限，而是把权限边界放回浏览器：

```text
登录、滑块、SSO：
  由真实系统 Chrome + 人完成

会话保存：
  由 Chrome Profile 管

同步请求：
  在已登录页面上下文内发起

脚本权限：
  只连接本机 CDP 端口
  不读取 Cookie 数据库
  不打印 Cookie
  不保存 Token
```

对比前几种方式：

| 方式 | 实现方式 | 优点 | 问题 |
| --- | --- | --- | --- |
| Playwright 自带 Chromium | `launchPersistentContext` | 工程最顺，API 完整 | 滑块/风控容易失败 |
| Playwright + `channel: "chrome"` | 用正式 Chrome 但仍由 Playwright 启动 | 兼容性更接近真实 Chrome | 仍有自动化启动特征 |
| 系统 Chrome 独立 Profile | `open -na "Google Chrome" --args --user-data-dir=...` | 滑块可人工通过 | Profile 被 Chrome 占用，Playwright 不能再抢 |
| 系统 Chrome + CDP | Chrome 常驻，脚本连调试端口 | 不抢 Profile，不读 Cookie，复用真实登录上下文 | 需要本地端口和常驻窗口，部署形态要管控 |

## 7) 目录发现不要只依赖“我的知识库”

同步语雀组织知识库时还有一个小坑：`/api/mine/book_stacks` 不一定能列出目标知识库。

普通个人知识库可能在这里：

```text
https://www.yuque.com/api/mine/book_stacks
```

但组织空间里的知识库，当前账号能打开文档，不代表它会出现在“我的知识库栈”接口里。更稳的兜底是从已打开文档页的 `window.appData` 里取当前 book 和 toc：

```js
const appData = await evaluateOnPage(`
  (() => {
    const appData = window.appData || {};
    return {
      group: appData.group || null,
      book: appData.book || null,
      doc: appData.doc || null
    };
  })()
`);
```

如果页面里已经有：

```text
appData.book.id
appData.book.slug
appData.book.name
appData.book.toc
appData.doc.slug
```

同步器就不必再从“我的知识库”反查目标 book。这个兜底对组织文档特别有用。

## 8) Markdown 同步的实现骨架

这次同步只做 Markdown，不做 DOM 解析。每篇文档的导出 URL 可以按文档 slug 拼：

```text
https://yuque.example.com/group/book/{doc_slug}/markdown?attachment=true&latexcode=false&anchor=false&linebreak=false
```

同步过程：

```text
book.toc
  -> 还原目录树
  -> 遍历 DOC 节点
  -> 页面上下文 fetch Markdown
  -> normalize
  -> sha256(content)
  -> 写入 generation
  -> active_generation 原子切换
  -> 写出 Markdown 镜像文件
```

本地存储不要只靠文件。文件适合人看，但不适合维护同步状态。更稳的是：

```text
SQLite:
  docs
    id
    source_url
    title
    active_generation
    sync_state
    index_quality
    export_path

  generations
    doc_id
    generation
    content_hash
    markdown

filesystem:
  data/exported/{group}/{book}/{toc_path...}/{title}_{slug}.md
```

同步失败时只更新 `sync_state` 和 `last_error`，不动当前 `active_generation`：

```text
旧版本 G1 可读
  -> 开始同步 G2
  -> 下载失败 / 解析失败
  -> 记录 FAILED
  -> active_generation 仍然指向 G1
```

这样失败不会污染本地可用知识库。

## 9) CDP 方案的局限

CDP 不是银弹，它更像一个本地授权浏览器的控制面。

它适合：

- 本地 MVP。
- 内部工具。
- 需要复用人工登录态，但不能读取 Cookie 的场景。
- 目标页面本来就能在浏览器里正常访问。
- 同步频率不高、可接受浏览器常驻。

它不适合：

- 无人值守的生产集群。
- 多用户权限隔离复杂的系统。
- 需要严格审计每个用户访问边界的服务。
- 目标站点明确禁止自动化访问的场景。
- 需要高并发抓取的通用爬虫。

生产化时至少要补这些边界：

- 独立机器或容器用户。
- 专用文档账号，最小权限。
- 只监听 `127.0.0.1` 的 CDP 端口。
- 固定 allowlist 域名和知识库范围。
- 同步日志和失败状态。
- 敏感内容脱敏策略。
- 不把 `data/browser-profile` 提交到仓库。

## 10) 最后的判断

这次排查下来，我对浏览器自动化登录有一个更明确的判断：

```text
如果页面没有强登录风控：
  Playwright persistent context 是最顺的。

如果页面有滑块/SSO/风控：
  不要和登录页硬刚。
  让真实 Chrome 负责登录。

如果还要让脚本稳定同步：
  不要关闭后再抢 profile。
  让 Chrome 常驻，脚本走 CDP。
```

这条路径的价值不在“绕过登录”，而在保持清晰的安全边界：人负责授权，浏览器负责会话，脚本只负责在已授权页面里执行有限同步动作。

对内部 Agent 知识库来说，这个边界比“把 Cookie 导出来给脚本”更可维护，也更容易后续替换成专用账号、API Token 或内部代理服务。
