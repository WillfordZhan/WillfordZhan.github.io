---
title: "给 ERP AI Tools 收一套统一协议：commandType、prepare-confirm 与 Query Framework"
date: 2026-08-18 10:52:19
categories:
  - "AI"
tags:
  - "AI Agent"
  - "MCP"
  - "Tool Calling"
  - "Java"
  - "架构设计"
  - "AI工作日志"
source_archive:
  id: 20260818-erp-ai-tool-command-query
  rel_path: source_materials/posts/20260818-erp-ai-tool-command-query
  conversation_file: conversation.jsonl
---

ERP Tool 接到第三类单据时，重复代码已经很明显了。

每个创建工具都要判断 `prepare` 和 `confirm`，补全主数据，重新校验表单，再处理幂等和并发。查询工具也各自维护 `page`、`pageSize` 和返回总数。字段名字看着接近，默认值、上限和错误语义却散在不同 Service 里。

当前链路已经能稳定完成 Tool 发现和调用：Pi Runtime 从 Java 获取 Tool Schema，把 tenant/user 固定进调用上下文，再由 Java MCP 调度到具体业务 Tool。缺口落在 Tool 进入 Java 之后。写操作和查询操作还没有共用一套业务协议。

本文记录准备采用的设计。现有代码仍以“完整 form 二次提交”和各 Service 自行处理分页为主，下面的 Command Framework、Redis preparation 和 Query Framework 还属于拟议方案。

## 当前 Tool 调用停在哪一层

现有调用顺序可以压缩成下面这条链路：

```text
用户请求
  → Pi AgentSession
  → Java MCP tools/call
  → MCP Dispatcher 注入运行上下文
  → Tool Registry 校验参数并调用 Tool
  → 业务 Tool
  → ERP Service
```

Pi Runtime 负责两件事：

1. 让模型看到当前可用的 Tool Schema。
2. 把模型产生的 Tool Call 交给 Java，并附上可信的 tenant/user。

Java MCP 入口继续做鉴权、上下文解析、Schema 校验和异常归一。Tool 方法拿到的 `AiRunContext` 已经包含服务端确认过的用户和租户，模型不需要也不允许自己提交这些字段。

因此，两个公共 Framework 应该放在 Java Tool 与业务 Service 之间。Pi 保持通用 Agent Runtime，不感知采购订单、入库单或者某个查询字段。

```text
Pi Runtime
  → Java MCP
  → Command / Query Framework
  → 领域 Handler
  → 现有 ERP Service
```

## 旧的 prepare-confirm 为什么开始不顺

当前写操作大致采用下面的接口：

```text
createDocument(action, form)
```

`action=prepare` 时，服务端补齐产品、供应商、仓库、金额等字段，返回完整 form。`action=confirm` 时，Agent 把完整 form 再提交一次，服务端重新执行 prepare 校验，然后调用原有 ERP Service 落库。

这套实现已经守住了几条重要边界：

- 主数据由服务端重新读取。
- confirm 不信任预览阶段计算出的金额。
- tenant/user 来自运行时上下文。
- 业务 Service 继续负责数据库事务。
- 原始业务单号承担最终幂等校验。

麻烦出在“确认对象”不够明确。用户看到的是第一次 prepare 的预览，confirm 收到的却是模型重新发送的完整 form。服务端能重新校验，却无法证明第二份 form 与用户刚才确认的预览完全相同。

随着单据类型增加，另外几类重复也开始出现：

- 每个 Tool 重写一次 action 判断。
- 每个 Service 定义一套 `prepared`、`preview_ready`、`created` 状态。
- 每个 Skill 再描述一遍“先 prepare，等待明确确认，再 confirm”。
- 某个 Skill 已经要求使用“确认标识”，实际 Tool 结果却还没有该字段。

最后一条已经属于契约漂移。继续复制实现只会让 Tool、Skill 和测试各自维护一套事实。

## commandType 是 Java 内部的路由键

统一写协议需要一个稳定标识，用来说明一份 preparation 最终会执行哪类业务命令。这里把它叫作 `commandType`。

示例：

```text
erp.purchase_requisition.create
erp.purchase_order.create
erp.stock_inbound.create
erp.outsource_order.create
furnace.stock_inbound.create
furnace.stock_outbound.create
```

项目里同时存在三个容易混淆的标识：

| 标识 | 消费者 | 用途 |
| --- | --- | --- |
| `toolName` | LLM / Pi | 选择要调用的 AI 能力 |
| `commandType` | Java Framework | 找到 Handler，校验 preparation 没有串业务 |
| `documentKind` | ERP 领域代码 | 表示请购单、采购订单、其他入库等业务类型 |

一次采购订单创建可以对应：

```text
toolName     = prepare_erp_purchase_order
commandType  = erp.purchase_order.create
documentKind = PURCHASE_ORDER
```

`commandType` 不进入模型参数。Tool 在 Java 代码里选择已经注册的常量：

```java
return commandFramework.prepare(
    PurchaseOrderCreateHandler.COMMAND_TYPE,
    form,
    context
);
```

