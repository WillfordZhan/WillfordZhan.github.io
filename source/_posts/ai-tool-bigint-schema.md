---
title: "AI Tool 大数精度丢失：返回值与参数 Schema 必须一起修"
date: 2026-08-07 14:29:56
categories:
  - "AI"
tags:
  - "MCP"
  - "AI Tool"
  - "踩坑复盘"
  - "AI工作日志"
source_archive:
  id: 20260807-ai-tool-bigint-schema
  rel_path: source_materials/posts/20260807-ai-tool-bigint-schema
  conversation_file: conversation.jsonl
---

一次物料出库的 AI Tool 调用失败，表面提示是“物料不存在或不属于当前工厂”。实际物料存在，问题发生在它作为 19 位 ID 穿过 JSON 与工具调用契约时。

第一次排查发现，工具调用收到的 ID 已经和查询结果不一致。随后将工具结果中的大整数序列化为字符串后，最新会话仍失败：返回值正确了，但工具参数 Schema 还是 `integer`，模型又把字符串 ID 当数字传回。这个问题需要同时修复结果表示和参数契约。

## 故障是怎样出现的

出库流程需要先查物料，再把物料和仓库 ID 交给 `create_material_stock_document`。故障日志显示，工具收到的物料 ID 已被舍入，随后按错误 ID 查询，自然得到了“不存在”的业务异常。

```text
search_material
  -> 返回物料与仓库 ID
  -> 模型组织 create_material_stock_document 参数
  -> 后端按 ID + 当前工厂查询
  -> 查无记录，返回“物料不存在或不属于当前工厂”
```

初看很像租户隔离或物料主数据问题。对照数据库与会话记录后，真实 ID 与工具收到的 ID 不同；两个值都是 19 位，已经超过 JavaScript 的安全整数上限 `9007199254740991`。

实际发生过的两组数据如下：

| 对象 | 正确 ID | 工具调用收到的 ID |
| --- | --- | --- |
| 物料 | `1955516024755728386` | `1955516024755728400` |
| 仓库 | `2079385681079046145` | `2079385681079046100` |

错误值并不是后端重新生成的 ID，而是原值在数值表示阶段被舍入后的结果。因此按错误 ID 查询时，没有任何一条物料或仓库记录能匹配。

这不是 Java 的 `Long` 算错了。`Long` 能保存该值，问题是它在某一段 JSON 链路中被当作 JavaScript `Number`。`Number` 只能精确表示安全整数范围内的整数，超出范围后会按二进制浮点规则舍入。

## 第一次修复为什么不够

最初的公共修复落在 Tool 返回值投影处。AI 工具注册模块自行创建了 `ObjectMapper`，绕过了 Spring 全局 Jackson 配置，因此项目已有的大数序列化规则没有生效。

原链路：

```text
Java Long
  -> 自建 ObjectMapper
  -> JSON number
  -> JavaScript / 模型运行时 Number（可能舍入）
  -> 下一次 Tool Call 使用已变形的 ID
```

修复后，工具结果复用 Spring 管理的 `ObjectMapper`，超出安全范围的 `Long` 和 `BigInteger` 以 JSON 字符串输出：

```json
{
  "materialId": "1955516024755728386",
  "depotId": "2079385681079046145"
}
```

这一步确实生效了：后续 Pi 会话中的 `search_material` 已经拿到了精确的字符串 ID。

但出库仍然失败。继续看 `tools/list` 返回的定义，`form.lines[].materialId`、`depotId` 等字段仍是 `integer`。模型遵循这个 Schema 构造调用参数时，会把字符串重新按数字处理；在请求序列化前，精度再次丢失。

## 修复的是 AI Tool 的边界契约

这里不应只针对物料、仓库或供应商字段逐个打补丁。根因是 AI Tool 边界把 Java 的 64 位整数误描述成了 JSON `integer`。

修复收口在通用 Schema 推导逻辑：

```text
Java 参数类型
  -> ToolSchemaIntrospector 推导 inputSchema
  -> MCP tools/list
  -> 模型按 Schema 组装参数
  -> ToolRegistry 反序列化为 Java 参数
```

新的规则是：

```text
long / Long / BigInteger
  -> AI Tool inputSchema: string
  -> JSON: "精确十进制文本"
  -> Java 绑定时还原为原始数值类型

Integer / Short / Byte / BigDecimal
  -> 继续使用数值类型
```

因此，`materialId`、`depotId`、`supplierId` 不需要字段名白名单；所有由 `Long` 或 `BigInteger` 表达的 AI Tool 参数都会得到同一套保护。业务 DTO、数据库字段和 Java 服务方法仍保持原来的数值类型，变化只发生在最容易丢精度的跨运行时边界。

## 回归测试覆盖了两边

测试没有只断言 Schema，而是同时验证：

1. 嵌套参数 `form.lines[].materialId` 的类型为 `string`；
2. 直接 `Long` 参数的类型也为 `string`；
3. 字符串形式的 19 位 ID 绑定到 Java `Long` 后，值保持精确；
4. 工具返回结果对超出安全范围的 `Long` 输出文本，而安全范围内的 `Long` 仍可输出整数。

执行受影响模块测试，6 个测试全部通过。

## 最后一个容易漏掉的验收点

代码与本地测试通过，不等于运行中的 AI Agent 已使用新契约。这次验证时，本地重启的 Java 服务已加载新代码，但 Pi 的实际 MCP 地址返回的 `tools/list` 仍是旧的 `integer` Schema。

```text
源码与本地实例：schema = string
Pi 实际连接实例：schema = integer
```

这说明剩余问题是部署目标或运行配置不一致，而不是模型缓存。验收不能只看源码，也不能只看返回值；必须从 Agent 实际使用的 MCP 地址读取 `tools/list`，确认大整数参数是 `string`，再做一次只准备、不落库的出库调用。

对于跨 Java、JSON、JavaScript 和 LLM Tool Use 的 ID，可靠约定很简单：把它当作标识符文本传递，而不是可计算的数字。返回值和参数 Schema 必须一起改；只修其中一半，精度仍会在下一次工具调用里丢掉。
