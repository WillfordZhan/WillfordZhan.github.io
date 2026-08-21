---
title: "用 Swagger 驱动 AI Draft 校对页的枚举标签"
date: 2026-08-21 19:15:43
categories:
  - "AI"
tags:
  - "Java"
  - "Swagger"
  - "JSON Schema"
  - "AI Agent"
  - "ERP"
  - "AI工作日志"
source_archive:
  id: 20260821-swagger-enum-labels-draft-ui
  rel_path: source_materials/posts/20260821-swagger-enum-labels-draft-ui
  conversation_file: conversation.jsonl
---

ERP 的 AI Draft 校对页已经能根据 Java 表单自动生成。采购表单打开以后，页面上却出现了这样的内容：

```text
AI DOCUMENT DRAFT
PURCHASE_REQUISITION

采购单据类型
PURCHASE_REQUISITION
PURCHASE_REQUISITION-请购单，PURCHASE_ORDER-采购订单
```

页面结构是自动生成的，字段语义还停留在后端协议里。用户需要看到“请购单”，后端仍然需要收到 `PURCHASE_REQUISITION`。把英文值替换成中文会破坏接口；在 Vue 页面里判断采购类型，又会让通用校对页逐渐堆满业务分支。

这次准备把枚举值和中文标签收回 Swagger DTO，让同一份 API 元数据同时服务接口文档、AI Tool Schema 和 Draft UI。本文记录设计，相关代码尚未落地。

## 当前校对页怎样生成

Draft 页面没有为请购单、入库单和委外单分别编写表单。Java Tool 接收强类型 DTO，Draft Handler 声明对应的 `commandClass`，公共服务再通过反射生成 JSON Schema：

```text
Java Tool 的 form DTO
  → Handler.commandClass()
  → ToolSchemaIntrospector
  → Draft detail.schema
  → Pi Runtime 转发 Draft API
  → Vue 递归 Schema 组件
```

前端根据 Schema 类型选择控件：

- `object` 渲染字段分组；
- `array<object>` 渲染可增删的单身表格；
- `boolean` 渲染开关；
- `number` 和 `integer` 渲染数字输入；
- `enum` 渲染下拉框；
- `readOnly` 禁止编辑；
- `issues.path` 定位并标红字段。

保存时，页面 PUT 完整表单。Java 将 JSON 重新绑定到同一个 DTO，再执行规范化和业务校验。Confirm 请求只提交 `draftId`，服务端重新校验后才写业务表。

这条链路已经把页面结构收成了通用能力。当前缺口落在枚举的展示元数据上。

## 为什么页面只能显示机器值

采购单据类型目前是普通 `String`：

```java
@ToolField(
    title = "采购单据类型",
    description = "PURCHASE_REQUISITION-请购单，PURCHASE_ORDER-采购订单",
    required = true
)
private String documentKind;
```

Schema 反射器看到的是 `String`，输出结果只有：

```json
{
  "type": "string",
  "title": "采购单据类型",
  "description": "PURCHASE_REQUISITION-请购单，PURCHASE_ORDER-采购订单"
}
```

Schema 没有 `enum`，也没有值与标签的对应关系。前端只能使用文本框展示 Draft data 中的原值。说明文字虽然写了中英文映射，人和程序都很难稳定消费：改一个标点、空格或描述顺序，文本解析就会失效。

## Swagger 1.5 已经留了扩展入口

项目当前使用 Swagger annotations 1.5。`@ApiModelProperty` 提供两个可以直接复用的字段：

- `allowableValues` 保存允许的机器值；
- `extensions` 保存扩展元数据，而且一个字段可以声明多个 Extension。

采购类型可以这样定义：

```java
@ApiModelProperty(
    value = "采购单据类型",
    required = true,
    allowableValues = "PURCHASE_REQUISITION,PURCHASE_ORDER",
    extensions = @Extension(
        name = "x-enum-labels",
        properties = {
            @ExtensionProperty(
                name = "PURCHASE_REQUISITION",
                value = "请购单"
            ),
            @ExtensionProperty(
                name = "PURCHASE_ORDER",
                value = "采购订单"
            )
        }
    )
)
private String documentKind;
```

