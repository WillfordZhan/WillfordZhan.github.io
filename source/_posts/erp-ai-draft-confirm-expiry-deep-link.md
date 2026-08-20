---
title: "从 Prepare–Confirm 到 Draft–Confirm：ERP AI 单据的过期、校对与页面回链"
date: 2026-08-20 14:40:30
updated: 2026-08-20 15:36:32
categories:
  - "AI"
tags:
  - "AI Agent"
  - "MCP"
  - "Pi"
  - "Java Runtime"
  - "ERP"
  - "架构设计"
  - "AI工作日志"
source_archive:
  id: 20260820-erp-ai-draft-confirm-routing
  rel_path: source_materials/posts/20260820-erp-ai-draft-confirm-routing
  conversation_file: conversation.jsonl
---

创建一张只有一两行明细的入库单，Agent 生成预览，用户看一眼再确认，`Prepare–Confirm` 已经够用。

文件导入把这个流程推到了另一种规模。一个 Excel 或 PDF 可能包含几十到几百行明细，模型识别出九成字段仍然不够：漏掉的物料、错位的数量和串列的备注都会进入正式单据。聊天里展示一段摘要也接不住逐行校对，用户需要一个可以直接修改的结构化页面。

我们因此准备把已经实现的 `Prepare–Confirm` 升级成 `Draft–Confirm`。同一个 `draftId` 既能直接确认，也能持续修改；默认有效期改为 6 小时；确认成功后，聊天卡片还能跳回 ERP 对应菜单并定位刚创建的单据。

本文记录的是下一阶段设计。当前代码仍使用 `preparationId` 和 15 分钟 Redis TTL，Draft、续期和结构化校对页尚未实现。第一阶段的 Confirm 页面回链已经落地：Java 在确认成功后生成单据引用，Pi 使用原生 ToolResult 保存展示信息，ERP 前端再从当前用户的权限菜单解析路由并定位单据。

## 实施更新：先完成 Confirm 页面回链

这次实现没有同时重写 Draft 状态机，而是先打通一条可独立验收的纵向链路：

```text
Confirm 领域写入成功
  → Java 从创建结果读取 documentKind/documentId/documentNo
  → 按 commandType + documentKind 精确查询模块绑定
  → 生成 presentation.document
  → Pi 合并静态 Tool title，并写入原生 ToolResult.details.presentation
  → 实时 SSE 与历史消息读取同一份 presentation
  → ERP 前端用 documentModuleKey 查询当前用户 permissionList
  → 跳转菜单列表，并按 documentId/documentNo 精确定位
```

Java 只返回稳定单据引用，不返回 URL。模块绑定不存在、查询异常或 presentation 序列化失败时，只降级导航按钮，不能把已经成功落库的 Confirm 改判成失败。重复 Confirm 会从 Redis 恢复第一次生成的 presentation，保证幂等结果不漂移。

Pi Runtime 在 Java MCP 信任边界只接收 `documentModuleKey`、`documentId` 和 `documentNo`，再与工具目录中的静态标题合并。业务 payload 继续提供给模型推理，presentation 只服务 UI；两者没有重新混在同一个返回结构里。

ERP 前端已经覆盖实时卡片和历史会话恢复。点击“前往 ERP 单据”时，页面只信任当前用户权限菜单里的路由；没有对应菜单权限时不跳转。列表页面保持正常 locate 语义，不自动打开只读详情。

DEV 验收结果如下：

- 排除明确要求原始 PDF 的 3 个写入场景后，23 个 E2E case 全部通过；
- 16 个非 PDF Tool 全部至少真实成功调用一次；
- 11 个查询 Tool 均返回统一的 `items/page/total/hasMore`；
- 炉料入库 Confirm 卡片支持实时展示、刷新后的历史恢复和单号精确定位，列表只命中目标单据；
- 浏览器控制台没有 error 或 warning。

