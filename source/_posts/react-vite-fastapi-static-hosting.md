---
title: "React/Vite 前端如何交给 Python/FastAPI 托管：从 npm run build 到默认首页入口"
date: 2026-03-23 17:23:00
tags:
  - "React"
  - "Vite"
  - "FastAPI"
  - "Python"
  - "前端工程"
  - "静态资源"
source_archive:
  id: 20260323-react-vite-fastapi-static-hosting
  rel_path: source_materials/posts/20260323-react-vite-fastapi-static-hosting
  conversation_file: conversation.jsonl
---

项目里有一个 `app_manage`，前端是 React + Vite，后端是 Python + FastAPI。最开始的问题很直接：`service.sh` 启动时，能不能把前端也一起拉起来，并且把 Python 服务的默认首页切到这个前端。

这类需求第一次看，很容易顺手想到 `service.sh` 里再后台起一个 `npm run dev`。它能跑，但不太像一个稳定的服务发布方案。真正要先分清的是，这个前端到底应该以“开发服务器”存在，还是应该先构建成静态产物，再交给 Python 托管。

我这次最后给出的建议，是后者。

## 先把两个概念拆开

前端日常开发时，常见的是：

```bash
npm run dev
```

这会启动一个 Vite 开发服务器。它的职责是热更新、模块编译、开发期代理，适合本地边改边看。

真正上线或者做统一服务启动时，更合适的动作通常是：

```bash
npm run build
```

这一步不会常驻运行一个 Node 服务，而是把前端源码构建成一套静态文件，通常包括：

- `index.html`
- `assets/*.js`
- `assets/*.css`
- 图片、字体等资源文件

浏览器最终访问的，其实就是这些产物。

## 这条链路到底长什么样

先看完整链路图：

```text
React / TSX 源码
    |
    | npm run build
    v
Vite 构建输出
    |
    | 生成静态资源
    v
app_manage/static/manage-console/
    |-- index.html
    |-- assets/index-xxxx.js
    |-- assets/index-xxxx.css
    |
    | FastAPI StaticFiles 挂载
    v
/ai/management/console/
    |
    | 浏览器访问
    v
加载 index.html -> 再加载 js/css -> React 在浏览器里运行
```

如果再把 `service.sh` 也放进来，完整启动链路会变成这样：

```text
./service.sh start
    |
    | 先执行
    v
npm run build
    |
    | 把前端打成静态产物
    v
app_manage/static/manage-console/
    |
    | 再执行
    v
uvicorn main:app
    |
    | FastAPI 挂载静态目录
    v
GET /
    |
    | 重定向
    v
/ai/management/console/
```

这里最容易让人误会的一点是：前端页面虽然是 React 写的，但真正给浏览器返回页面的，可以不是 Node，也可以是 Python。只要 Python 能把那套静态文件按 URL 提供出来，浏览器照样能运行它。

## 它和 Tomcat 部署前端的类比，能类比到哪一步

可以类比，但不要直接类比成 `WEB-INF`。

更接近的理解是：

1. React/Vite 项目先打包出一个 `dist` 一样的静态目录。
2. 这个目录被服务器托管出来。
3. 浏览器请求 `index.html`、`js`、`css` 后，前端应用在浏览器里真正跑起来。

`WEB-INF` 更偏 Java Web 容器自己的内部约定，很多内容默认不是直接公开给浏览器的。这里这套 `static/manage-console` 则更像一个“可直接对外访问的前端发布目录”。

所以拿 Tomcat 来比，比较像下面这个意思：

```text
前端打包目录  ->  被应用服务器托管  ->  浏览器访问首页
```

不是：

```text
前端源码直接扔进服务器里运行
```

源码不是浏览器直接吃的，构建产物才是。

## 为什么我不建议 service.sh 直接后台起 npm run dev

这条路不是不能走，而是它引入的东西比需求本身多。

先看它会多出来什么：

- 多一个 Node 常驻进程
- 多一个前端端口
- 多一份 PID 管理
- 多一套日志管理
- 停服务时还得保证 Node 也一起停掉
- Python 根路径如果还想保持统一入口，通常还要做反向代理

