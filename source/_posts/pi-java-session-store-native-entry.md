---
title: "从 Pi JSONL 到 Java Session Store：保留原生 Session Entry，只替换存储"
date: 2026-08-18 15:38:23
categories:
  - "AI"
tags:
  - "Pi"
  - "Agent"
  - "Session Store"
  - "Java"
  - "AI工作日志"
source_archive:
  id: "20260818-pi-java-session-store"
  rel_path: "source_materials/posts/20260818-pi-java-session-store"
  conversation_file: "conversation.jsonl"
---

这次 Java Runtime 的会话迁移里，最容易混淆的是 Entry 名字。管理台里曾经出现过 `final`、`tool_call`、`tool_result`，本地会话里又有若干业务自定义 Entry。它们看起来都像“会话事件”，实际分属不同层次。

Java Runtime 现在不再创建本地会话文件。它直接把 Java Session Store 接到了 Pi 的 `SessionRepository` / `SessionStorage` 接口上。Pi 仍然负责 Entry 语义、会话树和模型上下文，Java 数据库负责持久化、会话归属和 Head 推进。

这个结论需要从 Entry 的分层说起。

## `final` 不是 Pi SessionEntry

当前 Pi AgentHarness 的顶层 `SessionTreeEntry` 有这些类型：

| 类别 | 原生 Entry 类型 | 用途 |
| --- | --- | --- |
| 对话消息 | `message` | 保存 user、assistant、toolResult 等消息 |
| 运行配置 | `thinking_level_change`、`model_change`、`active_tools_change` | 记录当前推理级别、模型和活动工具 |
| 上下文整理 | `compaction`、`branch_summary` | 保存压缩和分支摘要 |
| 扩展数据 | `custom`、`custom_message` | 保存扩展状态，或向模型上下文注入扩展消息 |
| 导航与元数据 | `label`、`session_info`、`leaf` | 标签、会话名称和活动分支切换 |

这份列表以迁移完成后的当前 AgentHarness 为准。旧 Runtime 使用的 coding-agent `SessionManager` 版本只有其中九类，尚未包含 `active_tools_change` 和 `leaf`。这两个类型来自 Pi 会话模型后续演进，也不属于 Java Runtime 自定义事件。

JSONL 文件第一行的 `session` 是文件 Header，不属于这组会话树 Entry。

`message` 里面还有第二层类型。最终回答、工具调用和工具结果都在这里表达：

```ts
type SessionMessageEntry = {
  type: "message";
  id: string;
  parentId: string | null;
  timestamp: string;
  message: AgentMessage;
};
```

一条最终回答使用 `message.role = "assistant"`。模型发起工具调用时，`assistant` 消息的 `content` 中包含 `toolCall` 块。工具执行完以后，Pi 再写入一条 `message.role = "toolResult"` 的 Entry。

因此，这里至少有三层容易混用的类型：

| 层次 | 示例 | 是否为会话树节点 |
| --- | --- | --- |
| SessionEntry 类型 | `message`、`compaction`、`custom` | 是 |
| AgentMessage 角色或内容块 | `assistant`、`toolResult`、`toolCall` | 随 `message` Entry 保存 |
| 对外事件或管理台投影 | `final`、`tool_call`、`tool_result` | 否，由原生 Entry 投影得到 |

旧 Python 编排器把单轮结果建模为 `TurnResult.status = "final"`，随后写入同名历史事件并发送 SSE。`final` 表示一轮执行已经收敛，属于编排和传输协议。它没有进入 Pi 的原生 `SessionEntry` 联合类型。

当前管理台里的 `tool_call`、`tool_result` 也遵循同一原则。投影层扫描原生 `message` Entry：从 assistant 内容块展开工具调用，从 toolResult 消息生成工具结果，再把 assistant 文本映射成 `assistant_message`。展示模型可以演进，存储模型不需要跟着增加一批平行类型。

## 自定义 Entry 的“自定义”发生在哪里

Pi 原生提供了 `custom`：

```ts
type CustomEntry = {
  type: "custom";
  customType: string;
  data?: unknown;
};
```

`type: "custom"` 由 Pi 定义，具体的 `customType` 和 `data` 由 Runtime 或扩展定义。`custom` 默认不进入模型上下文，适合保存扩展状态。需要进入上下文的内容可以使用 `custom_message`，也可以由 AgentHarness 的 Entry Projector 做受控投影。

旧 Java Runtime 曾经写过四类代表性的 `customType`：

- 会话 Owner 快照；
- 可信业务上下文；
- 工具展示文案目录；
- Java 镜像同步位置。

这些条目的容器是 Pi 原生类型，数据语义来自我们的 Runtime。它们也不具有相同的保留价值。

可信业务上下文属于需要跨轮恢复的领域状态，继续保存为 `custom` 很合适。展示文案属于 ToolResult 的展示细节，同步位置属于旧双写协议。后两者进入会话树以后，会参与 `id`、`parentId` 链，基础设施状态便开始影响对话树结构。

## 旧链路：本地 JSONL 是真相源，Java 是镜像

迁移前的写入链路如下：

```text
AgentSession
    │
    ▼
SessionManager
    │  先追加
    ▼
本地 JSONL
    │  每轮结束后查找同步标记，发送增量
    ▼
Java Entry 镜像
```

`AgentSession` 始终通过 `SessionManager` 打开和追加本地 JSONL。每轮结束后，Runtime 读取当前 Entry 数组，从最后一个同步标记开始计算待发送增量。Java 依靠 `conversationId + entryId` 唯一约束处理重放，确认成功后，Runtime 再向本地会话追加一个同步标记。

本地文件丢失时，恢复方向会反过来：