这些结果只证明 Confirm 回链与现有 Tool 协议已经贯通。`draftId`、默认 6 小时 TTL、修改续期和结构化校对页仍是后续设计，本文下面相关章节继续使用将来时。

## 当前实现已经守住了哪些边界

上一篇《[给 ERP AI Tools 收一套统一协议：commandType、prepare-confirm 与 Query Framework](/2026/08/18/erp-ai-tool-command-query-framework/)》完成后，Java MCP 的写操作已经有一条稳定主链路：

```text
领域 prepare Tool
  → 领域 Service 校验并规范化表单
  → PreparedCommandService 生成 preparationId
  → Redis 保存规范化命令、预览、tenant、user、commandType 和绝对过期时间
  → 用户确认
  → 通用 confirm Tool 只提交 preparationId
  → Redisson 按 preparationId 加锁
  → Handler 再次校验实时业务条件并落库
  → Redis 保存 CONFIRMED 和创建结果
```

`commandType` 是 Java 内部的 Handler 路由键。采购、产品入库、炉料出入库和委外订单分别注册处理器，模型不能提交或替换这个值。`documentKind` 继续表示大类内部的业务子类型，例如采购类中的请购单、采购订单，产品入库中的采购入库、委外入库、其他入库。

当前实现还处理了几类容易被忽略的失败：

- preparation 绑定创建它的租户和用户，跨租户、跨用户确认会被拒绝；
- 同一 ID 的并发确认由 Redisson 锁串行化；
- Handler 失败时保留 `PREPARED`，凭证有效期内仍可重试；
- 成功结果写回 Redis，重复确认返回同一结果；
- Redis 的 TTL 与记录中的绝对过期时间同时校验；
- ERP 原有业务单号幂等继续保留，Redis 不接管业务数据库的一致性职责。

Pi Runtime 也已经有合适的展示落点。Java MCP Tool 执行结束后，动态信息可以进入原生 `ToolResult.details.presentation`；Pi Session 保存这条 ToolResult，实时 SSE 和历史消息都能读取同一份 presentation。这里不需要再造一套平行会话事件。

## Prepare 快照接不住持续修改

`preparationId` 表达的是一份不可变确认快照。用户改了数量、仓库或任意一行明细，旧快照就应该失效，Agent 重新 prepare，再让用户确认新预览。

这个约束适合短表单。结构化校对页会让用户连续改很多次，系统也无法提前知道哪一次修改是最后一次。用户在页面里已经把单据校对完成，随后说“帮我生成”，再返回一张 prepare 卡片要求确认，会多出一次没有业务价值的往返。

继续给 preparation 增加 `editable`、`reviewed`、`preparedAgain` 等状态，会让同一对象同时承担“草稿”和“确认凭证”两种含义。我们选择收掉 preparation 概念，对外只保留 Draft：

```text
DRAFT
  ├─ 修改成功 → DRAFT，并续期
  ├─ 确认成功 → CONFIRMED
  └─ TTL 到期 → 不可用
```

简单单据也是 Draft。区别落在 presentation：简单数据使用紧凑卡片，复杂数据打开结构化校对页。模型可以根据行数、来源文件和识别风险选择 `reviewMode`，但 `reviewMode` 只决定 UI 投影，不改变服务端生命周期。

## 一个 draftId 同时支持修改和确认

统一 Draft 协议保留一个 ID：

```text
创建 Draft
  → 返回 draftId

修改 Draft
  → 提交同一个 draftId
  → 领域 Handler 重新校验并保存规范化数据
  → 返回同一个 draftId 和新的 expiresAt

确认 Draft
  → confirm_document_draft(draftId)
  → 使用 Redis 中的最新规范化数据落库
```

MVP 不增加 `versionId` 或 `expectedVersion`。当前会话请求在 Pi Runtime 内按 conversation 串行，结构化页面每次修改后重新加载服务端 Draft。聊天里更新 Draft 时，新的 ToolResult presentation 会让同一 `draftId` 的旧卡片失效，只保留最新卡片可操作。

