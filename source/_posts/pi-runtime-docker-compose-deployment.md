---
title: "Docker 镜像、Compose 和环境变量：拆解 Pi Runtime 的部署边界"
date: 2026-08-09 19:50:56
categories:
  - "AI"
tags:
  - "Docker"
  - "Docker Compose"
  - "Pi Runtime"
  - "部署"
  - "AI工作日志"
source_archive:
  id: 20260809-pi-runtime-docker-compose-deployment
  rel_path: source_materials/posts/20260809-pi-runtime-docker-compose-deployment
  conversation_file: conversation.jsonl
---

这次要把 Pi Runtime 部署到一台已经安装 Docker 的 x86_64 Linux 主机上。代码还没有进入代码托管和构建流水线，因此第一版不接镜像仓库，也不做自动发布，只要求本地构建镜像、传到服务器、接入 Nginx，并把环境变量和运行数据放到镜像外面。

讨论到最后，真正需要理清的不是 Dockerfile 语法，而是三个边界：镜像负责什么，Compose 负责什么，环境变量和文件挂载又分别负责什么。尤其要避免一个常见误解：拉取新镜像不会顺带更新 `compose.yml`。

## 第一版先收窄到一条可验证链路

已有镜像仓库、代码平台和构建流水线，不代表第一版必须全部接入。当前代码还没有进入远端仓库，先为流水线写一套配置只会扩大排查面。

第一版链路收敛为：

```text
本地构建 linux/amd64 镜像
  -> docker save 导出镜像
  -> 压缩并传到目标服务器
  -> docker load 导入镜像
  -> 同步 compose.yml
  -> docker compose up -d
  -> Nginx 转发到容器映射在宿主机回环地址上的端口
```

这里有两个阶段。

构建阶段把源码和依赖变成不可变镜像。Dockerfile 使用多阶段构建：builder 安装完整依赖并产出编译结果，runtime 只复制运行所需文件。目标主机是 x86_64，所以本地构建时明确使用 `linux/amd64`，避免在 ARM 开发机上得到无法直接运行的镜像。

运行阶段不再编译代码。服务器只导入镜像，再由 Compose 提供端口、环境变量、挂载目录、重启策略和网络配置。

## 镜像和 Compose 是两个独立部署物

Docker 镜像包含程序、运行时和依赖。`compose.yml` 是部署说明，描述使用哪个镜像、如何启动、开放哪些端口以及挂载哪些目录。

因此：

```text
docker pull / docker load 只更新镜像
docker compose up -d 只读取服务器当前目录里的 Compose 文件
```

Docker 不会从镜像中自动取出新版 `compose.yml`。即使 Compose 和代码放在同一个 Git 仓库，它也只有在部署步骤同步到服务器后才会生效。

如果 `image` 指向可访问的镜像仓库，Compose 可以在本机缺少镜像时自动拉取；本地传输版则可以设置 `pull_policy: never`，明确使用 `docker load` 导入的镜像。两种方式都不会更新 Compose 文件本身。

第一版最简单的做法是把镜像包和 `compose.yml` 当作同一次发布的两个文件：每次都传过去，再执行 `docker compose up -d`。如果 Compose 没变，重复同步的成本也很低，却能避免服务器长期残留旧配置。

后续接入流水线时，这一步可以自动化，但边界不会改变：流水线负责同时发布镜像和部署配置，镜像仓库本身仍然只保存镜像。

## 环境变量不是“挂载”

Compose 可以通过 `environment` 直接向容器进程注入变量：

```yaml
services:
  pi-runtime:
    image: pi-runtime:${IMAGE_TAG}
    environment:
      PI_RUNTIME_PORT: "${CONTAINER_PORT}"
      MCP_BASE_URL: "http://host.docker.internal:${JAVA_PORT}/example/mcp"
      MCP_API_TOKEN: "${MCP_API_TOKEN}"
```

`${MCP_API_TOKEN}` 由服务器上的 `.env` 或启动 Compose 的 Shell 环境完成替换。这里即使没有配置 `env_file`，变量仍会通过 `environment` 进入容器；区别在于 `.env` 只参与 Compose 的变量替换，`env_file` 会把文件中的变量批量注入容器。

如果 `compose.yml` 要和代码一起管理，固定的非敏感配置可以直接写，token、API Key 和签名密钥只保留 `${...}` 占位符。真实值留在服务器，不进入镜像，也不提交 Git。

文件和目录才使用 `volumes`：

```yaml
volumes:
  - ./data:/data
  - ./config/model-api-key.txt:/run/secrets/model-api-key:ro
```

`./data:/data` 保存会话等运行数据，容器删除或重建后数据仍在宿主机。密钥文件以只读方式挂载，程序通过文件路径读取，不必把内容写进 Compose。

这只能解决单机容器重建后的持久化，不能解决主机迁移或多实例共享。等 Runtime 真正扩容时，会话需要进入数据库或对象存储，而不是继续依赖一台主机上的目录。

## 网络入口只交给 Nginx

第一版不让 Runtime 直接暴露到 VPC 或 VPN，只映射到宿主机回环地址：

```yaml
ports:
  - "127.0.0.1:${RUNTIME_PORT}:${CONTAINER_PORT}"
extra_hosts:
  - "host.docker.internal:host-gateway"
```

链路变成：

```text
客户端 -> Nginx -> 127.0.0.1:${RUNTIME_PORT} -> Pi Runtime 容器
Pi Runtime 容器 -> host.docker.internal:${JAVA_PORT} -> Java 服务
```

绑定 `127.0.0.1` 后，同一 VPC 或 VPN 中的其他机器不能直接访问 Runtime 端口，所有外部请求都经过 Nginx。Nginx 继续负责 TLS、路由和流式响应配置，Runtime 只处理应用协议。

如果以后确实需要从 VPN 直连 Runtime，再单独调整监听地址和安全组。第一版没有必要提前扩大暴露面。

## 一次发布到底更新什么

最终可以把文件分成两组。

随版本发布：

```text
Pi Runtime 镜像
compose.yml
```

长期保留在服务器：

```text
.env
只读 API Key 文件
会话和其他运行数据目录
```

一次人工发布的最短动作是：

```text
导入新镜像
同步 compose.yml
执行 docker compose up -d
检查容器健康状态
通过 Nginx 验证一次真实请求
重启容器并确认数据仍然存在
```

需要特别说明：这次形成的是第一版部署设计，不是已经完成上线的结果。镜像构建、Nginx 修改和真实业务验收仍需要在实施阶段执行。

## 后续什么时候再接流水线

当代码进入远端仓库、人工传输开始频繁或需要保留可追踪版本时，再接入构建流水线和镜像仓库：

```text
代码提交
  -> 流水线构建 linux/amd64 镜像
  -> 推送带版本号的镜像
  -> 服务器拉取镜像并同步部署配置
  -> docker compose up -d
```

流水线消除的是人工构建和传输，不会把镜像与 Compose 合并成同一个对象。先把这条边界想清楚，第一版手工部署和后续自动发布就能沿用同一套模型。
