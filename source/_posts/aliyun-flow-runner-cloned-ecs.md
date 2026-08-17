---
title: "复制 ECS 后云效 Flow 部署串机：Runner 身份被一并复制"
date: 2026-08-17 15:10:07
tags:
  - "阿里云"
  - "云效"
  - "Flow"
  - "CI/CD"
  - "ECS"
  - "故障排查"
source_archive:
  id: "20260817-aliyun-flow-runner-cloned-ecs"
  rel_path: "source_materials/posts/20260817-aliyun-flow-runner-cloned-ecs"
  conversation_file: "conversation.jsonl"
---

复制一台正在承担部署任务的 ECS 后，云效 Flow 开始把制品随机部署到原机器或复制机。两台机器的 ECS 实例 ID 不同，但在 Flow 看来，它们使用的是同一个 Runner 身份。

最后的止血动作很简单：停止并禁用复制机上的 Runner。真正值得记录的是，为什么复制磁盘会复制部署身份，以及 Flow Runner 到底怎样领取和执行任务。

## 现象

原 ECS 承担前端发布。复制实例启动后，流水线构建仍然成功，但主机部署阶段不再稳定：

```text
Flow 构建成功
  -> 生成并上传制品
  -> 进入主机部署阶段
  -> 有时部署到原 ECS
  -> 有时部署到复制 ECS
```

仓库里的 Webhook 脚本只负责触发流水线，并不携带 ECS 地址：

```bash
curl -X POST -H "Content-Type: application/json" \
  --data '{}' \
  'https://flow-openapi.example.com/pipeline/webhook/<webhook-id>'
```

因此问题不在业务代码或 Webhook，而在主机部署阶段使用的 Runner。

## 现场证据

两台 ECS 的真实实例 ID 不同：

```text
原 ECS:   i-original
复制 ECS: i-cloned
```

但两台机器上存在完全相同的 systemd 服务：

```text
runner-v0.3.0-be-<tenant>.service
```

Runner 配置位于：

```text
/root/yunxiao/<tenant>/runner/config/config.yml
```

配置结构包含：

```yaml
uuid: <runner-uuid>
url: <flow-server>
token: <runner-token>
tenant: <tenant>
instanceId: i-original
workspace: /root/yunxiao/<tenant>/runner
scanInterval: 5
concurrency: 50
autoUpgrade: true
```

关键证据有两个：

1. 两台机器的 `config.yml` SHA-256 完全相同。
2. 复制机配置中的 `instanceId` 仍然是原 ECS，而不是复制机自己的实例 ID。

这说明 ECS 复制过程把 Runner 的 UUID、Token、租户和实例绑定信息一起复制了。hostname 相同只会增加运维混淆，真正导致串机的是 Runner 注册身份相同。

## Flow Runner 怎么工作

云效官方将 Runner 定义为安装在构建机或部署主机上的本地服务。它通过长轮询从 Flow 服务端拉取任务，再同步执行状态和日志。[流水线 Runner](https://help.aliyun.com/zh/yunxiao/user-guide/pipeline-runner/)

可以把它理解成一个常驻任务 Worker：

| Flow 概念 | 后端开发中的对应概念 |
| --- | --- |
| Flow 服务端 | 调度中心 |
| 主机组 | Worker 分组和部署范围 |
| Runner | 常驻任务消费者 |
| Runner UUID、Token | Worker 身份和凭证 |
| Build UUID | 单次任务实例 ID |
| Step | 任务中的执行步骤 |
| Shell Executor | 本机任务执行器 |

现场使用的二进制自报版本为 `v0.3.0`，支持 `register`、`install`、`run`、`exec` 和 `upgrade` 等命令。systemd 启动 `runner run` 后，它会持续执行下面的链路：

```text
Runner 常驻进程
  -> POST /api/v2/builds/request 长轮询任务
  -> 没有任务：返回 204，继续轮询
  -> 收到任务：取得 Build UUID 和 Steps
  -> 创建临时工作目录和 Shell 脚本
  -> PUT /api/v2/builds/{uuid} 上报 RUNNING
  -> 下载流水线制品
  -> 使用 Shell Executor 执行部署脚本
  -> POST /steps/{index}/log 分片上传日志
  -> PUT /api/v2/builds/{uuid} 上报 SUCCESS 或 FAILED
  -> 标记任务完成并延迟清理目录
```

一次任务在本机留下的结构大致如下：

```text
/root/yunxiao/<tenant>/runner/
  -> config/config.yml
  -> __flow_work/__flow_temp/<build-uuid>/
       -> scripts/step-0.sh
       -> scripts/step-1.sh
       -> set_env.command
  -> __flow_logs/builds/<build-uuid>/
       -> step_0.log
       -> step_1.log
       -> finish
```

当前主机部署任务的实际动作也很直接：创建制品目录、下载压缩包、生成用户命令脚本、解压到站点目录，然后把退出码和日志回传给 Flow。

主机组决定部署范围。Flow 可以把上游制品下载到主机组中的机器，并支持分批发布；YAML 流水线则通过 `machineGroup` 指定主机组。[流水线关键概念](https://help.aliyun.com/zh/yunxiao/user-guide/analysis-of-key-concepts-of-pipeline)

## 为什么会随机部署

复制完成后，实际形成了两个使用相同身份的消费者：

```text
原 ECS Runner
  -> 使用身份 A 长轮询

复制 ECS Runner
  -> 也使用身份 A 长轮询

Flow 服务端
  -> 为身份 A 准备部署任务
  -> 两个进程同时请求
  -> 任务可能被任意一个进程领取
```

Flow 服务端如何处理重复 Runner 身份没有公开实现，无法从源码确认；但两台机器的配置完全相同、日志显示它们使用相同 Runner 标识轮询，而且部署记录确实分别落到两台机器，已经足以确认故障链路。

## 修复与验证

复制机暂时不需要参与 Flow 部署，因此直接停止并禁用它的 Runner：

```bash
sudo systemctl disable --now runner-v0.3.0-be-<tenant>.service
```

验证结果：

```text
原 ECS
  -> Runner active/running
  -> enabled
  -> 正常领取部署任务

复制 ECS
  -> Runner inactive/dead
  -> disabled
  -> 不再请求 Flow 任务
```

后续流水线重新稳定部署到原 ECS，说明止血动作与根因一致。

## 停用不等于彻底清理

`disable --now` 只停止进程并取消开机启动，复制机磁盘中仍然保留原 Runner Token 和配置。有人重新启用该服务，问题还会复发。

长期处理应根据复制机用途二选一：

- 不需要 Flow：卸载复制过来的 Runner，并删除对应注册配置。
- 需要独立部署：清理旧 Runner，再从 Flow 控制台重新接入，让它获得新的 UUID、Token 和实例绑定，并加入独立主机组。

阿里云的主机部署故障文档也建议：通过镜像生成的新主机，不应继续使用复制的代理身份，应卸载后重新添加。[主机部署问题](https://help.aliyun.com/zh/yunxiao/user-guide/common-issues-in-host-deployment/)

以后复制 ECS 或制作系统镜像时，应该额外检查这些有注册身份的常驻代理：

- CI/CD Runner
- GitLab Runner
- 监控和日志采集 Agent
- 服务注册 Agent
- 节点证书和机器级 Token

这类组件不是普通软件包。复制磁盘不仅复制了程序，也可能复制它在外部控制平面中的身份。

- 写正文
- 本地预览：`npm run server`
- 发布：`bash bin/publish.sh -m "post: ..."`