这里可以复用 Pi 原生 Entry 顺序：

```text
第一次保存 Draft
  → ToolResult.details.presentation.draft(draftId=D)

Agent 修改 Draft
  → 新 ToolResult.details.presentation.draft(draftId=D)

前端按 Entry 顺序扫描
  → 较早的 D 标记为失效
  → 最新的 D 从后端重新加载完整数据
```

模型不负责重述整张表，Session 也不复制大体积明细。presentation 保存稳定引用，Draft 数据继续以 Redis 为事实源。

这项简化接受 last-write-wins。多浏览器或多人同时编辑同一 Draft 的需求出现后，再引入版本校验；当前没有证据支撑这部分并发协议。

## 过期时间由后端决定

Draft 默认有效期定为 6 小时。Tool 参数不开放 TTL，模型也不负责计算 `expiresAt`。

```text
创建成功
  → 后端读取当前 Handler 的 TTL 配置
  → 未配置时使用 6 小时
  → Redis 原子写入 value + TTL
  → 返回后端计算出的 expiresAt

修改成功
  → 后端重新校验并保存 Draft
  → 按同一规则续期
  → 返回新的 expiresAt

读取 Draft
  → 不续期
```

框架需要保留 Handler 自定义 TTL 的入口，首版所有 Handler 都使用 6 小时默认值。敏感单据以后可以缩短，长周期计划也可以延长，不需要改 Tool Schema。

Draft presentation 只保存 UI 需要的最小信息：

```json
{
  "title": "编辑单据草稿",
  "draft": {
    "draftId": "<uuid>",
    "status": "DRAFT",
    "expiresAt": "2026-08-20T20:40:30+08:00",
    "reviewMode": "structured"
  }
}
```

前端可以根据 `expiresAt` 立即禁用过期卡片，减少一次无效请求。后端仍会检查 Redis key 和记录中的绝对过期时间，浏览器时间不能成为确认依据。Redis 自然淘汰数据即可，不增加定时清理任务，也不保存过期墓碑。

## Confirm 返回的是业务结果和页面回链

单据创建成功后，用户还要进入 ERP 查看、修改、审核、上传附件或执行后续操作。聊天只回复“创建成功”会迫使用户重新找菜单、输入单号再查询。

Confirm 的展示结果增加三个字段：

```json
{
  "documentModuleKey": "<menu-function-number>",
  "documentId": "<document-id>",
  "documentNo": "<document-number>"
}
```

`documentId` 使用字符串，避免 JavaScript 对 64 位整数的精度损失；部分流水型单据没有统一单头 ID，该字段允许为空，页面改用 `documentNo` 定位。

`documentModuleKey` 对应 ERP 菜单表里的 `function_number`，它不是 URL。前端从当前用户已经加载的权限菜单中查找这个 key，再取得真实路由：

```text
Confirm 成功
  → presentation.document
  → documentModuleKey 查当前用户 permissionList
  → 找到 menu.url
  → router.push(menu.url + Query Deep Link)
  → 列表页按 documentId/documentNo 精确查询
  → 用户继续使用页面原有的修改、审核、附件等操作
```

Deep Link 统一使用 locate 语义：

```text
?aiDocumentId=<string>&aiDocumentNo=<string>
```

页面优先使用 ID，接口暂不支持 ID 时使用单号。定位完成后展示正常菜单列表，不自动打开只读详情。现有列表页普遍已经有查询、分页和行操作，适配 locate 的改动远小于统一各种弹窗、抽屉和专用详情组件。

当前用户的权限菜单里找不到 `documentModuleKey` 时，前端不生成跳转按钮。后端也不直接下发 URL，从而保留菜单调整和业务代码之间的解耦。

## 路由绑定留在数据库

Handler 里声明页面地址会把 Java 业务代码和 Vue 路由绑在一起。页面迁移、菜单改号或插件页改造成普通页面，都要重新发布后端。

