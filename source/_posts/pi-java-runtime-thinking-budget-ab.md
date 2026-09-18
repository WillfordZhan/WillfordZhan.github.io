---
title: "Pi Java Runtime 导入提速复盘：thinking budget 从 2048 到 768"
date: 2026-09-18 16:30:00
categories:
  - "AI"
tags:
  - "AI Agent"
  - "Pi Runtime"
  - "性能优化"
  - "LLM 评测"
  - "AI工作日志"
source_archive:
  id: 20260918-pi-java-runtime-thinking-budget-ab
  rel_path: source_materials/posts/20260918-pi-java-runtime-thinking-budget-ab
  conversation_file: conversation.jsonl
---

一次生产服铁水批次计划导入需要 2～3 分钟。排查后，慢点集中在 Pi Runtime 调用 Qwen 的三轮推理，Java 网关、SSE 和工具接口都没有占掉主要时间。

这次优化最后把专用导入会话的 `thinking_budget` 从默认的 2048 收到 768。768 不是模型的“思考等级”，也不是所有任务都应该使用的固定值，它是一次 Provider 请求允许使用的最大 reasoning token 数。实测结果是：512 更快但发生了语义合并，1024 语义正确但超过 100 秒，768 在这份真实 Excel 上同时满足了语义和时延要求。

## 先确认慢在哪里

测试服使用与生产服相同的 ERP 工厂配置，导入一份包含多条批次、多个钢种和配方上下限的 Excel。一次完整成功链路的工具顺序如下：

```text
前端上传 Excel
  -> POST /ai/imports/molten-iron-batch-plan
  -> Pi 创建专用导入会话
  -> read_attachment / load_skill
  -> molten_iron_batch_field_schema
  -> query_recipes（一次传入多个配方名称）
  -> create_or_update_recipe（按语义结果新增或更新）
  -> create_molten_iron_batch_plan_draft
  -> Draft 成功后返回原生 terminate
```

最终复测的墙钟时间是 93.296 秒。三轮 Provider 请求分别耗时 11.5169、46.7157、33.4905 秒，合计 91.7231 秒，占墙钟时间约 98.31%。工具调用、数据库查询和 Draft 写入只占很小部分。

这一步很重要：没有先把时间拆到调用链上，直接改 Java 查询或页面轮询，收益都不会落在主要瓶颈上。

## `thinking_budget` 到底控制什么

Pi Runtime 的 Provider 适配器负责把统一消息转换成 Qwen 请求。Qwen 使用的是 Provider 原生字段：

```json
{
  "enable_thinking": true,
  "thinking_budget": 768
}
```

这里有三个容易混淆的概念：

| 字段 | 作用 |
| --- | --- |
| `enable_thinking` | 是否允许模型进行思考 |
| `thinking_budget` | 本次请求最多使用多少 reasoning token |
| `reasoning_effort` | 某些 Provider 的抽象档位，当前 Qwen 适配并不依赖它 |

当前 Java Runtime 的配置增加了一个正整数环境变量：

```text
PI_RUNTIME_THINKING_BUDGET=768
```

配置在 Runtime 启动时解析，专用导入会话在发送 Provider 请求前，通过已有的 `before_provider_payload` 原生 Hook 注入 `enable_thinking` 和 `thinking_budget`。这条改动没有触碰 Agent Loop，也没有给普通聊天会话套上导入专属参数。

```text
统一消息
  -> Provider payload 已构造
  -> before_provider_payload Hook
  -> 仅当 sessionPurpose=molten-iron-batch-plan-import 时注入预算
  -> Qwen 请求
```

这个位置的边界很清楚：模型请求格式属于 Runtime/Provider 适配层，导入业务的终止条件仍由专用会话处理逻辑负责。Draft 成功生成或更新后，专用会话返回原生 `terminate`，不会改动通用 Agent Loop 的退出语义。

## 为什么先补配方自动取号

导入过程中发现，模型识别出需要新增配方时，原链路还需要自己组织配方编号。这个动作既消耗上下文，又给重复编号和格式猜测留下空间。

