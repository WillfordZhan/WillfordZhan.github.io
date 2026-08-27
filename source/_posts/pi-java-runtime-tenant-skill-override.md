---
title: "给 Pi Java Runtime 加一层工厂级 Skill Override"
date: 2026-08-27 14:26:11
categories:
  - "AI"
tags:
  - "Pi"
  - "Java Runtime"
  - "Agent"
  - "Skill"
  - "多租户"
  - "MCP"
  - "AI工作日志"
source_archive:
  id: 20260827-pi-tenant-skill-override
  rel_path: source_materials/posts/20260827-pi-tenant-skill-override
  conversation_file: conversation.jsonl
---

我们的铁水批次计划已经不适合继续共用一份 Skill。A 工厂创建计划时只需要写计划数据，B 工厂还要创建配方和产品，两个工厂使用同一个业务名称，执行步骤却完全不同。

Tool 暂时没有租户差异，所有工厂仍可调用同一批 Java MCP Tool。变化集中在流程编排：模型处理“创建计划”时，需要先加载当前工厂对应的 Skill，再按正文决定调用哪些 Tool、按什么顺序调用。

这版设计保留 Pi 的渐进加载思路，把 Skill 的目录、正文和版本控制搬到 Java 云端。运行时只增加两项能力：`Agent Profile API` 和 `load_skill`。

> 当前内容是设计方案，代码尚未落地。

## 当前链路留下的限制

Pi 原生 Skill 从本地 `SKILL.md` 开始。`DefaultResourceLoader` 扫描文件并解析 `name`、`description`、`location`，`AgentSession` 将这些元数据写入 System Prompt。模型匹配到 Skill 后，再调用 `read` 获取正文。

Java Runtime 的配置有一处差异：

```ts
createAgentSession({
  resourceLoader,
  customTools,
  noTools: "builtin",
});
```

`noTools: "builtin"` 关闭了通用的 `read`、`bash`、`edit` 和 `write`。本地 Skill 即使被 Resource Loader 扫描到，模型也缺少标准的正文加载路径。恢复通用 `read` 会扩大服务端文件读取范围，把所有正文直接塞进 System Prompt 又会破坏渐进加载。

Java Runtime 也没有使用 `packages/agent` 里的 Harness Skill Loader。当前入口直接创建 `coding-agent` 的 `AgentSession`。为了云端 Skill 再切换一套 Harness，会同时改动会话、工具和资源加载边界，接入成本超出了这次需求。

因此我们不改 Pi 的本地 Skill 引擎。Java Runtime 只复用它已经具备的两个机制：System Prompt 扩展和自定义 Tool。

## 两条运行时能力

### Agent Profile API：返回最终有效目录

`PiConversationRuntime.openSession()` 使用可信的调用人上下文请求 Java。Java 根据 `tenantId` 计算当前工厂可见的 Skill，响应只保留模型发现能力所需的字段：

```json
{
  "skills": [
    {
      "name": "create_furnace_plan",
      "description": "创建铁水批次计划"
    }
  ]
}
```

Profile 不返回公共或私有来源，也不返回 `profileVersion`、`schemaVersion`、`contentDigest` 和文件地址。公共 Skill 与工厂 Skill 的合并已经在 Java 完成，Pi 拿到的是最终目录。

Pi 将目录写入 System Prompt：

```xml
<available_skills>
  <skill>
    <name>create_furnace_plan</name>
    <description>创建铁水批次计划</description>
  </skill>
</available_skills>
```

加载说明随目录一起注入：任务与描述匹配时，模型调用 `load_skill`，不读取本地路径。

### load_skill：按名称加载正文

模型只提交 Skill 名称：

```json
{
  "name": "create_furnace_plan"
}
```

`tenantId` 和 `userId` 不进入 Tool Schema。Pi 当前的 Java MCP 适配层在执行 Tool 时已经会自动注入调用人上下文，并通过 `/tools/call` 发送给 Java。模型无法修改租户范围。

`load_skill` 可以直接注册成一个普通 Java MCP Tool。这样不需要增加专用的 Skill HTTP Client，也不需要重新实现 Tool 生命周期：

```text
模型调用 load_skill(name)
  -> Pi JavaMcpClient 注入 tenantId / userId
  -> POST /tools/call
  -> Java MCP Dispatcher
  -> Skill 服务解析当前 Snapshot
  -> 正文作为 Tool Result 返回模型
```

逻辑上仍然只有 `Agent Profile API` 和 `load_skill` 两项能力；网络层只有 Agent Profile 需要新增入口，`load_skill` 复用已有的 MCP Tool Call。

加载结果保留当前 Skill 版本，方便日志和历史会话追溯：

```json
{
  "name": "create_furnace_plan",
  "skillVersion": 3,
  "content": "创建计划前先检查产品；缺少配方时先创建配方……"
}
```