绑定表只保存业务命令和菜单编号的关系：

```sql
ai_document_module_binding
  command_type    varchar(...) not null
  document_kind   varchar(...) not null default ''
  function_number varchar(...) not null
  enabled         tinyint      not null

unique(command_type, document_kind)
```

查询规则使用精确匹配：

```text
commandType 有值、documentKind 为空
  → 查询 (command_type, '')

commandType 与 documentKind 都有值
  → 查询 (command_type, document_kind)
```

联合绑定不存在时不回退到 commandType 默认项。静默回退可能把采购订单导航到请购单页面，缺少按钮比错误页面更容易排查。

Tool 粒度继续按业务大类收口。采购 Tool 可以覆盖请购单和采购订单，产品入库 Tool 可以覆盖采购入库、委外入库和其他入库；这些子类型共享相同输入骨架和内部 Facade，没有必要为每个 `documentKind` 扩张一组 Tool。`documentKind` 使用受限枚举，模型不能传自由文本。

导航解析发生在 Confirm 成功之后。绑定缺失或查询异常不能把已经落库的业务单据改判成失败：Confirm 仍返回创建结果，presentation 不显示导航，并记录配置错误。重复 Confirm 返回的 receipt 也应包含当时生成的导航信息，避免重试前后结果漂移。

## presentation 在 Pi 链路中的位置

业务数据和 UI 展示数据需要分开走：

```text
Java Tool 返回结构化业务结果
  ├─ payload → 提供给模型继续推理
  └─ presentation → 提供给聊天 UI

Pi Java MCP Adapter
  → 合并静态 Tool title 与动态 document
  → 写入 ToolResult.details.presentation

Pi Session
  → 原样持久化 ToolResult Entry

实时阶段
  → tool_execution_end 从 details 读取 presentation

历史阶段
  → Session Entry 投影读取同一份 presentation

ERP 前端
  → 当前：单据导航按钮
  → 后续：Draft 卡片 / 结构化校对入口
```

当前 Runtime 的 Tool Hook 会根据工具目录补充静态 `title`，并与 Java Tool 执行结果中的动态 `document` 合并，避免静态目录覆盖业务执行结果。历史恢复已经保留同一份 `document`。后续实现 Draft 时，再让同一合并与投影链路识别 `draft`，不新增平行会话协议。

这套链路没有新增自定义消息 Entry。每次 Draft 创建、修改和 Confirm 本来就会产生原生 ToolResult；UI 只需要识别其中的 presentation。会话存储继续保存 Pi 原生消息，Draft 明细继续留在后端。

## 实现顺序和剩余代价

按纵向链路拆成三步更容易回归：

1. 已完成 Confirm receipt、绑定表、`documentModuleKey` 和列表 locate，并通过真实创建与历史恢复验收。
2. 下一步把 `preparationId`、`PREPARED` 和 15 分钟 TTL 改为 `draftId`、`DRAFT` 和默认 6 小时续期。
3. 最后接入结构化校对页，以及同一 `draftId` 的旧 presentation 失效规则。

Draft 增加了可变状态。更新请求需要重新执行领域校验，Confirm 仍要复核库存、来源单状态和主数据。Redis 与业务数据库之间依旧没有分布式事务，数据库提交后、Redis receipt 写回前发生进程故障时，仍要依靠业务单号幂等兜底。

页面回链也不是零成本。已有单号筛选的列表页只需读取 Query Deep Link；缺少 ID、单号过滤的页面要补一条精确查询条件。自动打开详情、统一高亮和跨页面操作编排暂不进入首版。

第一阶段已经把 Confirm receipt 中的 `documentModuleKey/documentId/documentNo` 落成稳定协议。下一阶段再处理可编辑的 `draftId` 和后端生成的 `expiresAt`，不把尚未实现的 Draft 能力混入当前交付结论。