因此先在 ERP 配方保存服务里复用现有序号能力：创建时 `recipeNum` 为空就由服务端按租户和配方类型生成，显式传入编号的更新场景保持原逻辑。AI Tool 只关心“新增还是更新”和配方内容，编号归 ERP 领域服务负责。

这项改动没有直接缩短 Provider 推理时间，却减少了模型需要承担的业务决策，降低了导入链路的脆弱点。性能优化和业务边界收口要分开验证，避免把两类收益混在一起。

## A/B 结果：512、768、1024

三组测试使用同一份 Excel、同一个测试工厂和相同的清理流程。每次完成后都检查配方详情、Draft 结构、批次数量和动态字段，不只看 HTTP 200。

| `thinking_budget` | 墙钟时间 | Provider 总耗时 | 输出 token | 结果 |
| ---: | ---: | ---: | ---: | --- |
| 512 | 77.514 秒 | 约 76.255 秒 | 5,831 | 失败：把 1.2738 的 B/C 两套配方合并 |
| 768 | 93.296 秒 | 91.7231 秒 | 6,804 | 通过：语义正确，8 批次、233,300 kg |
| 1024 | 108.684 秒 | 107.2295 秒 | 7,875 | 通过：语义正确，但超过 100 秒目标 |

512 的失败比较隐蔽：Draft 的结构校验没有报错，`issues=[]`，但两套配方被模型合并，属于“结构成功、语义错误”。这也是为什么只用接口状态、字段非空和 Draft 校验结果做验收不够。

768 的复测结果包括：

- 一次 `query_recipes` 传入 `1.2738`、`42CrMo4`、`5CrNiMo`，没有额外逐个 `get_recipe`；
- 生成或更新 4 套配方，元素集合和上下限保持正确；
- Draft 包含 8 个批次，总重量 233,300 kg；
- CF003 的数字值为 `[1,2,1,2,1,2,1,2]`，CF016 为“已做”；
- 完成后会话删除返回 200，Draft 清理后 GET 为 404，临时配方全部删除，最终查询总数为 0。

## 这次优化真正改变了什么

改动很小，影响面也被限制在专用导入会话：

1. Runtime 配置增加 `PI_RUNTIME_THINKING_BUDGET`，默认值仍保留为 2048，未配置时不改变旧行为。
2. Provider Hook 只识别导入会话目的，普通聊天、数字员工新会话和其他 Tool 调用不继承这个预算。
3. 配方创建编号交给 ERP 服务端生成，模型不再负责猜编号。
4. 验收从“请求成功”升级为“工具轨迹 + Draft 结构 + 配方详情 + 清理结果”的组合证据。

这里没有通过固定文本匹配某个钢种，也没有给当前 Excel 加专属规则。预算是通用 Runtime 配置，导入会话只是一个可配置的作用域。

## 还不能直接下的结论

768 是这份真实导入样本上的当前选择，不代表所有 Excel、所有模型或所有 Provider 都适合 768。现在只有一次完整的 768 成功复测，后续还需要用多份不同复杂度的表格重复 3～5 轮，观察：

- 配方候选数量变多时，语义错误率是否上升；
- 表格图片、合并单元格和缺失列是否需要更多推理预算；
- Provider 延迟波动是否掩盖预算带来的收益；
- `query_recipes` 返回的配方详情是否继续保持上下文增长压力。

从当前 trace 看，三轮请求的输入 token 分别为 25,137、30,407 和 34,344，提示词和工具 Schema 已经是明显成本。下一步优先级应放在通用的工具目录精简、按需加载 Schema 和语义校验器，而不是继续压低预算。预算解决的是推理上限，不能替代证据完整性和结果校验。

## 结论

这次导入提速没有改 Agent Loop，也没有为某个客户写特例。先用 trace 找到 Provider 请求占比，再把 Provider 原生预算收敛到专用会话作用域，最后用语义验收筛掉“快但错”的配置。

最终选定：`PI_RUNTIME_THINKING_BUDGET=768`。当前证据支持它作为这条导入链路的生产候选值；是否推广到其他 Agent 场景，必须重新做同样的 A/B 和语义验收。
