---
title: "回顾 Pi 原生 Skill 机制，以及我们在 Java Runtime 中的选择"
date: 2026-08-13 18:42:15
categories:
  - "AI"
tags:
  - "Pi"
  - "Skill"
  - "Java Runtime"
  - "Agent"
  - "AI工作日志"
source_archive:
  id: 20260813-pi-native-skill-runtime-choice
  rel_path: source_materials/posts/20260813-pi-native-skill-runtime-choice
  conversation_file: conversation.jsonl
---

这次给 Java Runtime 接入仓管 Skill，我先重新梳理了 Pi 原生的 Skill 链路。

Pi 已经提供了四项可以直接组合的能力：

1. Skill 自动发现
2. `noSkills`
3. `additionalSkillPaths`
4. Skill 元数据注入与正文按需加载

我们最终选择保留这套原生链路：

```text
noSkills
  + additionalSkillPaths
  + 自定义受限 read
```

Runtime 不再扫描用户目录和工作目录，只加载随 Runtime 发布的 Skill。模型仍然通过 Pi 原生元数据识别 Skill，再按需读取对应的 `SKILL.md`。

## 一、Skill 自动发现

Pi 的 Skill 加载入口是 `DefaultResourceLoader.reload()`。

它先调用 `DefaultPackageManager.resolve()`，收集当前会话允许使用的资源。Skill 来源包括：

- 项目配置中声明的 Skill
- 用户配置中声明的 Skill
- 已安装 Package 提供的 Skill
- 项目目录自动发现的 Skill
- 用户目录自动发现的 Skill
- 通过参数显式传入的 Skill

默认自动发现目录主要有四类：

```text
<cwd>/.pi/skills
<cwd 或上级目录>/.agents/skills
<agentDir>/skills
~/.agents/skills
```

项目级目录受 Project Trust 控制。项目未被信任时，Pi 不会自动加载项目里的 `.pi/skills` 和 `.agents/skills`。

用户级 Skill 不依赖当前项目的信任状态。

### `.pi/skills` 和 `.agents/skills` 的发现方式

Pi 会递归扫描 Skill 目录。

目录中存在 `SKILL.md` 时，该目录成为一个完整的 Skill 根目录。扫描在这里停止，不再把其子目录识别为其他 Skill。

典型结构如下：

```text
skills/
└── warehouse-manager/
    └── SKILL.md
```

`.pi/skills` 还兼容直接放置 Markdown 文件：

```text
.pi/skills/
├── warehouse-manager.md
└── purchase-manager.md
```

扫描过程会跳过：

- 隐藏目录
- `node_modules`
- 被 `.gitignore`、`.ignore` 或 `.fdignore` 排除的文件

符号链接可以被跟随，但 Pi 会对最终真实路径去重。同一个文件通过多个路径被发现时，只保留一份。

### 从文件到 Skill 对象

发现 `SKILL.md` 后，Pi 会读取 YAML frontmatter：

```yaml
---
name: warehouse-manager
description: 处理仓库入库、出库单据创建和库存校验流程。
---
```

随后生成一个 `Skill` 对象：

```ts
interface Skill {
  name: string;
  description: string;
  filePath: string;
  baseDir: string;
  sourceInfo: SourceInfo;
  disableModelInvocation: boolean;
}
```

各字段职责如下：

- `name`：Skill 唯一名称
- `description`：模型判断是否需要使用 Skill 的主要证据
- `filePath`：`SKILL.md` 的实际位置
- `baseDir`：Skill 内相对引用的解析目录
- `sourceInfo`：Skill 来自用户、项目、Package 或显式路径
- `disableModelInvocation`：是否禁止模型自动调用

缺少 `description` 的 Skill 不会被加载。名称格式存在问题时会产生诊断信息。

同名 Skill 发生冲突时，先进入 Skill 集合的版本保留，后续版本记入 collision diagnostic。

## 二、noSkills

`noSkills` 用于关闭默认 Skill 发现。

CLI 中对应：

```bash
pi --no-skills
pi -ns
```

SDK 中对应：

```ts
const loader = new DefaultResourceLoader({
  cwd,
  agentDir,
  noSkills: true,
});
```

ResourceLoader 组装 Skill 路径时，逻辑可以简化为：

```ts
const skillPaths = noSkills
  ? merge(cliSkills, additionalSkillPaths)
  : merge(cliSkills, discoveredSkills, additionalSkillPaths);
```

`noSkills: true` 关闭以下来源：

- 项目目录自动发现
- 用户目录自动发现
- 项目和用户配置中的默认 Skill
- Package 解析得到的默认 Skill

它仍然保留两类显式输入：

- CLI 的 `--skill`
- SDK 的 `additionalSkillPaths`

