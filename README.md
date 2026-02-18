# WillfordZhan Blog (Hexo Source)

这个分支（`hexo-src`）存放 Hexo 的**源码**；站点生成后的静态文件会由 GitHub Actions 自动构建并发布到 `master` 分支（GitHub Pages 直接从 `master` 提供访问）。

## 写文章

- 新建文章：在 `source/_posts/` 下新增一个 `.md`
- 本地预览：

```bash
npm ci
npm run server
```

## 发布

推送到 `hexo-src` 即可触发自动构建并部署到 `master`：

```bash
git checkout hexo-src
# 修改/新增文章后
git add -A
git commit -m "post: ..."
git push origin hexo-src
```

## 目录约定

- `hexo-src`：源码分支
- `master`：生成后的静态站点（GitHub Pages）
