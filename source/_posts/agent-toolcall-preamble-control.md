---
title: "ToolCall 前输出了一大段废话，Agent Runtime 应该怎么限制"
date: 2026-09-02 14:37:31
categories:
  - "AI"
tags:
  - "Agent"
  - "Tool Calling"
  - "Pi"
  - "Claude Code"
  - "Codex"
  - "DeepSeek"
  - "AI工作日志"
source_archive:
  id: 20260902-agent-toolcall-preamble-control
  rel_path: source_materials/posts/20260902-agent-toolcall-preamble-control
  conversation_file: conversation.jsonl
---

在一次 ERP 文档导入中，Agent 明明已经准备调用 Tool，却先输出了整张表格的识别结果、配方元素和后续计划。紧接着，ToolCall 的参数又把同一批数据完整传了一遍。

这不是普通的“回复有点啰嗦”。一次实际会话里，单轮混合了文本与 ToolCall 的 Assistant Message 达到 11,392 个 output tokens、14,890 个字符。用户侧观察到整段流程约 130 秒，其中两段无效长文本占了约 80 秒。

问题可以压缩成一句话：**怎样限制 ToolCall 之前的 Assistant Message，同时不破坏通用 Agent Loop？**

## Pi 当前为什么会把这些文字输出出来

Pi 的基础循环是标准的 ReAct / Tool Use 结构：

```text
模型输出 Assistant Message
  -> 有 ToolCall：执行工具，把 ToolResult 放回上下文，继续下一轮
  -> 没有 ToolCall：结束本轮 Agent Loop
```

Assistant Message 是一个混合内容容器，可以同时包含 `text`、`thinking` 和 `toolCall`。Pi 在流式接收时会转发这些事件；本轮结束后，再从同一条消息里提取 ToolCall 并执行。当前基础层没有“ToolCall 前的文字”和“最终答复”这两个独立预算，也不会因为后面出现了 ToolCall 就自动丢弃前面的文本。

因此，模型先复述一大段参数再调用工具，对运行时来说是合法输出。它只是低效，不是协议错误。

## 几个看似直接、实际不够好的方案

### 1. 只删除 Preamble Prompt

我们已经试过移除 Java Runtime 里的 Preamble。结果只能消除框架主动添加的固定开场，无法阻止模型自己生成“让我先整理一下”“根据附件可以得到”等长篇文字。

Prompt 可以影响模型习惯，但不是可靠的协议约束。

### 2. 全局调低 `max_output_tokens`

这会限制整条 Assistant Message，而不是只限制 ToolCall 前面的文字。文本和 ToolCall 参数共享同一预算；如果预算在工具参数生成到一半时耗尽，Pi 会把这批 ToolCall 判为不可信，因为 JSON 参数可能已经被截断。

所以，全局 token 上限适合防止失控，不适合精确治理 ToolCall 前的废话。它可能把“慢但正确”变成“更快失败”。

### 3. “Draft 未完成时强制 `tool_choice=required`”

这个方案被否决是对的。它把某个 ERP 页面和 Draft 状态机写进了通用 Agent Runtime，造成三类问题：

- 基础层开始理解具体业务对象，耦合方向错误；
- 每新增一种导入流程，都要继续添加特殊状态；
- 如果状态更新失败或模型反复选择无进展的工具，会形成死循环。

`tool_choice` 是通用的单次模型调用策略，不应该被某个业务 Draft 是否完成长期锁定。

### 4. 前端不展示中间文本

这对页面体验有效，但不会减少模型已经生成的 token，也不会缩短 Time to First ToolCall。它解决“看不见”，没有解决“没生成”。

## Claude Code、Codex 和 DeepSeek Harness 怎么做

调研后的共同结论并不神秘：主流 Coding Agent 也没有一个通用的“ToolCall 前文字硬截断器”。它们主要依靠协议、Prompt、调用策略和运行时边界的组合。