这层约束挡住了一类串用错误：采购订单生成的 `preparationId` 无法交给委外订单 Handler 执行。

## Command Framework：prepare 保存快照，confirm 只收 ID

写操作对模型暴露两个语义清晰的动作：

```text
prepare_xxx(form) → PreparedCommand
confirm_xxx(preparationId) → CommandReceipt
```

各类单据继续保留自己的 Tool 名和强类型表单。一个包含全部单据联合 Schema 的 `execute_document` 会让工具描述和参数分支迅速膨胀，模型选中 Tool 之后仍要猜业务类型，省下的 Java 方法换成了更高的调用失败率。

### prepare 的数据流

```text
Tool 接收领域表单
  → 写死 commandType
  → Framework 从 AiRunContext 读取 tenant/user
  → 找到对应 CommandHandler
  → Handler 规范化表单并校验领域规则
  → Handler 生成预览
  → Framework 把规范化快照写入 Redis
  → 返回 preparationId、expiresAt 和 preview
```

公共结果可以保持很小：

```json
{
  "state": "PREPARED",
  "preparationId": "随机 UUID",
  "expiresAt": "2026-08-18T11:30:00+08:00",
  "preview": {
    "documentKind": "PURCHASE_ORDER",
    "lineCount": 3,
    "amountTotal": 12500.00
  }
}
```

预览只放用户确认所需的稳定业务字段。规范化后的完整 payload 留在 Redis，confirm 阶段不再让模型搬运。

### Redis preparation

Redis key 不需要编码业务字段：

```text
ai:command:preparation:{preparationId}
```

value 至少包含：

```json
{
  "commandType": "erp.purchase_order.create",
  "tenantId": "<tenant-id>",
  "userId": "<user-id>",
  "status": "PREPARED",
  "normalizedPayload": {},
  "snapshotHash": "sha256...",
  "createdAt": "2026-08-18T11:00:00+08:00",
  "expiresAt": "2026-08-18T11:30:00+08:00",
  "receipt": null
}
```

项目已经使用 Redisson `RBucket` 和 TTL，第一版可以直接复用：

```java
bucket.set(preparation, ttl, TimeUnit.SECONDS);
```

过期数据交给 Redis 清理，不增加定时任务。Redis key 缺失时统一返回 `preparation_not_found_or_expired`，第一版不再维护一份过期墓碑来区分“从未存在”和“已经过期”。两种情况对 Agent 的恢复动作相同：重新 prepare。

### confirm 的数据流

```text
Tool 接收 preparationId
  → Framework 从 Redis 读取 preparation
  → 校验 tenant/user
  → 校验当前 Tool 绑定的 commandType
  → 对 preparationId 加分布式锁
  → 检查是否已经完成
  → Handler 重查易变业务条件
  → 调用现有 ERP Service 落库
  → 保存 CONFIRMED 和 receipt
  → 返回创建结果
```

快照字段在 prepare 后不能修改。库存、来源单状态、仓库是否启用等数据会变化，Handler 在 confirm 时仍要重新查询。

状态先收成四个就够用：

```text
PREPARED
  → CONFIRMING
  → CONFIRMED
  → REJECTED
```

执行期间的临时错误可以退回 `PREPARED` 供重试。不可恢复的业务错误进入 `REJECTED`。成功 receipt 保留到 Redis TTL 结束，网络超时造成的重复 confirm 可以直接拿到上次结果。

Redis 只承担短期流程状态。最终幂等仍由业务数据库负责。Redis 重启、淘汰 key 或跨环境切换都可能让 preparation 消失，数据库唯一键和原始业务单号必须继续拦住重复落库。

### Handler 只写领域差异

公共 Framework 不读取采购金额，也不理解库存方向。Handler 负责这些差异：

```java
interface CommandHandler<F, P, R> {
    String commandType();

    PreparedPayload<F, P> prepare(F input, AiRunContext context);

    R confirm(F normalizedPayload, AiRunContext context);
}
```

职责分配如下：

| 公共 Framework | 领域 Handler |
| --- | --- |
| tenant/user 绑定 | 主数据查询 |
| preparationId | 领域表单规范化 |
| Redis TTL | 金额、数量和状态校验 |
| commandType 路由 | 预览内容 |
| 状态和分布式锁 | 调用现有 ERP Service |
| 通用错误码 | 业务错误码和创建结果 |

Framework 抽走的是每类写操作都重复的生命周期。业务规则继续留在业务模块里。

## Query Framework：统一调用形状，不造动态查询语言

当前查询 Tool 已经有分页雏形。库存查询会返回 `page`、`pageSize` 和 `total`，两个库存域也复用了接近的查询对象。分页默认值、上限和日期规范化仍由各 Service 分别处理，排序协议还没有进入公共结果。

统一后的请求分成三块：

```java
class QueryRequest<F> {
    F filter;
    PageRequest page;
    List<SortItem> sort;
}
```

示例：

```json
{
  "filter": {
    "materialName": "球墨铸铁",
    "warehouseName": "成品库"
  },
  "page": {
    "number": 1,
    "size": 50
  },
  "sort": [
    {
      "field": "documentDate",
      "direction": "DESC"
    }
  ]
}
```