所以 `noSkills` 的准确语义是“关闭默认发现集合”，显式授权的 Skill 仍然可以加载。

这个行为给 Runtime 提供了一个清晰的安全边界：服务端不接受运行环境自动发现出来的 Skill，只接受部署时明确指定的 Skill。

## 三、additionalSkillPaths

`additionalSkillPaths` 用来向 ResourceLoader 显式提供 Skill 文件或目录。

```ts
const loader = new DefaultResourceLoader({
  cwd,
  agentDir,
  additionalSkillPaths: [
    "/opt/runtime-skills",
  ],
});
```

它可以指向：

- 单个 `SKILL.md`
- 单个 Markdown Skill
- 包含多个 Skill 的目录

CLI 的对应能力是：

```bash
pi --skill /opt/runtime-skills
```

`additionalSkillPaths` 会和其他 Skill 来源合并。配合 `noSkills: true` 时，它会成为主要甚至唯一的 Skill 来源：

```ts
const loader = new DefaultResourceLoader({
  cwd,
  agentDir,
  noSkills: true,
  additionalSkillPaths: [
    "/opt/runtime-skills",
  ],
});
```

最终效果是：

```text
项目 Skill         不扫描
用户 Skill         不扫描
Package Skill      不加载
显式 Runtime Skill 加载
```

Pi 后续的 Skill 解析、冲突检测、元数据生成和 AgentSession 集成都保持不变。

## 四、元数据注入与正文按需加载

Pi 在发现阶段需要读取 `SKILL.md`，因为它必须解析 frontmatter。

这次读取发生在 Runtime 内部。完整正文还没有发送给模型。

### 第一层：Skill 元数据进入 system prompt

`AgentSession` 重建 system prompt 时，会调用：

```ts
resourceLoader.getSkills()
```

然后把允许模型自动调用的 Skill 格式化为：

```xml
<available_skills>
  <skill>
    <name>warehouse-manager</name>
    <description>
      处理仓库入库、出库单据创建和库存校验流程。
    </description>
    <location>
      /opt/runtime-skills/warehouse-manager/SKILL.md
    </location>
  </skill>
</available_skills>
```

这一步进入上下文的内容只有：

- `name`
- `description`
- `location`

`SKILL.md` 正文暂时不进入上下文。

这就是 Pi 的渐进加载机制。每个 Skill 固定占用少量元数据 Token，只有匹配当前请求的 Skill 才加载完整正文。

### 第二层：模型判断是否使用 Skill

模型拿到用户请求后，通过 `description` 判断相关性。

例如：

```text
用户：帮我创建一张产品出库单
```

模型看到 `warehouse-manager` 的描述后，判断当前任务属于仓库单据流程。

随后调用：

```text
read(
  path="/opt/runtime-skills/warehouse-manager/SKILL.md"
)
```

工具返回正文后，Skill 中定义的业务规则才进入当前 Agent loop。

完整链路如下：

```text
ResourceLoader 发现 Skill
  -> 解析 frontmatter
  -> 生成 Skill 元数据
  -> AgentSession 构建 system prompt
  -> 模型读取 available_skills
  -> 模型根据 description 匹配
  -> 调用 read 读取 SKILL.md
  -> 按 Skill 正文调用业务 Tool
```

### read 是原生链路中的必要条件

Pi 构建 system prompt 时会检查当前活动工具中是否存在名为 `read` 的工具。

存在 `read`：

```text
Skill 元数据写入 system prompt
```

不存在 `read`：

```text
不写入 available_skills
```

这个判断有明确的上下文：模型收到 Skill 的路径后，需要有能力读取对应文件。缺少读取能力时，单独暴露元数据无法完成后续加载。

### 显式调用是另一条链路

Pi 还支持：

```text
/skill:warehouse-manager
```

AgentSession 会在处理消息前查找对应 Skill，直接读取文件、去掉 frontmatter，并把正文展开到用户消息中。

这条路径不需要模型先判断，也不依赖模型主动调用 `read`：

```text
用户输入 /skill:name
  -> AgentSession 查找 Skill
  -> Runtime 读取 SKILL.md
  -> 正文展开到当前消息
  -> 模型直接执行 Skill
```

它适合用户明确指定 Skill。自然语言自动触发仍然依赖 `<available_skills>` 和 `read`。

## 五、我们在 Java Runtime 中的选择

我们的 Java Runtime 已经关闭 Pi 内置工具：

```ts
createAgentSession({
  customTools,
  noTools: "builtin",
});
```

这个配置关闭了内置的：

- `read`
- `bash`
- `edit`
- `write`

Java MCP 提供的自定义 Tool 仍然可用。