Claude 的标准 Agent Loop 仍然是“模型输出 Tool Use，客户端执行，再把结果送回模型”，正常循环通常使用自动工具选择；只有明确知道下一步必须调用某个工具的局部请求，才使用 `tool_choice` 强制选择。[Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/agent-loop) 和 [Anthropic Tool Use 文档](https://platform.claude.com/docs/en/agents-and-tools/tool-use/define-tools) 都体现了这个边界。

在本地核对的一份高保真 Claude Code 实现中，主循环没有默认强制 Tool；Web Search 等目标确定的子请求才会指定工具。它还会给子 Agent 更强的指令：工具之间不要输出文字，完成后统一汇报。但这仍属于 Prompt 约束，不是底层硬保证。

Anthropic 曾尝试加入“工具之间最多 25 个词”一类数字限制，随后因为编码质量回退而撤回。这说明定量约束能压缩文字，却可能让复杂任务缺少必要说明，不能作为唯一机制。[Anthropic 事故复盘](https://www.anthropic.com/engineering/april-23-postmortem)

Codex 的公开实现同样遵循“Final Message 或 ToolCall；有 ToolCall 就继续”的循环。[Codex Agent Loop](https://openai.com/index/unrolling-the-codex-agent-loop/) 的 Prompt 更强调短 Preamble、跳过简单读取的说明，并在协议中区分 Commentary 与 Final Answer。它改善了输出纪律和展示投影，但没有把某个业务完成状态写进基础循环。

DeepSeek Harness 也是标准的模型—工具—模型循环，提供 `tool_choice`、turn limit 和可选 Plan Mode。Plan Mode 用于复杂任务的显式规划，不是专门压制 ToolCall 前文字的机制。为每一轮额外调用一个 Planner，反而会增加延迟和 token。[DeepSeek Tool Calls](https://api-docs.deepseek.com/guides/tool_calls/) 与 [DeepSeek Harness](https://www.deepseek.com/harness/en/)

## 更稳妥的通用设计

这个问题没有一个开关可以完整解决，比较合理的是四层组合。

### 第一层：短而明确的输出纪律

System Prompt 只表达通用规则：

```text
当下一步是调用工具时，直接调用工具。
不要在 ToolCall 前复述输入、附件内容或即将提交的参数。
只有用户必须知道当前动作时才说明，并限制为一句话。
```

这里可以加字数限制辅助模型收敛，但它只是软约束。不要把“25 个词”之类的数字当成正确性保证，也不要要求所有任务绝对静默。

### 第二层：一次性执行意图，而不是业务状态机

当调用方**客观知道下一次模型响应必须使用工具**时，可以传递通用、一次性消费的执行意图：

```ts
type NextResponseToolChoice =
  | "auto"
  | "required"
  | { name: string };
```

Provider Adapter 再把它映射到各模型的 `tool_choice`。关键约束是：它只作用于下一次模型调用，调用后立即恢复 `auto`，不能根据“Draft 是否完成”在基础层持续强制。

这项能力适用于“下一步动作已由上层协议确定”的场景。开放式对话仍使用 `auto`，否则只是把模型的废话问题换成工具死循环。

### 第三层：区分执行投影和用户投影

运行时可以把中间 Commentary、ToolCall、ToolResult 和 Final Answer 分成不同事件。页面导入场景只展示可信的进度元数据和最终 Draft 投影；会话模式可以展示简短 Commentary。

这层负责体验和语义边界，不负责节省模型 token。它的价值是避免把原始执行轨迹直接当成用户结果。

### 第四层：独立的安全边界

无论是否强制 Tool，都需要通用的最大轮数、最大墙钟时间、重复 ToolCall 检测和“连续无状态进展”保护。它们负责终止异常循环，不参与判断某个业务是否完成。

## 先量化，再决定要不要改 Runtime

最小可行的下一步不是引入 Planner，而是增加四个指标：

- `text_tokens_before_first_tool_call`：首次 ToolCall 前生成了多少文本；
- `time_to_first_tool_call`：从请求开始到首次 ToolCall 的时间；
- `mixed_text_tool_message_rate`：同时包含长文本和 ToolCall 的消息比例；
- `tool_argument_truncation_count`：因为长度截断而作废的 ToolCall 数量。

有了这些数据，才能判断问题主要来自 Prompt、模型、Provider 适配，还是特定任务的调用契约。否则调小 token、加 Planner 或强制 Tool 都是在猜。

## 当前结论

针对 ToolCall 前长篇 Assistant Message，当前不应该：

- 在 Pi 基础层加入 Draft 专属状态机；
- 用全局 `max_output_tokens` 充当 Preamble 限制；
- 每轮增加一个 Planner 来猜任务是否完成；
- 只在前端隐藏文字，然后把延迟和 token 成本留在后台。

更合适的顺序是：先用通用 Prompt 禁止参数复述并建立指标；确有确定性调用阶段时，再增加一次性的通用 Tool Choice；展示层按 Commentary、Tool 和 Final 做投影；最后用轮数、时间和无进展检测兜住循环风险。

这套方案没有为某个 Excel、某个 Draft 或某个 ERP 页面写例外规则，才能迁移到后续所有文档导入和 Tool-Heavy Agent 场景。