`allowableValues` 属于 Swagger 的现有能力。中文标签没有一等属性，因此使用 `x-enum-labels` 扩展。这里保留机器值作为 key，中文只负责展示。

同一个字段还可以声明其他 Extension：

```java
extensions = {
    @Extension(name = "x-enum-labels", properties = { /* ... */ }),
    @Extension(name = "x-another-extension", properties = { /* ... */ })
}
```

这次不会增加 `x-ui.component=select` 一类配置。DTO 负责表达业务值和可读标签，具体使用 Ant Design Vue 还是其他组件，仍由前端的 Schema 渲染器决定。

## Schema 投影保持一处

`ToolSchemaIntrospector` 已经读取 `ApiModelProperty.value` 和 `required`。在同一个位置补两条规则即可：

```text
ApiModelProperty.allowableValues
  → schema.enum

ApiModelProperty.extensions[x-enum-labels]
  → schema.x-enum-labels
```

最终 Schema 预计为：

```json
{
  "type": "string",
  "title": "采购单据类型",
  "enum": [
    "PURCHASE_REQUISITION",
    "PURCHASE_ORDER"
  ],
  "x-enum-labels": {
    "PURCHASE_REQUISITION": "请购单",
    "PURCHASE_ORDER": "采购订单"
  }
}
```

前端下拉框仍把机器值放进 `value`，选项文字读取中文标签：

```vue
<a-select-option
  v-for="option in schema.enum"
  :key="option"
  :value="option"
>
  {{ schema['x-enum-labels'][option] || option }}
</a-select-option>
```

用户选择“请购单”后，Draft data 仍然是：

```json
{
  "documentKind": "PURCHASE_REQUISITION"
}
```

顶部业务标题也使用同一个标签解析函数。页面先读取 `data.documentKind`，再从对应字段 Schema 中解析中文名称。采购页面显示“请购单”，其他单据继续按各自的 Swagger 定义工作，Vue 代码不认识任何采购常量。

固定英文眉题 `AI DOCUMENT DRAFT` 则直接改成“数据写入预览”。这属于页面文案，不需要进入 DTO 或 Schema。

## 为什么不把配置加进 ToolField

给 `@ToolField` 增加 `enumValues` 和 `enumLabels` 也能生成同样的页面，维护时会遇到两份来源：

```text
Swagger DTO：接口允许哪些值
ToolField：AI 页面显示哪些值
```

后续 AI Tool 切换为调用现有 API 接口时，现有 DTO 已经带着 Swagger 注解。继续要求这些 DTO 增加 AI 专用枚举配置，会让接口层和 Agent 层长期同步同一张映射表。

Swagger 作为来源后，`@ToolField` 只保留 AI 特有语义，例如字段对模型的说明、可见范围和 `readOnly`。API 的允许值和业务标签继续跟着 API DTO 走。

## 这个设计增加了什么负担

`x-enum-labels` 是项目约定的 vendor extension，不属于 JSON Schema 的标准关键字。Java 投影器和前端渲染器需要共同维护它，并用契约测试锁定格式。

几个边界需要写清楚：

- 只有 `allowableValues` 时，页面仍能生成下拉框，缺少标签的选项回退机器值；
- 标签映射中多出的 key 不进入可选值；
- `allowableValues` 没有声明时，普通 String 继续使用文本输入；
- 业务校验仍由 Draft Handler 执行，枚举 Schema 不能替代领域校验；
- 前端不解析 description，也不按字段名或单据类型补标签。

回归至少覆盖两端：Java 测试确认 Swagger 注解正确投影为 Schema；前端测试确认下拉框显示中文、保存值保持英文。采购 Draft 还需要跑一次完整的保存与 Confirm，确认接口、幂等和页面导航没有受到影响。

这套改动只补展示语义，不改变 Draft 状态、Redis 数据和 ERP 写入协议。现有 API DTO 继续使用熟悉的 Swagger 注解，AI 校对页从同一份元数据获得可读标签。
