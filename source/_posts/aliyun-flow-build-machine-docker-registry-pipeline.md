---
title: "从云效 Pipeline 到 Registry：一条镜像构建链路如何工作"
date: 2026-08-24 16:52:02
categories:
  - "AI"
tags:
  - "云效"
  - "Flow"
  - "CI/CD"
  - "Docker"
  - "Registry"
  - "构建机"
  - "Pi"
  - "AI工作日志"
source_archive:
  id: "20260824-pi-java-runtime-flow-build"
  rel_path: "source_materials/posts/20260824-pi-java-runtime-flow-build"
  conversation_file: "conversation.jsonl"
---

最近给 Pi Java Runtime 增加了一条镜像构建流水线。这个接入只新增了一个仓库构建脚本和一条云效 Pipeline，背后沿用的是现有构建系统：云效收集代码版本并提交构建请求，构建机排队执行，仓库的 Dockerfile 产出镜像，Registry 保存制品，企微通知和 Build Event 分别面向人和系统记录结果。

下面按一次请求真实经过的路径，整理各组件的职责、配置和失败边界。Pi 是文末的接入案例，同样的做法也可以用于其他 Java、Node.js 或多阶段 Docker 项目。

## 链路全景

一次构建会经过六个组件：

| 组件 | 接收什么 | 负责什么 | 产出什么 |
| --- | --- | --- | --- |
| Git 仓库 | 代码提交 | 保存源码、Dockerfile 和仓库构建入口 | commit SHA |
| 云效 Flow | Push 或手工运行 | 固定触发版本，提交构建请求 | HTTP 入队请求 |
| 构建请求接收器 | `cmd` 与 `env` | 校验请求、写入串行队列 | 入队确认 |
| 构建机 Worker | 队列任务 | 拉代码、执行脚本、保存日志、处理有限重试 | 进程退出码 |
| Docker / Registry | 构建上下文与镜像 tag | 生成并保存镜像 | tag 与 digest |
| 通知与 Build Event | 构建上下文和结果 | 通知操作人，向控制面留结构化状态 | 消息与状态记录 |

完整时序如下：

```text
开发者 Push / 手工运行
        |
        v
云效：获取代码，得到 branch + commit SHA
        |
        | POST /run { cmd, env }
        v
构建请求接收器：参数检查 -> 入队 -> 返回 HTTP 200
        |
        | 发送“任务已入队”通知
        v
单 Worker 串行取任务
        |
        | 拉取并检出指定 commit
        | 上报 RUNNING Build Event
        v
仓库 build.sh -> Dockerfile -> docker buildx
        |
        | docker push
        v
Registry：保存镜像 tag 与 digest
        |
        | 上报 SUCCESS Build Event
        | 发送“完成”通知
        v
构建机日志 / 控制面 / 企微消息
```

这里有两个不同的 Runner。云效的构建集群运行 Pipeline 中的 Bash 任务；内部构建机上的 Worker 才运行 Git、Docker 和仓库构建脚本。云效任务得到 HTTP 200 时，请求已经进入内部队列，镜像此时通常还没有开始构建。

## 一、云效 Pipeline 如何产生构建请求

### 1. 代码源和触发方式

先在云效 Flow 创建流水线并关联目标仓库。触发条件通常包含：

- 指定分支 Push 自动触发；
- 指定分支手工运行，用于首次验证和失败后的人工重跑；
- 如仓库有 Pull Request 门禁，构建镜像的 Pipeline 与代码检查 Pipeline 分开配置。

流水线的第一项任务使用“获取代码”。这一步不承担最终镜像构建，它提供本次运行对应的 Git 元数据，例如：

```text
CI_COMMIT_REF_NAME=dev
CI_COMMIT_SHA=0123456789abcdef...
```

