# 自动配料操作动图与博客增量 Implementation Plan

**Feature:** 内容增量 — `docs/superpowers/specs/2026-07-29-auto-batching-operation-gifs-design.md`
**Goal:** 用真实、不保存的页面操作证明自动配料的关键体验优化，并将其写入现有文章。
**Acceptance Criteria:** 六类优化均有对应说明；可安全录制的交互使用真实 GIF；不发布内部地址、账号或令牌；Hexo 构建通过。
**Architecture cell:** 内容资产
**Map delta:** none
**Map delta why:** 仅为现有博客文章补充媒体与文案，不改变系统架构。
**Architecture:** Chrome 隔离会话采集未保存的 UI 状态；FFmpeg 将连续真实截图合成为短 GIF；文章按用户动作、系统反馈和边界组织。
**Tech Stack:** Chrome DevTools、FFmpeg、Hexo
**前端验证:** Yes — 通过真实页面状态截图与本地 Hexo 构建验证。

---

### Task 1: 采集不落库的真实操作状态

**Files:**
- Create: `source/img/auto-batching-ux-redesign/operation-*.png`

1. 在隔离会话中打开新建自动配料配方。
2. 临时输入原料、元素和成分目标，触发自动带入、最优值补齐、目标复制和推荐值应用。
3. 不点击“保存”；每个动作采集前后状态截图。

**验证：** 截图仅含页面 UI，不含内部地址、账号、令牌或已保存的业务数据。

### Task 2: 生成并复核 GIF

**Files:**
- Create: `source/img/auto-batching-ux-redesign/operation-*.gif`

1. 使用 FFmpeg 将每组真实前后状态制作成 5 至 8 秒 GIF。
2. 确认每段只表达一个交互结果，且不会把静态图宣称为连续录屏。

**验证：** GIF 可读取，文件生成成功。

### Task 3: 重写文章后半段并构建

**Files:**
- Modify: `source/_posts/auto-batching-ux-redesign.md`

1. 将“操作优化”从功能列表改为用户动作、系统反馈、工序边界和用户控制权。
2. 插入真实 GIF，保留低频设置收起的现有动图。
3. 以克制成果总结收尾，不夸大未验证指标。
4. 运行 `npm run build`。

**验证：** 构建成功，生成页面引用所有新增 GIF。
