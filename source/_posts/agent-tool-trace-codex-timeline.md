---
title: "把 Agent 工具调用收成一条 Codex 轨迹"
date: 2026-08-20 16:13:00
description: "把用户问题、工具调用和助手结果组合成可展开的 Codex 风格轨迹，并说明 Pi、Java Gateway 与页面事件投影的真实链路。"
categories:
  - "AI"
tags:
  - "AI Agent"
  - "Pi"
  - "Java Runtime"
  - "Tool Use"
  - "产品设计"
  - "AI工作日志"
source_archive:
  id: 20260820-agent-tool-trace-ui
  rel_path: source_materials/posts/20260820-agent-tool-trace-ui
  conversation_file: conversation.jsonl
---

一轮 Agent 对话可能连续调用多个工具。旧页面把每次调用都显示成一张大卡片，8 次调用就能占满一屏，最终业务结果反而被推到下面。

这次选择的是 A：Codex 轨迹。下面把用户问题、工具过程和助手结果放进同一次对话；演示默认展开，便于看清三者关系，真实产品仍在任务结束后收成一句“已调用 8 个工具”。

<style>
  .agent-conversation-demo {
    display: grid;
    gap: 20px;
    margin: 24px 0 30px;
    padding: 24px;
    border: 1px solid #e1e7f0;
    border-radius: 20px;
    background: linear-gradient(180deg, #f7f9fd 0%, #f1f5fb 100%);
  }
  .agent-demo-turn {
    display: flex;
    width: min(78%, 620px);
    flex-direction: column;
    gap: 6px;
  }
  .agent-demo-turn.user {
    justify-self: end;
    align-items: flex-end;
  }
  .agent-demo-turn.assistant { align-items: flex-start; }
  .agent-demo-role {
    color: #8993a5;
    font-size: 12px;
    font-weight: 600;
  }
  .agent-demo-bubble {
    padding: 13px 16px;
    border: 1px solid #dfe5ef;
    border-radius: 15px;
    background: rgba(255, 255, 255, 0.96);
    color: #344054;
    font-size: 14px;
    line-height: 1.7;
    box-shadow: 0 8px 22px rgba(28, 39, 58, 0.05);
  }
  .agent-demo-bubble p { margin: 0; }
  .agent-demo-turn.user .agent-demo-bubble {
    border-color: #d3def6;
    background: #e7efff;
    color: #2f3f5d;
  }
  .agent-demo-process {
    display: grid;
    width: min(92%, 760px);
    gap: 6px;
  }
  .agent-trace-demo {
    --trace-border: #dfe5ef;
    --trace-text: #4c596c;
    --trace-muted: #8b95a5;
    margin: 0;
    overflow: hidden;
    border: 1px solid var(--trace-border);
    border-radius: 14px;
    background: rgba(255, 255, 255, 0.94);
    box-shadow: 0 12px 30px rgba(28, 39, 58, 0.06);
  }
  .agent-trace-demo summary {
    display: flex;
    min-height: 46px;
    align-items: center;
    gap: 9px;
    padding: 0 14px;
    color: #2f3b4e;
    cursor: pointer;
    list-style: none;
    user-select: none;
  }
  .agent-trace-demo summary::-webkit-details-marker { display: none; }
  .agent-trace-demo summary:focus-visible {
    outline: 2px solid rgba(53, 104, 212, 0.48);
    outline-offset: -3px;
  }
  .agent-trace-demo .trace-check {
    color: #526277;
    font-weight: 800;
  }
  .agent-trace-demo .trace-title {
    font-size: 14px;
    font-weight: 650;
  }
  .agent-trace-demo .trace-count,
  .agent-trace-demo .trace-warning {
    font-size: 12px;
    font-weight: 500;
  }
  .agent-trace-demo .trace-count { display: none; color: var(--trace-muted); }
  .agent-trace-demo .trace-warning { margin-left: auto; color: #9a6a16; }
  .agent-trace-demo .trace-chevron {
    margin-left: 3px;
    color: #7f8a9d;
    transition: transform 160ms ease;
  }
  .agent-trace-demo[open] .trace-title::before { content: "处理过程"; }
  .agent-trace-demo:not([open]) .trace-title::before { content: "已调用 8 个工具"; }
  .agent-trace-demo[open] .trace-count { display: inline; }
  .agent-trace-demo[open] .trace-warning { display: none; }
  .agent-trace-demo[open] .trace-chevron { transform: rotate(180deg); }
  .agent-trace-demo .trace-note {
    margin: 0 14px 10px 37px;
    color: #6c7890;
    font-size: 13px;
    line-height: 1.6;
  }
  .agent-trace-demo .trace-timeline {
    position: relative;
    margin: 2px 15px 15px 25px;
    padding-left: 22px;
  }
  .agent-trace-demo .trace-timeline::before {
    position: absolute;
    top: 9px;
    bottom: 9px;
    left: 6px;
    width: 1px;
    background: #dde3ed;
    content: "";
  }
  .agent-trace-demo .trace-step {
    position: relative;
    display: flex;
    min-height: 32px;
    align-items: baseline;
    gap: 12px;
    color: var(--trace-text);
    font-size: 13px;
    line-height: 1.5;
  }
  .agent-trace-demo .trace-step::before {
    position: absolute;
    top: 2px;
    left: -22px;
    display: grid;
    width: 13px;
    height: 13px;
    place-items: center;
    border-radius: 50%;
    background: #f7f9fc;
    color: #647186;
    content: "✓";
    font-size: 9px;
    font-weight: 800;
  }
  .agent-trace-demo .trace-step span { flex: 1; }
  .agent-trace-demo .trace-step small {
    color: #9aa3b1;
    white-space: nowrap;
  }
  .agent-trace-demo .trace-step.failed { color: #7e621f; }
  .agent-trace-demo .trace-step.failed::before {
    background: #fff5da;
    color: #b07912;
    content: "!";
  }
  @media (max-width: 560px) {
    .agent-conversation-demo { padding: 16px; }
    .agent-demo-turn,
    .agent-demo-process { width: 94%; }
    .agent-trace-demo .trace-warning { display: none; }
    .agent-trace-demo .trace-step { gap: 6px; }
  }
</style>

<div class="agent-conversation-demo" aria-label="用户、工具轨迹与助手结果组成的完整对话示例">
  <div class="agent-demo-turn user">
    <span class="agent-demo-role">用户</span>
    <div class="agent-demo-bubble">
      <p>帮我查一下物料 A 最近的库存变化，并总结最近一次入库情况。</p>
    </div>
  </div>

  <div class="agent-demo-process">
    <span class="agent-demo-role">助手 · 处理过程</span>
    <details class="agent-trace-demo" open>
      <summary aria-label="展开或收起工具调用过程">
        <span class="trace-check">✓</span>
        <span class="trace-title"></span>
        <span class="trace-count">8 个工具</span>
        <span class="trace-warning">1 个未完成</span>
        <span class="trace-chevron">⌄</span>
      </summary>
      <p class="trace-note">已核对物料库存、库存变化和最近入库记录。</p>
      <div class="trace-timeline">
        <div class="trace-step"><span>查询物料库存</span><small>完成</small></div>
        <div class="trace-step"><span>查询库存变化</span><small>完成</small></div>
        <div class="trace-step"><span>核对仓库信息</span><small>完成</small></div>
        <div class="trace-step failed"><span>读取一项业务记录</span><small>未完成</small></div>
        <div class="trace-step"><span>查询采购入库</span><small>完成</small></div>
        <div class="trace-step"><span>查询调拨记录</span><small>完成</small></div>
        <div class="trace-step"><span>汇总最近入库记录</span><small>完成</small></div>
        <div class="trace-step"><span>生成结果摘要</span><small>完成</small></div>
      </div>
    </details>
  </div>

  <div class="agent-demo-turn assistant">
    <span class="agent-demo-role">助手</span>
    <div class="agent-demo-bubble">
      <p>已完成库存、库存变化和最近入库记录的查询。其中一项历史业务记录未读取成功，但不影响本次库存结论。</p>
    </div>
  </div>
</div>

## 为什么不用一堆工具卡片

工具过程是辅助信息，不是页面主角。用户首先要看业务结果，只有在等待、核对或排错时才需要过程。

因此这版只保留三条原则：

- 结果优先：执行结束自动收起，不挤压最终回答。
- 过程可解释：只显示业务名称和完成状态，不展示隐藏推理、调用参数、原始返回值或内部英文工具名。
- 异常不隐藏：收起态保留未完成数量，展开后能定位具体步骤。

## 这不是 Prompt 补丁

轨迹来自结构化事件，不靠模型临时组织文案。当前链路是：

```text
Pi Agent Runtime
  └─ tool_execution_start / tool_execution_end
       ↓ SSE
Java Gateway
  └─ 注入可信业务上下文并透传事件
       ↓
页面事件投影
  ├─ 按 toolCallId 合并开始与结果
  ├─ 读取安全的 presentation 文案
  └─ 把连续工具消息组成一条轨迹
       ↓
运行时展开，agent_settled 后收起
```

Pi 在真正执行工具前发出 `tool_execution_start`，完成后用同一个 `toolCallId` 发出 `tool_execution_end`。Java Gateway 不改写过程语义，只处理可信上下文和流式转发。页面拿到事件后，才负责状态合并、文案投影和视觉分组。

这样做的关键是职责没有压进 Prompt：工具提供安全的 `details.presentation`，运行时提供事实事件，页面负责展示。即使模型换了表达方式，工具轨迹仍然稳定。

## 状态与边界

轨迹只需要三种状态：进行中、完成、未完成。开始事件先建立进行中步骤；结束事件关闭同一条步骤；会话稳定后，整组轨迹默认收起。

系统通知、网络错误和模型错误不会伪装成工具，也不会进入“已调用 X 个工具”的计数。历史消息同样只读取持久化的安全展示字段，避免刷新页面后泄露原始参数。

当前实现按一轮对话中连续出现的真实工具消息分组，它不是工作流 DAG，也不试图展示模型思维链。这个边界刻意保持简单：足够解释“系统做了什么”，但不把调试日志直接交给普通用户。

## 验证结果

- Java 侧 9 个聚焦测试通过。
- 页面事件投影测试通过。
- 页面生产构建通过。

最终变化很直接：8 张纵向卡片变成一行摘要；需要时仍能展开查看完整过程，最终业务回答重新成为页面主视觉。