```text
Java Entry 镜像
    │  下载、校验并修复父节点缺口
    ▼
合成当前版本的 JSONL Header
    │
    ▼
重新写出本地 JSONL
    │
    ▼
SessionManager.open(...)
```

恢复完成以后，AgentSession 仍然只操作本地文件。Java 提供了一次性恢复数据，还没有成为 Pi Session 接口下的持久化实现。

这套链路有几个具体负担：

- 同步标记自身是树节点，下一条 Entry 的 `parentId` 会引用它；早期镜像遗漏标记后，恢复代码还要合成节点修补父链。
- 图片完整保存在本地 JSONL，Java 镜像只保存文字占位。两边的数据天然不对称。
- 本地会话卷影响续聊可用性；Java 数据完整也要先重建文件才能继续运行。
- Runtime 同时维护 Pi 文件协议、增量同步协议和恢复协议。

Java 数据库当时承担的是管理查询和恢复镜像。把唯一约束再做得更严，只能改善重放，无法消除这三套协议。

## 新链路：把 Java 接到 Pi 的存储端口

AgentHarness 把会话领域逻辑放在 `Session`，把持久化拆成两个接口：

```ts
interface SessionStorage {
  readHead(): Promise<{ leafId: string | null }>;
  readEntries(...): Promise<readonly SessionTreeEntry[]>;
  appendEntry(entry: SessionTreeEntry): Promise<void>;
  // 分支、路径、标签、统计等读取能力
}

interface SessionRepository {
  create(...): Promise<Session>;
  openById(id: string): Promise<Session>;
  list(): Promise<SessionMetadata[]>;
  delete(...): Promise<void>;
  fork(...): Promise<Session>;
}
```

Pi 自带的 `JsonlSessionRepository` 是其中一个实现。它把 Session Header 和原生 Entry 逐行写入文件。Java Runtime 新增的是另一套实现：

```text
AgentHarness
    │
    ▼
Session
    │  生成 id、parentId、timestamp，并串行追加
    ▼
JavaSessionStorage
    │
    ▼
Java Session API
    │  同一事务内写 Entry、校验 Head、推进 Head
    ▼
Java DB
```

Runtime 创建或续聊时实例化一个绑定当前租户和用户的 Java Repository，再调用 `create()` 或 `openById()`。创建 AgentHarness 时传入返回的原生 `Session`。这条路径没有实例化 `JsonlSessionRepository`，也没有调用文件版 `SessionManager`。

所以“停用本地文件”和“接入 Java Session Store”在 Java Runtime 里是同一项改造：本地 JSONL 退出这条运行链路，Java 实现直接挂到 Pi 的 Repository/Storage 端口。Pi CLI 等其他入口仍然可以选择 `JsonlSessionRepository`，全局的 JSONL 能力没有被删除。

## 打开和追加时具体发生什么

打开会话时，Java 返回两部分数据：

1. Session 元数据，包括 Owner、创建时间和当前活动 Head；
2. 按追加顺序保存的完整原生 Entry JSON。

Runtime 用这些 Entry 建立 `ArraySessionIndex`。这个对象只服务当前打开的 Session，在内存中提供按 ID 查找、分支回溯、上下文路径、标签和统计。进程退出后它不会留下持久化数据。

初始化完成前还会做一次一致性检查：内存索引计算出的 leaf 必须等于 Java 元数据中的活动 Head。两者不一致时拒绝继续追加，避免在错误父节点上延长会话树。

追加顺序也有明确边界：

```text
Session 生成下一条原生 Entry
        │
        ▼
Java 事务：Owner 校验 → 幂等检查 → expectedHead 校验
        │
        ▼
插入原始 Entry JSON → 推进 activeHead
        │
        ▼
Java 返回成功 → Runtime 更新 ArraySessionIndex
```

Java 写入失败时，本地索引不会前进。相同 `entryId` 的重试会先做幂等比较；Head 已被其他写入推进时返回冲突。`leaf` 是一个特殊导航 Entry，它的语义 Head 指向 `targetId`，Java 只为这个原生规则做最小解释。

Java 保存的是完整 Entry JSON，同时抽取 `entryId`、`parentId`、`type` 和数据库顺序列用于约束与查询。模型上下文仍由 Pi 的 `Session.buildContext()` 重建，Java 不再维护另一套 user、assistant、tool event 上下文规则。

## 多租户边界也随 Repository 收紧

每个 Java Repository 实例绑定一个可信的 tenant/user 调用上下文。创建、打开、列举、追加、分叉和删除都携带相同 Owner，Java 查询也把 Session ID 与 Owner 一起作为条件。

这比按租户划分本地目录更直接。会话归属保存在 Session 元数据中，Entry 和 Head 更新落在同一个数据库事务里。跨租户请求统一返回未找到，避免利用状态码枚举其他租户的会话 ID。

## 复杂度转移到了哪里

本地 JSONL 写入很便宜，远程 Session Store 会把网络和数据库放进 Entry 追加的关键路径。当前实现每条 Entry 都需要一次远程写入；打开会话时还会加载完整 Entry 列表。长会话增多以后，需要根据实际延迟和数据量评估分页、快照或压缩，当前没有提前增加这些机制。

Java Store 还要无损保存 Pi 新增的 Entry 类型，并维护 Head 的原生语义。它不负责模型上下文投影，也不复制一套消息状态机，这让耦合范围保持在存储协议内。

这次迁移最终保留了一条清晰边界：Pi 管会话是什么，Java 管会话存在哪里、属于谁、怎样可靠追加。Java Runtime 不再依赖本地会话文件，Pi 的其他运行入口也无需放弃原生 JSONL。
