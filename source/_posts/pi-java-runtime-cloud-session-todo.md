---
title: "Pi Java Runtime 的云端会话恢复 TODO"
date: 2026-08-07 15:44:06
categories:
  - "AI"
tags:
  - "AI TODO"
  - "会话持久化"
  - "多租户"
  - "AI工作日志"
source_archive:
  id: 20260807-pi-java-runtime-cloud-session-todo
  rel_path: source_materials/posts/20260807-pi-java-runtime-cloud-session-todo
  conversation_file: conversation.jsonl
---

Pi Java Runtime 目前把 Pi 的 `AgentSession` 写到本地 JSONL，再把原始 Entry 镜像到 Java 数据库。这个实现足以支持单机运行和管理台回放，但不适合作为云端部署后的会话恢复方案。

核心问题很直接：Runtime 续聊时仍从本机 `sessions/*.jsonl` 打开会话。如果实例重启、容器迁移或扩容到另一台机器，数据库虽然还保留管理台记录，Agent 却没有可恢复的上下文。

这篇记录当前实现的边界，以及后续要补的云端会话恢复 TODO。

## 当前链路：JSONL 是运行真相，数据库是查询索引

现在每个会话都有一个本地 JSONL 文件。文件里保存 Pi 的原生 Session Entry：用户消息、助手消息、工具调用、工具结果、模型切换、压缩记录以及自定义上下文。

Java 侧保存两类数据：

- 会话元数据：会话 ID、租户、用户、标题、创建时间。
- 原生 Entry：每条 Pi Entry 单独存储，保留原始 JSON，用于管理台的列表、timeline、turn events 和 event detail。

这两份数据内容相近，但职责不同：

```text
本地 JSONL  ->  Pi SessionManager 恢复上下文并续聊
Java Entry  ->  管理台查询、筛选和回放
```

因此数据库中的历史记录即使完整，本地 JSONL 消失后，当前 Runtime 仍无法继续同一会话。

## 多租户隔离现在做到哪里了

新会话创建时，Runtime 会将 `tenantId` 和 `userId` 写入本地会话的自定义 Entry。续聊时，它会校验本次 Java 签名上下文与该 Entry 是否一致；不一致就拒绝访问。

这能保护“本机仍有 JSONL”的续聊路径，但它不是云端恢复的完整授权模型。原因是恢复源仍在本机，数据库查询虽然已有会话归属字段，Runtime 却没有以 `(conversationId, tenantId, userId)` 从数据库加载上下文。

管理台也属于另一条路径：管理员在具备权限时可以查询会话，而普通用户续聊必须严格限制到自己的租户和用户范围。两者不能共用一个无 owner 条件的读取接口。

## 云端部署前要完成的改造

目标是把数据库升级为会话的唯一持久化真相源，JSONL 仅作为运行节点上的可丢弃缓存。

### 1. 提供带归属校验的会话快照接口

Java 接口按以下条件读取会话：

```text
conversationId + tenantId + userId
```

归属不匹配时直接返回 403。接口返回会话元数据和按顺序排列的原始 Pi Entry；不能先按会话 ID 取数据，再由 Runtime 自己判断归属。

### 2. 用数据库 Entry 重建 Pi Session

Runtime 收到续聊请求后，先从 Java 获取会话快照，再将其物化为临时 JSONL 缓存，复用 Pi 的 `SessionManager` 恢复上下文。

这样不需要重写 Pi 的 Agent loop，也不把 Java 变成另一套消息解释器。缓存丢失时重新物化即可。

### 3. 把写库变成完成条件

当前 Entry 镜像可以失败后重试，这适合本地开发阶段，但不满足云端持久化保证。云端模式下，一轮会话的最终状态必须在数据库确认写入后才算完成。

Entry ID 继续作为幂等键：网络重试、进程重启和重复提交都不应生成重复记录。

### 4. 用跨实例测试验证，而不是只测刷新

至少需要覆盖以下场景：

- A 实例创建会话，B 实例续聊。
- 本地缓存删除后，仍能从数据库恢复。
- 同一租户的不同用户不能互相续聊。
- 不同租户、相同会话 ID 的非法请求被拒绝。
- 工具调用和工具结果恢复后，后续模型调用仍保留正确上下文。

## 当前结论

现在的 Java Entry 表已经能承担管理台索引，但还不能替代 JSONL 恢复 AgentSession。把数据库设为唯一真相源前，不应把本地会话目录当作可随时丢弃的临时文件。

这个改造先作为 AI TODO 保留。后续实现时，优先补齐“带 owner 校验的快照读取 + 临时 JSONL 物化 + 跨实例恢复测试”这条最小闭环，不要先拆重写 Pi 的会话运行时。