关闭内置 `read` 后，模型无法读取 Runtime 文件系统。这满足服务端最小权限要求，但 Pi 也不会把 Skill 元数据写入 system prompt，自然语言无法自动触发 Skill。

### 方案一：恢复内置 read

这条路改动少，但读取范围过大。

模型除了能读取 `SKILL.md`，也可能读取：

- Runtime 配置
- 工作目录文件
- 挂载卷内容
- 会话文件
- 其他租户遗留文件

服务端环境不适合开放这种权限。

### 方案二：把 Skill 正文直接拼进 system prompt

这条路不需要 `read`。

代价也很明确：

- 每次请求都携带完整 Skill
- Skill 增加后上下文持续膨胀
- 无关业务规则进入每轮推理
- 偏离 Pi 原生渐进加载方式

第一版只有一个仓管 Skill 时可以工作，后续继续增加采购、生产、质检 Skill 后，维护成本会上升。

### 方案三：noSkills + additionalSkillPaths + 受限 read

我们最终选择这一版：

```ts
const resourceLoader = new DefaultResourceLoader({
  cwd,
  agentDir,
  noSkills: true,
  additionalSkillPaths: [
    runtimeBundledSkillsDirectory,
  ],
});

const { session } = await createAgentSession({
  resourceLoader,
  customTools: [
    ...javaMcpTools,
    restrictedSkillReadTool,
  ],
  noTools: "builtin",
});
```

三个部分各自承担一个职责。

#### noSkills

关闭项目目录、用户目录和默认 Package Skill 的自动发现。

Runtime 不会因为挂载目录里多了一个 Markdown 文件，就把它暴露给所有会话。

#### additionalSkillPaths

只加载随 Java Runtime 构建和发布的 Skill 目录。

第一版仓管 Skill 跟随 Runtime 镜像交付，所有租户使用同一份业务流程规则。Skill 文件中不保存租户数据。

#### 受限 read

注册一个名称仍为 `read` 的自定义 Tool，让 Pi 保留原生 Skill 元数据注入逻辑。

它只允许读取当前 ResourceLoader 已登记的 `SKILL.md`：

```text
模型提交路径
  -> 解析真实路径
  -> 检查当前会话 Skill 白名单
  -> 完全匹配：读取
  -> 未匹配：拒绝
```

白名单应使用规范化后的真实路径，防止：

- `../` 路径穿越
- 符号链接跳出 Skill 目录
- 伪造相似路径
- 读取 Skill 目录之外的文件

第一版 Skill 只有一个 `SKILL.md`，因此读取权限可以精确到文件，不需要开放整个 Skill 目录。

## 六、这次选择保留了什么，又限制了什么

保留的 Pi 原生能力：

- Skill 资源模型
- frontmatter 解析
- Skill 诊断
- 元数据注入
- description 自动匹配
- 正文渐进加载
- `/skill:name` 显式调用
- AgentSession 原生 Tool loop

Java Runtime 增加的边界：

- 默认 Skill 发现关闭
- Skill 来源由 Runtime 明确指定
- 内置通用 `read` 继续关闭
- 自定义 `read` 只能读取会话授权的 `SKILL.md`
- Skill 不携带租户业务数据

暂未引入：

- 云端 Skill 存储
- 租户自定义 Skill
- Skill 版本管理
- Skill 审核和发布状态
- 对象存储读取
- 动态 Skill 缓存

这些能力等租户自定义 Skill 进入实际需求后再增加。当前本地 Skill 随 Runtime 发布，一套白名单已经覆盖第一版需求。

## 源码阅读顺序

这次理解 Pi Skill，可以按下面的顺序读：

1. `packages/coding-agent/src/core/package-manager.ts`
   - Skill 从哪里被发现
   - 项目和用户资源如何合并
   - Project Trust 如何影响项目 Skill

2. `packages/coding-agent/src/core/resource-loader.ts`
   - `noSkills` 和 `additionalSkillPaths` 如何组合
   - Skill 路径何时交给加载器

3. `packages/coding-agent/src/core/skills.ts`
   - `SKILL.md` 如何解析
   - Skill 如何去重和处理名称冲突
   - `<available_skills>` 如何生成

4. `packages/coding-agent/src/core/system-prompt.ts`
   - Skill 元数据何时进入 system prompt
   - `read` 为什么影响 Skill 元数据注入

5. `packages/coding-agent/src/core/agent-session.ts`
   - ResourceLoader 的结果如何进入 AgentSession
   - `/skill:name` 如何直接展开 Skill 正文

6. `packages/java-agent-runtime/src/runtime.ts`
   - Java Runtime 如何创建 ResourceLoader
   - Java MCP Tool 和 Pi AgentSession 如何组合
   - 我们的受限 Skill 加载方案应落在哪里