云效的 Git 环境变量依赖代码源和“获取代码”步骤，变量清单以[官方环境变量文档](https://help.aliyun.com/zh/yunxiao/user-guide/environment-variables/)为准。

commit SHA 需要随请求传给构建机。只传分支名会产生版本错位：提交 A 触发任务后，队列尚未执行，分支已经前进到 B；构建机若只拉取分支最新代码，流水线记录指向 A，镜像内容却来自 B。

### 2. 构建集群和网络

执行 HTTP 请求的机器属于云效构建集群，它需要访问内部的构建请求接收器。网络选择由接收器的位置决定：

- 接收器只有内网地址时，使用与目标网络互通的私有构建集群或 VPC 构建集群；
- 接收器有受保护的公网入口时，可以使用公共构建集群，同时配置鉴权、来源限制和 TLS；
- 连通性检查应在正式构建前完成，至少验证 DNS、路由、端口和证书。

云效的公共构建集群只能访问公网资源，集群类型和适用网络见[官方构建集群文档](https://help.aliyun.com/zh/yunxiao/user-guide/build-a-cluster)。

### 3. Pipeline 变量

将接收器地址配置为流水线变量：

```text
BUILD_RUNNER_URL=https://build-receiver.example.internal/run
```

Webhook、Registry 密码、Git 私钥和 Build Event token 不需要传到这个任务。它们分别保存在通知服务、构建机 Docker 登录态、构建机 SSH 配置和状态上报脚本中。Pipeline 只携带构建标识和 Git 元数据。

### 4. Bash 执行任务

Pipeline 的“执行命令”可以保持很短：

```bash
set -euo pipefail

commit_sha="${CI_COMMIT_SHA:-${CI_COMMIT_ID:-}}"
test -n "${CI_COMMIT_REF_NAME:-}"
test -n "${commit_sha}"

curl --connect-timeout 5 --max-time 15 \
  --fail --show-error --silent \
  -H "Content-Type: application/json" \
  --data "{\"cmd\":\"cd /srv/build/project && bash build.sh\",\"env\":{\"CI_COMMIT_REF_NAME\":\"${CI_COMMIT_REF_NAME}\",\"CI_COMMIT_SHA\":\"${commit_sha}\",\"PIPELINE_NAME\":\"Project Docker Build\",\"CI_PIPELINE_NAME\":\"Project Docker Build\",\"CI_SOURCE_NAME\":\"project\"}}" \
  "${BUILD_RUNNER_URL}"
```

请求体的契约只有两个顶层字段：

```json
{
  "cmd": "cd /srv/build/project && bash build.sh",
  "env": {
    "CI_COMMIT_REF_NAME": "dev",
    "CI_COMMIT_SHA": "完整的 40 位 commit SHA",
    "PIPELINE_NAME": "Project Docker Build",
    "CI_PIPELINE_NAME": "Project Docker Build",
    "CI_SOURCE_NAME": "project"
  }
}
```

`cmd` 指向构建机上已经部署好的仓库入口；`env` 会合并进子进程环境。`PIPELINE_NAME` 和 `CI_SOURCE_NAME` 用于人类通知，`CI_PIPELINE_NAME` 用于结构化 Build Event。流水线可以继续传入操作人和运行说明，但不应把自由文本拼进 `cmd`。

`curl --fail` 会让 4xx、5xx 直接结束云效任务；连接和总超时防止网络异常长时间占住云效执行器。HTTP 200 的含义仅为“请求已入队”。

## 二、构建机如何接收和排队

构建请求接收器是一个常驻 HTTP 服务。当前实现收到 `POST /run` 后执行以下动作：

1. 读取 JSON，请求缺少 `cmd` 或 `env` 时返回 400；
2. 记录环境变量、接收时间和任务类型；
3. 将 `(cmd, env, received_at, task_type)` 写入内存队列；
4. 发送“代码构建任务已提交到队列”的企微通知；
5. 立即返回 `{"msg":"command queued"}`。

队列由单个后台 Worker 消费。串行执行牺牲了一部分吞吐量，换来了简单的资源隔离：多个大型 Docker 构建不会同时争抢磁盘、内存、网络和 BuildKit 缓存，也不会并发覆盖同一个可变镜像 tag。

Worker 取到任务后，将 Pipeline 传来的 `env` 合并到构建机环境，再通过 Shell 启动命令。标准输出、标准错误、退出码和耗时都由接收器统一收集。服务日志按天轮转并保留固定周期；失败任务还会生成单独的文本报告，通知中给出查看地址。

执行前还会检查根分区剩余空间。空间低于安全线时先清理 Docker、Buildx 和 Builder 缓存。这个机制保护共享构建机，代价是下一次构建失去缓存后耗时会上升，因此阈值应按机器磁盘容量设置。

### 有限重试

重试只处理有明确瞬时特征的故障：

- Registry 认证、拉取 metadata 或 push 时出现连接重置、TLS 超时、DNS 失败、502/503/504；
- BuildKit 缓存出现已知的 snapshot 父节点丢失。

命中这些特征后，Worker 清理构建缓存并重试一次。编译错误、测试失败、Dockerfile 错误和脚本参数错误不会自动重试；再次运行同一份代码不会修复这些问题，重复构建只会占用队列。

## 三、仓库构建脚本如何连接 Git、Dockerfile 和 Registry

接收器只负责运行命令，不了解仓库结构。每个项目在构建机脚本目录中提供一个薄的 `build.sh`，处理五件事：

1. 校验分支和 commit SHA；
2. 更新构建机上的仓库缓存并检出确定提交；
3. 上报 `RUNNING`；
4. 调用仓库自己的 Dockerfile 构建并推送镜像；
5. 读取镜像 digest，上报 `SUCCESS`。

一个通用骨架如下：

```bash
#!/usr/bin/env bash
set -euo pipefail

readonly repository="git@example.com:team/project.git"
readonly branch="${CI_COMMIT_REF_NAME:?missing branch}"
readonly commit_sha="${CI_COMMIT_SHA:?missing commit SHA}"
readonly image="registry.example.com/team/project:${branch}"
readonly code_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/code"

if [ ! -d "${code_dir}/.git" ]; then
  git clone "${repository}" "${code_dir}"
fi

git -C "${code_dir}" fetch --prune origin \
  "+refs/heads/${branch}:refs/remotes/origin/${branch}"
git -C "${code_dir}" cat-file -e "${commit_sha}^{commit}"
git -C "${code_dir}" merge-base --is-ancestor \
  "${commit_sha}" "origin/${branch}"
git -C "${code_dir}" checkout --detach "${commit_sha}"

report_build RUNNING "${image}" ""

docker buildx build \
  --platform linux/amd64 \
  --file "${code_dir}/Dockerfile" \
  --tag "${image}" \
  --label "org.opencontainers.image.revision=${commit_sha}" \
  --load \
  "${code_dir}"

docker image inspect "${image}" >/dev/null
docker push "${image}"
digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "${image}")"

report_build SUCCESS "${image}" "${digest}"
```

示例里的 `report_build` 代表已有的状态上报辅助脚本。实际接入时复用公共 helper 即可，没有必要让每个仓库重新实现 HTTP 请求、超时和 JSON 字段。

### Dockerfile 由代码仓库维护

依赖安装、编译命令、多阶段镜像、运行用户和启动入口都属于项目代码，应与源码一起评审和版本化。构建机脚本只选择：

- Dockerfile 路径；
- build context；
- 目标平台；
- 镜像名称和标签；
- 需要写入的 OCI 元数据。

单仓项目一般以仓库根目录为 context；monorepo 是否能够缩小 context，要看 Dockerfile 是否复制其他 workspace。错误地缩小 context 会让 Docker 在执行 `COPY` 时找不到依赖，或者构建出缺少内部包的镜像。

### Registry 保存的是制品

Registry 认证由构建机维护。Docker build 完成后，脚本先做本地检查，再执行 `docker push`。只有 push 成功，镜像才算进入可供后续部署使用的制品库。

tag 适合表达渠道，例如 `dev`、`test`、`release`；digest 对应不可变内容。当前链路可以先推送固定分支 tag，控制面同时记录 commit SHA 和 digest。需要处理并发、回滚或精确部署时，再增加 `:<commit-sha>` 不可变 tag，并让渠道 tag 指向同一份 digest。

## 四、消息通知和结构化 Build Event

这条链路保留两套输出，因为它们服务的消费者不同。

### 面向人的企微通知

构建请求接收器持有通知配置，Pipeline 不接触 Webhook。通知覆盖三个时点：

- 入队：流水线、仓库、分支、操作人和提交时间；
- 完成：耗时、进程返回码，以及脚本输出中识别到的镜像；
- 失败：错误类型、耗时和独立错误报告链接。

Registry 网络抖动会使用较安静的提示，并说明是否已经自动重试；编译或脚本异常会提醒对应操作人。这样可以减少瞬时基础设施故障带来的重复人工排查。

### 面向系统的 Build Event

仓库构建脚本在检出源码后写入 `RUNNING`，在 `docker push` 后写入 `SUCCESS`。事件包含：

```text
repo, branch, commitId, service, status,
image, digest, buildMachine, pipelineName
```

控制面由此可以回答“哪个 Pipeline 在哪台构建机上，把哪个提交构建成了哪个镜像”。状态上报属于旁路：连接超时很短，接口不可达时只写 warning 并返回成功，不能让观测系统故障改变 Docker 构建结果。

当前实现尚未写 `FAILED` Build Event，失败结果主要存在于 Worker 日志和企微通知。补齐失败事件后，控制面才能独立形成完整状态机。

## 五、一次构建到底什么时候成功

链路中存在三层成功语义：

| 位置 | 成功代表什么 | 不代表什么 |
| --- | --- | --- |
| 云效 Bash 任务 | 请求接收器已返回 2xx | 镜像已经构建或推送 |
| 构建机进程 | `build.sh` 退出码为 0 | 部署已经更新 |
| Registry / Build Event | push 成功，并记录了镜像信息 | 容器已经启动且健康 |

排障时先确认问题属于哪一层：

1. 云效失败：检查变量、构建集群网络、接收器 HTTP 状态；
2. 云效成功但长期没有入队通知：检查请求是否到达正确接收器；
3. 已入队但没有完成通知：查看队列前方任务和 Worker 进程；
4. Worker 失败：从独立错误报告判断 Git、编译、Docker、Registry 哪一步退出；
5. Worker 成功但控制面无记录：检查旁路 Build Event 的 warning；
6. Registry 有镜像但业务未变化：构建链路已经结束，转到部署链路检查。

异步入口让云效执行器很快释放，也允许多条 Pipeline 共享少量构建机。它同时造成云效页面的绿色状态只表示“已受理”。如果要求云效直接展示最终构建结果，接收器需要返回任务 ID，并提供轮询、回调或事件订阅；这会引入任务持久化和状态生命周期，现阶段没有把它塞进简单的入队接口。

## 六、将一个新 Pipeline 接入现有链路

接入新仓库时，改动集中在两处。

构建系统仓库中增加一个项目目录和 `build.sh`：

- 填写 Git 地址、允许的分支、Dockerfile 路径和 build context；
- 设计 Registry 镜像名与 tag；
- 复用公共 Build Event helper；
- 做 Shell 语法检查和错误分支自测；
- 将脚本部署到所有可能接单的构建机。

云效中增加一条 Pipeline：

- 关联代码源并配置触发分支；
- 选择能访问接收器的构建集群；
- 增加“获取代码”；
- 配置 `BUILD_RUNNER_URL`；
- 增加提交 `cmd + env` 的 Bash 任务；
- 手工运行一次，按“入队、RUNNING、push、SUCCESS、通知”五个节点验收。

接收器、串行队列、企微通知、错误报告和状态上报 helper 可以直接复用。项目差异留在 `build.sh` 和 Dockerfile，避免为每个仓库复制一套 HTTP 服务和通知代码。

## Pi Java Runtime 的接入位置

Pi 的特殊配置只落在仓库构建脚本里：构建目标来自 `dev`，目标平台是 `linux/amd64`，Dockerfile 位于 Java Runtime 包中，但 build context 使用 monorepo 根目录，因为 Runtime 编译依赖多个 workspace。脚本检出云效传来的确定 SHA，调用该 Dockerfile，推送 Runtime 镜像并记录 digest。

云效、请求接收器、队列、通知和 Build Event 没有为 Pi 增加专属分支。下一套镜像接入仍沿用同一个请求契约，只替换项目目录、构建入口和镜像身份。

## 当前边界与后续演进

这套实现已经覆盖“触发、排队、构建、推送、通知、留痕”，仍保留几项清晰的工程边界：

1. **队列在内存中。** 接收器重启会丢失尚未执行的任务。出现不能接受的任务丢失后，再引入数据库或消息队列持久化。
2. **入口能够执行 Shell。** 当前接口只校验 `cmd` 和 `env` 是否存在，因此只能放在可信内网。对外暴露前应增加身份认证、命令白名单、来源限制和 TLS。
3. **云效不等待最终结果。** 需要统一 CI 状态时，再增加任务 ID 和状态查询，不要用超长 HTTP 连接占住 Pipeline。
4. **分支 tag 可变。** 对精确部署和回滚有要求时，增加 commit SHA tag，部署按 digest 或不可变 tag 取制品。
5. **失败事件不完整。** Worker 已经保存退出码和错误报告，下一步可以将同一信息投影成 `FAILED` Build Event。
6. **单 Worker 限制吞吐。** 队列持续积压后，再按机器资源或镜像命名空间拆分 Worker；在没有数据证明瓶颈前，串行执行更容易维护。
7. **构建与质量门禁分离。** Dockerfile 能编译不等于测试通过。需要阻断不合格镜像时，在 push 前加入项目自己的检查命令，或让独立检查 Pipeline 成为构建前置条件。

这条链路的维护边界很明确：云效决定构建哪次提交，接收器决定何时执行，仓库决定怎样构建，Registry 保存结果，通知和 Build Event 记录发生了什么。部署可以在后续按 image digest 接入，不需要改变前面的镜像生产流程。
