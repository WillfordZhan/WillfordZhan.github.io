---
title: "Pi Skill 的渐进加载：元数据、System Prompt 与正文"
date: 2026-08-07 18:38:53
categories:
  - "AI"
tags:
  - "Pi"
  - "Agent"
  - "Skill"
  - "Java Runtime"
  - "AI工作日志"
source_archive:
  id: 20260807-pi-skill-progressive-loading
  rel_path: source_materials/posts/20260807-pi-skill-progressive-loading
  conversation_file: conversation.jsonl
---

Pi 的 Skill 不是在启动时把所有 `SKILL.md` 正文塞进模型上下文。它采用渐进加载：启动或重载时发现 Skill 并保存元数据，构建 System Prompt 时只向模型展示目录，真正选中某个 Skill 后才读取正文。

理解这三层状态很重要：磁盘上的 Skill、运行时内存里的 Skill 元数据、模型上下文里的 Skill 正文不是同一件事。

## 三个加载时机

完整链路可以压缩成三步：

```text
扫描 SKILL.md
  -> 解析 name / description / location
  -> 写入 System Prompt 的 <available_skills>
  -> 模型选择 Skill
  -> 读取 SKILL.md 正文
  -> 正文进入模型上下文
```

第一步发生在 `DefaultResourceLoader.reload()`。`createAgentSession()` 创建会话前会先执行资源重载，随后 `loadSkills()` 扫描默认目录、项目目录、配置路径和包提供的 Skill。

这一阶段虽然会读取 `SKILL.md` 来解析 frontmatter，但内存中的 `Skill` 对象只保留这些字段：

```ts
interface Skill {
  name: string;
  description: string;
  filePath: string;
  baseDir: string;
  sourceInfo?: ResourceSourceInfo;
  disableModelInvocation: boolean;
}
```

正文没有长期保存在这个对象里。`reload()` 的职责是发现和注册资源，不是扩大模型上下文。

## 元数据如何进入 System Prompt

`AgentSession` 创建运行时并确定 active tools 后，会重建 System Prompt：

```text
_buildRuntime()
  -> _refreshToolRegistry()
  -> setActiveToolsByName()
  -> _rebuildSystemPrompt()
```

`_rebuildSystemPrompt()` 从 ResourceLoader 取得已加载的 Skill，交给 `formatSkillsForPrompt()`，最终生成类似下面的目录：

```xml
<available_skills>
  <skill>
    <name>learn-pi-by-doing</name>
    <description>基于当前工作区源码讲解 Pi 与 Java Runtime</description>
    <location>/path/to/skill/SKILL.md</location>
  </skill>
</available_skills>
```

模型第一次被调用时已经能看到这份目录，但还看不到 Skill 正文。这样做可以让大量 Skill 同时可发现，又不必为没有使用的 Skill 支付上下文成本。

这里还有一个容易忽略的条件：当前实现只有在 active tools 中存在名为 `read` 的工具时，才会把 Skill 目录加入 System Prompt。原因很直接——如果模型没有能力读取目录中的文件，向它展示 Skill 也无法完成后续加载。

## 正文什么时候进入上下文

正文有两条加载路径。

第一条是模型自主选择：

```text
模型读取 available_skills
  -> 根据 description 选择 Skill
  -> 调用 read(location)
  -> SKILL.md 作为 ToolResult 加入会话
  -> 下一次模型调用看到正文
```

这是标准的懒加载路径。Skill 正文通过工具结果进入会话，不会提前占用首次请求的上下文。

第二条是用户显式调用：

```text
/skill:skill-name 参数
  -> _expandSkillCommand()
  -> Pi 直接读取 SKILL.md
  -> 去掉 frontmatter
  -> 把正文和参数放入当前用户消息
```

这条路径不需要模型先从目录中发现 Skill，也不依赖内置 `read`。因此即使 Skill 设置了 `disable-model-invocation: true`，用户仍然可以显式调用它；该配置只控制是否向模型展示。

## `/reload` 改变了什么

修改或新增 Skill 后，`/reload` 会重新执行资源扫描、更新内存中的 Skill 列表，并重建运行时和 System Prompt。新的元数据从下一次模型请求开始生效。

它不会追溯修改已经进入历史消息的 Skill 正文。已经产生的 ToolResult 或展开后的用户消息仍然是当时的内容，这是对话历史不可变带来的自然结果。

另外，Skill 加载存在两个值得排查的边界：

- 缺少 `description` 的 Skill 不会成功注册，因为模型无法据此判断用途。
- 同名 Skill 发生冲突时，按资源优先级保留先加载者，并产生诊断信息，而不是合并两份正文。

## Java Runtime 当前的差异

Java Runtime 的 `openSession()` 每次请求都会新建 `DefaultResourceLoader` 并执行 `reload()`，所以本地 Skill 仍然会被扫描到内存。

但当前 Java Runtime 同时配置了：

```ts
noTools: "builtin"
```

这会禁用 Pi 内置工具，包括 `read`。结合前面的 System Prompt 条件，实际结果是：

- Skill 可以被 ResourceLoader 发现；
- 模型通常看不到 `<available_skills>`；
- 用户显式输入 `/skill:name` 仍可加载正文；
- 如果 Java MCP 提供一个激活且名称为 `read` 的自定义工具，目录才可能重新进入 System Prompt。

因此，给 Java Runtime 接入云端或租户级 Skill，不能只解决“Skill 存在哪里”。运行时还必须明确解决三件事：目录如何注入、正文由谁读取、读取时如何执行租户和权限校验。

## 设计上的边界

Pi 当前的渐进加载把职责分得比较清楚：

- ResourceLoader 负责发现与元数据注册；
- System Prompt 负责让模型发现能力；
- `read` 或 `/skill:name` 负责按需加载正文；
- 会话消息负责保存本次实际使用过的内容。

如果后续把 Skill 改成云端存储，适合保留这条边界。云端列表接口只返回可信元数据，正文读取走独立的鉴权接口，并在读取时校验租户、用户、Skill 版本和授权范围。不要为了接云端存储，直接把所有正文提前拼进 System Prompt。
