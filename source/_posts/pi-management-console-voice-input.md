---
title: "Pi 管理台语音输入：把音频停在 Java，把文本交给 Pi"
date: 2026-08-12 17:12:29
categories:
  - "AI"
tags:
  - "Pi"
  - "Java Runtime"
  - "语音识别"
  - "阿里云百炼"
  - "SSE"
  - "AI工作日志"
source_archive:
  id: 20260812-pi-management-console-voice-input
  rel_path: source_materials/posts/20260812-pi-management-console-voice-input
  conversation_file: conversation.jsonl
---

管理台的语音输入最后没有做成“浏览器把音频交给 Pi，再让模型处理”。实际链路是：浏览器录音，Java 调用阿里云百炼转成文字，文字回填输入框；用户确认后，才按原有 SSE 对话链路交给 Pi。

这个拆分很重要：Pi 负责 Agent 会话、Tool 调用和模型回复；Java 负责 ERP Gateway 已有的鉴权、部署配置和外部 ASR 调用。音频不是 Pi 会话的一部分，也不会进入 LLM 上下文。

## 最终链路

```text
浏览器 Management Console
  │ 1. MediaRecorder 录音
  ▼
Pi 管理台代理 ──► Java Gateway ──► 阿里云百炼非实时 ASR
  ▲                    │
  └──── { text } ◄─────┘

浏览器输入框（用户可修改）
  │ 2. 用户点击“发送”
  ▼
Pi 管理台代理 ──► Java Gateway ──► Pi /ai/conversations（SSE）
                                          │
                                          ▼
                                  Pi AgentSession ──► 模型 / ERP MCP Tool
```

管理台静态页面由 Pi Runtime 托管，但浏览器访问 `/api/ai/**` 时，Pi 的 HTTP 层会先转发给 Java Gateway。对话请求再由 Java Gateway 带上可信业务上下文，转发回 Pi 的内部会话接口。这个双向代理看似多了一跳，换来的是：浏览器从不持有 Runtime 的内网凭据，Java 仍是 ERP 身份和外部服务密钥的唯一边界。

## 为什么不直接把音频发给 Pi

这不是 Pi 不支持语音，而是这次产品路径不需要让 Pi 处理音频。

Pi 当前运行的是文本和图片会话。图片在 Pi HTTP 边界做 `processImage` 预处理后，作为原生 `images` 参数传入 `AgentSession`；如果把音频也塞进这条路径，就要额外选择支持音频的模型、定义音频在 Session JSONL 中的存储形式，并处理后续追问是否携带原音频。

本次需求是“转写后先填入输入框，用户确认再发送”。因此把 ASR 当作输入法能力更直接：Java 得到音频后只返回一段文本，Pi 看到的仍然是原本就支持的文字消息。音频不写入 Pi 会话 JSONL，也不会被带进 ERP Tool 调用。

这是当前项目的设计判断，不是 Pi 的通用限制。若以后需要让模型直接理解会议录音、语音中的环境声或多说话人信息，再单独设计音频多模态会话，而不是把它混入本次的文本输入流程。

## 浏览器：录音不等于发送

入口在 `packages/java-agent-runtime/manage-console/src/useLiveDebugTransport.ts`。这个 Hook 同时管理管理台的文本、图片、录音状态和 SSE 对话，但语音和发送是两条连续而独立的动作。

点击“语音输入”后，`toggleLiveRecording()` 会：

1. 用 `navigator.mediaDevices.getUserMedia({ audio: true })` 请求麦克风权限；
2. 按 `webm/opus`、`ogg/opus`、`mp4` 的顺序选择浏览器实际支持的 `MediaRecorder` 格式；
3. 收集录音分片，录满 5 分钟自动停止；
4. 停止后调用 `transcribeRecordedChunks()`，将 `Blob` 作为 `multipart/form-data` 的 `audio` 字段提交。

```ts
const formData = new FormData();
formData.append("audio", audio, audio.name);

const response = await apiFetch<{ text: string }>("/api/ai/asr/transcriptions", {
  method: "POST",
  body: formData,
});

setLiveInput((current) => (current.trim() ? `${current}\n${response.text.trim()}` : response.text.trim()));
```

这里没有调用 `handleLivePrimaryAction()`。转写结果只追加到输入框，发送按钮仍由用户点击或按 Enter 触发。录音或转写进行时，发送和图片附件都会被禁用，避免一段尚未完成的输入与另一轮 Pi 会话交叉。

