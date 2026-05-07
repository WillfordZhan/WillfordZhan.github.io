---
title: "把构建、部署和 Agent 调试闭环接起来"
date: 2026-05-07 19:27:40
categories:
  - "AI"
tags:
  - "AI Agent"
  - "自动化部署"
  - "DevOps"
  - "AI工作日志"
source_archive:
  id: 20260507-agent-build-deploy-loop
  rel_path: source_materials/posts/20260507-agent-build-deploy-loop
  conversation_file: conversation.jsonl
---

这次主要补的是 Agent 编码之后的下一段路：代码可以自动改了，但构建完成、镜像确认、部署调试机这几步还断在人工操作里。结果就是 Agent 写完代码以后，仍然不知道什么时候可以部署，也不知道应该拿哪一个镜像去跑调试。

最后落下来的方案没有做成一套很重的发布平台，而是先把调试闭环打通：构建脚本上报状态，后台服务记录构建产物，Agent 查询成功镜像，再调用仓库里的受控部署脚本更新调试机。

## 目标

当前工作流大致是：

```text
开发仓库 push -> CI 触发构建 -> 构建机 build/push 镜像 -> 人工收到通知 -> 人工部署调试机
```

编码阶段已经能交给 Agent，但“构建完成之后发生了什么”对 Agent 是不可见的。企业微信通知对人有用，对 Agent 没有稳定结构；镜像仓库里虽然能看到 tag 和 digest，但用 registry 反推“这次构建产物”并不可靠，尤其是分支 tag 会覆盖。

所以这次的目标很窄：

1. 构建阶段把 `RUNNING` / `SUCCESS` 上报到云端服务。
2. 上报失败不能影响原构建。
3. Agent 能按 `repo + branch + service + commitId` 查询完整镜像。
4. 调试机部署继续走受控脚本，不手工拼 SSH 命令。

## 构建上报

第一版只做成功链路，不处理失败日志，也不引入复杂流水线模型。构建机在两个时机上报：

```text
RUNNING: 代码目录切到目标分支，并拿到 commit 之后
SUCCESS: docker push 成功之后
```

云端接口收敛成一个 upsert 入口：

```text
POST /ci/build-report
```

唯一键是：

```text
repo + branch + commitId + service
```

这样同一个提交重复构建时不会插出多条互相竞争的记录；同一个分支的新提交构建成功后，也能明确区分“当前提交产物”和“分支最新成功产物”。

构建脚本里的上报逻辑没有直接铺在业务脚本里，而是抽成一个公共 helper。业务构建脚本只保留两次调用：

```bash
report-build.sh RUNNING
report-build.sh SUCCESS
```

这个 helper 的约束比功能更重要：

```text
connect timeout: 1s
max time: 3s
failure: warn only
exit code: never breaks build
```

也就是说，云端服务挂了、网络慢了、token 配错了，都只能影响 Agent 感知，不能影响镜像构建本身。

## 云端记录

云端先只加了最小表：

```text
repo
branch
commitId
service
status
image
digest
startedTime
finishedTime
```

接口也只保留两个核心动作：

```text
POST /ci/build-report
GET  /ci/build-report/latest
```

其中 `latest` 查询默认服务于 Agent：

- 带 `commitId`：查询当前提交对应的成功镜像。
- 不带 `commitId`：查询该分支最新成功镜像，但必须是用户明确接受这个语义。

这里没有把 digest 当成 v0 的强依赖。digest 有价值，能确认 tag 当前指向的不可变内容，但部署调试机需要的是完整 image。第一阶段先让 Agent 拿到正确 image，后面再补 digest 校验也来得及。

## 部署脚本

部署脚本没有放进 skill 里，而是保留在产品仓库的 `bin/` 目录下。原因很简单：它会改调试机上的 `compose.yml`，还会执行远端 `update.sh`，这是实际运维入口，不应该藏在 Agent 私有目录里。

脚本做的事很克制：

1. 根据 `j`、`f`、`both` 三种模式选择服务。
2. 备份远端 `compose.yml`。
3. 精确替换对应 service 的 image 行。
4. 只保留最近两个 Agent 创建的备份。
5. 执行远端已有的 `update.sh`。
6. 验证容器正在用预期镜像运行。

这里没有做额外元数据块，也没有设计新的部署协议。调试机本来就是人和 Agent 并行使用的环境，保持“像人一样改 compose 再 update”反而更容易和现有习惯兼容。

## Agent Skill

最后补的是 Agent 侧 skill。这个 skill 的重点不是把所有命令写进去，而是把低 HITL 的边界写清楚。

默认场景是：

```text
编码完成 -> 构建 -> 查询构建产物 -> 部署调试机 -> 继续查日志调试
```

所以它不应该每一步都问用户。只要上下文能判断影响范围，就直接推断部署模式：

- 后端变更：部署 `j`
- 前端变更：部署 `f`
- 两边都有变更：部署 `both`

但也不能因为低 HITL 就模糊部署。这里补了两个硬约束：

1. 默认必须带 `commitId` 查询构建产物。
2. `both` 模式必须先分别拿到两个服务的完整 image，全部成功后再部署一次，不能自动降级成单服务部署。

如果用户明确说“部署该分支最新成功构建”，skill 才允许不带 `commitId`。这个区分很关键，否则 Agent 漏传参数就可能静默部署到同分支更新的镜像。

## 结果

这次跑通之后，链路变成：

```text
git push
-> CI 构建
-> 构建机上报 RUNNING / SUCCESS
-> 云端记录 image
-> Agent 查询成功产物
-> Agent 调用受控部署脚本
-> 调试机验证
```

现在至少解决了三个问题：

1. Agent 不再靠猜 registry tag 判断构建结果。
2. 构建上报失败不会拖垮原来的构建流程。
3. 调试机部署有了固定入口，既能自动跑，也方便人审计。

## 还没做的事

这还不是完整发布系统。当前只适合调试机闭环，不适合生产发布。

后面可以继续补：

- 失败构建的日志链接上报。
- 部署后的更完整健康检查。
- digest 校验。
- token 从脚本默认值迁到安全配置。
- 部署记录和验证结果也进入同一个控制面。

但这一步已经让 Agent 从“只能改代码”往前走了一段：它现在能等构建、拿镜像、部署调试机，并继续进入日志排查。对日常开发来说，这比一开始就设计完整发布平台更有用。