`skillVersion` 由 Java 返回，模型不提交版本，也不负责选择版本。

## 同名 Skill 如何覆盖

Java 同时维护公共目录和工厂目录，按 `skill_name` 合并：

```text
公共 Skill
  + 当前 tenantId 的 Skill
  -> 同名时保留工厂版本
  -> 得到 Agent Profile
```

正文加载使用相同的解析规则：

```text
tenantId + skillName
  -> 查询工厂 skill_current
  -> 工厂未配置时查询公共 skill_current
  -> 根据 snapshot_id 读取正文
```

Profile 与 `load_skill` 应共用一个 Java Skill Service。目录和正文各写一套覆盖逻辑，很容易出现“目录显示工厂版，正文却加载公共版”的分叉。

## Snapshot 保存历史，Current 决定生效版本

Skill 正文只有一两千字，数据库 `TEXT` 已经够用，第一版不接 OSS。

历史记录拆成两张表：

```text
skill_snapshot
  id
  tenant_id
  skill_name
  skill_version
  description
  content
  created_by
  created_at

skill_current
  tenant_id
  skill_name
  snapshot_id
  updated_by
  updated_at
```

`skill_snapshot` 不可变。一次修改对应一条新 Snapshot，旧正文继续保留。`skill_current` 只保存当前指针。

发布新版本需要在同一事务中完成两步：

1. 插入新的 `skill_snapshot`。
2. 将 `skill_current.snapshot_id` 指向新记录。

回滚不复制正文，也不覆盖历史记录。管理端把 Current 指针切回旧 Snapshot 即可。

`skillVersion` 属于 Snapshot。Profile 不依赖它，Pi 也不保存 Profile Snapshot。版本信息出现在加载结果和 Java 审计日志中已经能够完成追溯。

## 会话不锁定 Skill 版本

当前设计不把 Skill 版本固定到整个会话。

一次 `load_skill` 返回的正文会作为 Tool Result 写入会话历史。运行时不会改写这条历史消息。模型后续再次调用相同 Skill 时，Java 重新读取 `skill_current`，因此可能拿到更新后的 Snapshot。

这会产生一个明确的时间边界：旧 Tool Result 保留旧正文，新调用拿当前正文。第一版不增加版本检测、Profile 快照和会话级绑定。

Java Runtime 目前还会在用户每发一条消息时重新创建 `AgentSession`，并从 JSONL 恢复历史。Agent Profile 放进 `openSession()` 后也会按消息请求。这里存在重复加载成本，但不影响 Skill 解析的正确性。会话级 `AgentSession` 缓存作为后续独立优化处理，不和第一版云端 Skill 混在一起。

## 失败边界

这套流程会参与 ERP 写操作，失败时不能绕过 Skill 继续执行。第一版按下面的边界处理：

- Agent Profile 请求失败：终止本轮请求，不返回空目录继续运行。
- 工厂没有覆盖版本：回退公共 Skill。
- 工厂 Current 存在，但 Snapshot 丢失或损坏：返回错误，不静默切换公共正文。
- Skill 名称不在最终目录：`load_skill` 返回明确的 Tool Error。
- `tenantId` 只接受可信运行时上下文，不接受模型参数。

公共 Skill 的数据库表示还需要和现有租户规则拉通。第一版倾向用保留值表示公共范围，例如 `tenant_id = 0`，前提是 `0` 永远不是有效工厂 ID。

现有 MyBatis 租户拦截器会自动追加当前租户条件。Skill 查询需要同时读取当前工厂和公共范围，因此这两张表要绕过自动拦截，由 Skill Service 显式执行受控查询。这里属于租户安全边界，不能靠普通 Mapper 的默认行为碰运气。

## 第一版的改动范围

Pi Java Runtime：

- `openSession()` 请求 Agent Profile。
- 将 `name`、`description` 和远程加载说明加入 System Prompt。
- 继续使用现有 `JavaMcpClient.createTools()`，不新建 Skill Tool 适配器。

Java：

- 增加 `skill_snapshot` 和 `skill_current`。
- 增加统一的租户 Skill 解析服务。
- 增加 Agent Profile 内部接口。
- 将 `load_skill` 注册到现有 Java MCP Tool Registry。
- 增加 Snapshot 发布、历史查询和 Current 回滚能力。

第一版不处理 `/skill:name`、TUI、Tool Search、角色级 Tool List、OSS、Profile 持久化和会话版本锁定。工具数量增长后的渐进披露属于另一条链路，继续复用 Pi 的 Active Tools 能力即可。

这层适配把租户、版本和回滚留在 Java，把能力发现和 Agent Loop 留在 Pi。新增的长期维护面集中在两张表、一个解析服务和一段目录注入逻辑，足以支撑同名 Skill 的工厂级覆盖。