`filter` 使用领域强类型对象。`Map<String, Object>` 或任意 `field/operator/value` AST 会把字段白名单、类型校验和权限压力推给运行时，还给 SQL 注入和数据越权留出更大入口。现有 Tool Schema 已经能生成嵌套对象约束，沿用强类型 DTO 更省代码。

### 统一结果

```java
class QueryResult<T> {
    List<T> items;
    PageResult page;
    List<SortItem> appliedSort;
    List<String> warnings;
}
```

返回示例：

```json
{
  "items": [],
  "page": {
    "number": 1,
    "size": 50,
    "total": 128,
    "hasMore": true
  },
  "appliedSort": [
    {
      "field": "documentDate",
      "direction": "DESC"
    },
    {
      "field": "id",
      "direction": "DESC"
    }
  ],
  "warnings": []
}
```

`appliedSort` 返回实际生效的完整排序。数组顺序就是优先级。字段名使用 Tool 公共 Schema 的名字，不能把 `oper_time`、`create_time` 之类数据库列名暴露给 Agent。

上面的 `id DESC` 由 Framework 自动追加。仅按业务日期翻页时，同一天的数据没有稳定顺序，前后两次查询可能重复或漏项。唯一 ID 作为最后一层排序可以把顺序固定下来。Agent 不必向最终用户复述这段元数据，测试和后续翻页会用到它。

`total` 允许为空。部分外部系统只能可靠提供 `hasMore`，强制补总数会多执行一次昂贵查询。当前 ERP 查询继续沿用 `page/size`，第一版不加 cursor；数据规模和并发变化确实造成翻页漂移后，再升级游标协议。

### Query Framework 的边界

公共层负责：

- 补默认页码和页大小。
- 限制最大 page size。
- 校验 `ASC/DESC`。
- 校验排序字段白名单。
- 追加稳定排序字段。
- 构造统一分页结果。

领域 Handler 负责：

- 定义强类型 filter。
- 声明公共排序字段及数据库映射。
- 注入租户、用户和数据权限条件。
- 执行具体 Mapper 或既有 Service。

排序字段不在白名单时直接返回 `query_sort_field_not_allowed`。Framework 不猜别名，也不静默忽略。模型拿到稳定错误后可以修正参数，测试也能准确定位失败原因。

## Tool 统一以后，Skill 可以少写一批重复规则

Tool 负责原子能力，Skill 负责业务编排。两层都需要，但承担的内容不同。

写协议统一后，模块 Skill 不再逐个解释每张单据如何保存临时状态。它只需要写业务顺序：

```text
查询主数据
  → 补齐缺失字段
  → 调用 prepare
  → 完整展示 preview
  → 等待用户明确确认
  → 使用 preparationId 调用 confirm
```

查询协议统一后，Skill 也不需要记住不同 Tool 的 `pageNum/page/pageIndex` 和 `rows/limit/pageSize`。跨模块 Skill 可以沿用同一套分页和排序语义，把篇幅留给领域路由、证据要求和禁止操作。

Tool Schema、Skill 和 Scenario 仍要做一致性校验。Skill 引用的 Tool、参数、状态和结果字段应当能从 Tool Registry 中验证。这样能提前抓住“Skill 已经要求 confirmation ID，Tool 还在返回完整 form”这类漂移。

## 这两套 Framework 怎么测试

公共框架只需要一组集中测试，各领域 Handler 再补自己的业务用例。

Command Framework 至少覆盖：

- prepare 不写业务表。
- preparation 绑定 tenant/user/commandType。
- 过期 ID 被拒绝。
- 跨用户和跨租户确认被拒绝。
- commandType 不匹配被拒绝。
- confirm 使用 Redis 快照，不接收修改后的 form。
- 并发 confirm 只产生一次业务写入。
- 网络重试返回同一 receipt。
- Redis 状态丢失后，数据库幂等仍能拦住重复单据。

Query Framework 至少覆盖：

- 默认分页和最大页大小。
- 非法排序方向。
- 非白名单排序字段。
- 自动追加稳定排序。
- `appliedSort` 使用公共字段名。
- `total` 为空时仍能正确计算或返回 `hasMore`。

Agent Scenario 再验证模型行为：写操作是否先 prepare、普通回复是否被误当成确认、confirm 是否传入刚才返回的 `preparationId`，以及查询 Tool 是否遵循统一分页字段。

## 新增的复杂度和适用边界

Command Framework 引入了 Redis 状态、TTL、分布式锁和一次额外读取。它适合创建单据、审批、删除、发起流程等需要用户确认且副作用明显的操作。普通收藏、标记已读等低风险幂等动作继续直接执行更省事。

Query Framework 统一的是请求和结果外壳。领域过滤条件、权限和 Mapper 不会因此自动通用。试图继续抽成一个万能查询引擎，会把简单 DTO 变成一门新的查询语言。

这次先收两层重复：写操作的生命周期和查询操作的协议形状。Redis 复用现有 Redisson，分页沿用当前 page/size，Tool 保留领域名称和强类型 Schema。后续扩展需要由真实单据和查询场景推动。