浏览器侧限制是 5 分钟、原始音频 7 MiB。百炼接口接收的是 Base64 Data URI，编码后会比原始二进制大；把原文件控制在 7 MiB，是为其 10 MiB 的输入上限预留 JSON 和协议开销。组件卸载、重置会话或录音失败时，代码会停止 `MediaStream` 的所有轨道，避免浏览器继续占用麦克风。

## Java：把音频变成稳定的文本接口

浏览器请求先经过 Pi 的 `proxyJava()`，再到 Java 的 `AiController#transcribeAudio()`：

```java
@PostMapping(value = "/asr/transcriptions", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
public ResponseEntity<Map<String, String>> transcribeAudio(
    @RequestParam(value = "audio", required = false) MultipartFile audio,
    HttpServletRequest request
) {
    AiBizPrincipal principal = resolvePrincipal(request);
    String text = aliyunAsrService.transcribe(audio, principal.getTraceId());
    return ResponseEntity.ok(Collections.singletonMap("text", text));
}
```

`resolvePrincipal()` 仍然走 Java Gateway 的既有身份解析。转写接口使用 `traceId` 记录可排查日志，但不会记录音频内容、Base64 内容或 API Key。

真正调用百炼的是 `AliyunAsrService#transcribe()`，它在请求离开 Java 前做四件事：

1. 校验文件存在、大小和 MIME 类型；目前接受 `webm`、`ogg/opus`、`m4a`、`mp3`、`wav`；
2. 用有界读取限制真实字节数，不能只相信 multipart 的 `Content-Length`；
3. 将音频编码为 `data:<mime>;base64,...`，调用 `fun-asr-flash-2026-06-15`；
4. 设置 `X-DashScope-SSE: disable`，只取最终的 `output.text`，不再维护另一条 ASR SSE 状态机。

ASR 的 API Key 只放在 Java 的 Nacos 或部署密钥中，例如：

```yaml
ai:
  asr:
    api-key: "<DashScope API Key>"
```

Pi 的 `.env` 不需要、也不应该保存这把 Key。当前实现提供了百炼兼容地址、模型和超时的默认值；如果配置是在服务启动后才改动，重启 Java 服务使 `@Value` 重新注入即可。

## 文本确认后，才进入 Pi AgentSession

用户点击发送后，还是 `useLiveDebugTransport.ts` 的 `handleLivePrimaryAction()`。它将纯文字组织成原有 JSON 请求，并固定通过 `apiStream()` 请求 SSE：

```ts
await apiStream(path, { method: "POST", body: JSON.stringify({ query }) }, {
  onEvent: handleSseEvent,
});
```

`apiStream()` 显式设置 `Accept: text/event-stream`，逐帧解析 `event:` 和 `data:`。Pi Runtime 的 `streamConversation()` 将 Pi `AgentSession` 事件投影为管理台可消费的 SSE 事件：

- `conversation_started`：已创建会话；
- `answer_delta`：模型文本增量；
- `tool_call` / `tool_result`：ERP MCP Tool 生命周期；
- `final`：最终回答；
- `conversation_failed`：本轮失败。

在 Runtime 内，`PiConversationRuntime#runConversation()` 最终调用的是：

```ts
await session.prompt(input.query, {
  source: "rpc",
  images: input.images.length > 0 ? input.images : undefined,
});
```

因此语音转写后的内容和用户手工输入的文字，对 Pi 来说没有区别。Pi 继续负责 Session JSONL、Agent loop、模型调用、MCP Tool 和 SSE 事件；Java ASR 完成任务后就退出链路。

## 验证和边界

这次实现保留了两类聚焦测试：

- Java ASR 测试用本地 HTTP Server 验证请求头、`data:` URI、模型参数和转写结果解析；也验证超限音频会在调用百炼前被拒绝。
- Controller 测试验证转写接口只返回文本，并且不会调用创建或续聊 Pi 会话的 Gateway 方法。

提交前还执行了 Pi 的 `npm run check` 和 Java 聚焦测试。

当前版本刻意不做实时识别、OSS 存储和音频会话持久化。它适合“短语音转文字，再确认发送”的 ERP 对话输入。等需求变成边说边出字、保存录音审计，或让模型直接理解音频时，再分别引入实时 ASR、对象存储和音频多模态会话设计；它们不该被提前塞进这一条简单输入链路。