这时服务脚本就不再是“启动一个系统”，而是在同时养两套服务。

对于开发态联调，这么干可以接受。对于你这种已经明确有构建产物目录、并且 FastAPI 已经能挂静态资源的项目，这条路没必要。

## 当前项目里，这套托管其实已经基本具备了

前端构建配置大概是这个意思：

```ts
export default defineConfig({
  base: "/ai/management/console/",
  build: {
    outDir: "../static/manage-console",
  },
});
```

这里有两个关键信息：

1. 构建后的访问基路径是 `/ai/management/console/`
2. 输出目录直接落到 Python 会挂载的静态目录

FastAPI 侧则会做类似这样的事情：

```python
app.mount(
    "/ai/management/console",
    StaticFiles(directory="app_manage/static/manage-console", html=True),
)
```

意思是：

- 浏览器访问 `/ai/management/console/`
- FastAPI 就去 `app_manage/static/manage-console/` 找对应文件
- `html=True` 时，请求目录入口会返回 `index.html`

这就是前端能被 Python 托管起来的关键。

## 默认首页入口怎么切

项目里如果已经有一个旧首页，比如：

```python
@app.get("/")
async def root_redirect():
    return RedirectResponse(url="/ai-chat/assistant.html", status_code=307)
```

那改默认入口，本质上只是把跳转地址换掉：

```python
@app.get("/")
async def root_redirect():
    return RedirectResponse(url="/ai/management/console/", status_code=307)
```

改完以后，用户访问根路径 `/`，就直接进入新的 React 管理台了。

这里没有神秘机制，就是一个服务端跳转。

## 真正推荐的 service.sh 方案

更稳的做法是把 `service.sh` 设计成两步：

```text
1. 构建前端静态资源
2. 启动 Python/FastAPI
```

脚本行为可以概括成这样：

```bash
start() {
  cd app_manage/frontend
  npm run build

  cd 项目根目录
  uvicorn main:app --host 127.0.0.1 --port 8000
}
```

实际工程里还会再补几件事：

- `node_modules` 不存在时先 `npm install`
- 构建失败就不启动 Python
- 日志、PID、端口检查仍然由原服务脚本统一处理

这样改完后，启动路径会非常清晰：

```text
源码改动
  -> build
  -> 生成静态资源
  -> Python 托管
  -> 浏览器访问统一入口
```

## 这套方式的收益是什么

第一，部署模型更简单。

最终对外只有一个 Python 服务入口。用户不需要知道前面还有没有 Node，也不需要区分“前端端口”和“后端端口”。

第二，链路更稳定。

你不用额外处理 Vite dev server 的生命周期，也不用担心服务停了以后 Node 还留在后台。

第三，职责边界更清楚。

- 开发期：前端自己用 `npm run dev`
- 服务启动或发布期：统一 `npm run build`，再交给 Python 托管

这两种模式的职责不同，混在一起后面容易越来越乱。

## 这套方式的代价也要说清楚

它不是没有代价，只是代价比较可控。

主要有三个：

1. 每次服务启动前，如果都重新 build，会多一点启动时间。
2. 前端一旦改了代码，必须重新 build，浏览器才能看到最新托管版本。
3. 如果以后前端需要特别强的开发态代理、HMR、Mock 联调能力，开发时还是得单独跑 `npm run dev`。

所以这套方案适合“统一启动、统一部署、统一入口”，不等于替代前端开发服务器。

## 最后用一句话收住

`npm run build` 做的事，不是“把前端服务跑起来”，而是“把前端源码变成浏览器能直接访问的一套静态站点”。后面这套站点可以交给 Nginx、Tomcat、FastAPI，或者任何能托管静态文件的服务。

你这个场景里，FastAPI 已经有静态挂载能力，也已经有现成输出目录。那最省事、也最稳的方案，就是：

```text
build 前端 -> 输出到 static -> FastAPI 挂载 -> 根路径跳到新前端
```

够直接，也够长期。
