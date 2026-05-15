---
title: "一次 NPS SSH 隧道变卡排查：从 banner timeout 到 mux 心跳超时"
date: 2026-05-15 11:32:58
tags:
  - "NPS"
  - "SSH"
  - "排障"
  - "网络"
source_archive:
  id: 20260515-nps-ssh-tunnel-mux-timeout
  rel_path: source_materials/posts/20260515-nps-ssh-tunnel-mux-timeout
  conversation_file: conversation.jsonl
---

远程小电脑通过 NPS 暴露 SSH 入口。现场现象很具体：SSH 连上后，过一段时间开始变卡，随后出现断联；新开一个 SSH 连接时，客户端卡在 banner 阶段，最后报：

```text
Connection timed out during banner exchange
```

这类问题容易被归到三个方向：本机 SSH 配置、云端 NPS、设备侧 4G 网络。最后的结论是：本机到云端跳板没有问题；NPS 服务端确实记录到了目标客户端的 mux 通道异常；更直接的证据偏向设备侧 4G/npc 链路不稳定，同时云端 NPS 的资源状态会放大这个问题。

## 先把链路拆开

这次 SSH 不是直连设备，而是经过一条多段链路：

```text
本机 SSH client
  -> 云端跳板 SSH
  -> NPS 服务端映射端口
  -> 设备侧 npc
  -> 设备本机 sshd:22
```

如果只看最终的 `ssh device` 失败，很难判断是哪一段坏了。排查脚本同时做了三件事：

```text
1. 本机到目标设备：循环新建 SSH 短连接，记录耗时和错误
2. 本机到云端跳板：循环新建 SSH 短连接，作为对照组
3. 长连接探针：保持一条 SSH 会话，每 30 秒输出一次心跳
```

同时在云端和设备侧采集：

```text
云端：NPS 进程、端口、socket 状态、容器日志
设备：负载、内存、路由、4G 网卡状态、npc 进程、sshd 日志
```

脚本有一个细节：探测连接必须关闭 SSH 配置里的本地端口转发。

```bash
ssh \
  -o BatchMode=yes \
  -o ClearAllForwardings=yes \
  -o ConnectTimeout=12 \
  "$target" 'date'
```

如果不加 `ClearAllForwardings=yes`，已有 SSH 会话占用了本地转发端口时，探测连接会因为本地端口绑定失败而退出。这不是远端故障，会污染证据。

## 第一轮证据：不是本机到跳板的问题

故障窗口里，目标设备的短连接失败：

```text
probe_time=10:53:10
Connection timed out during banner exchange
real 12.01
```

同一分钟，云端跳板短连接正常：

```text
probe_time=10:53:22
ssh_ok
real 0.63
```

这一步基本排除了本机网络、本机 SSH 客户端和跳板 SSH 登录问题。更细的 `ssh -vvv` 也印证了这一点：

```text
Authenticated to jump-host
channel_connect_stdio_fwd: 127.x.x.x:50022
channel 0: open confirm
Connection timed out during banner exchange
```

含义是：本机已经登录了跳板，跳板也打开了到 NPS 映射端口的通道，但后面的设备 sshd banner 没有及时回来。

这时候链路可以缩小为：

```text
NPS 服务端映射端口
  -> 设备侧 npc
  -> 设备本机 sshd
```

## 第二轮证据：NPS 收到了连接，但后端通道不健康

云端 NPS 日志里，目标设备对应的客户端可以抽象成：

```text
clientId: N
remark: device-A
server_ip: 127.x.x.x
server_port: 50022
target: 22
```

故障窗口的 NPS 日志是关键：

```text
10:53:11 new tcp connection, local port 50022, client N
10:53:23 new tcp connection, local port 50022, client N
10:53:35 new tcp connection, local port 50022, client N
10:54:12 clientId N connection succeeded
10:55:11 get connection from client id N error create connection fail, the server refused the connection
10:55:23 get connection from client id N error create connection fail, the server refused the connection
10:55:35 get connection from client id N error create connection fail, the server refused the connection
```

这说明 NPS 并不是没收到 SSH 连接。它收到了，而且知道这个连接应该转给哪个 npc 客户端。但它向客户端创建后端连接时失败了。

云端 socket 状态也有对应现象：

```text
映射端口仍然 LISTEN
同一映射端口出现 CLOSE-WAIT / FIN-WAIT-2
```

这类状态不能单独定罪，但和 banner timeout 放在一起看，说明 NPS 端口还在接连接，后端转发通道已经不稳定。

## 第三轮证据：设备本机没有资源耗尽

故障前一轮设备状态正常：

```text
load average: 约 3
内存可用：数 GiB
磁盘使用率：低
npc 进程存在
sshd 进程存在
设备到 NPS 服务端 TCP 端口探测成功
```

这不支持“设备 CPU、内存、磁盘把 sshd 卡死”这个解释。

但它也不能证明 4G 链路没有问题。因为 4G/npc 链路可以出现一种更麻烦的状态：进程还在，TCP 端口偶尔能通，但 mux 数据通道已经半死，新的 SSH banner 回不来。

## 多设备线索：mux 心跳超时

继续看 NPS 容器日志，近两小时出现多次：

```text
mux: ping time out, checktime 61 threshold 60
close mux
```

当时我最开始把它粗略理解成 60 秒超时，后来查了 [`nps-mux` 源码](https://github.com/ehang-io/nps-mux/blob/master/mux.go)后修正了这个判断。

NPS mux 的心跳逻辑大致是：

```go
ticker := time.NewTicker(time.Second * 5)

if pingCheckTime > pingCheckThreshold {
    log.Println("mux: ping time out, checktime", pingCheckTime, "threshold", pingCheckThreshold)
    _ = s.Close()
}

sendInfo(muxPingFlag, ...)
pingCheckTime++
```

也就是说：

```text
心跳检查频率：约每 5 秒一次
threshold=60：允许累计 60 次检查没有有效 ping return
实际判死时间：约 5 分钟
```

日志里的 `checktime 61 threshold 60` 不是第 61 秒，而是第 61 次检查。真正含义是：这条 mux 通道连续约 5 分钟没有收到有效 ping return，NPS 才关闭它。

这比“几十秒小抖动”严重。它更像：

```text
设备侧 npc 到 NPS 的 mux 通道长时间半死
或设备侧网络/进程卡住
或云端 NPS 在压力下没有及时处理心跳
```

## 不能把所有锅都甩给 NPS

云端 NPS 的状态确实不健康：

```text
NPS 容器运行了数月
NPS CPU 长期较高
宿主机 swap 已满
根盘使用率偏高
NPS log_level=debug
映射端口数量很多
```

这些都是风险。它们会放大弱网场景下的转发抖动，也会让连接恢复更慢。

但目前没有直接证据证明“NPS 服务端调度异常导致 ping return 没被处理”。要证明这一点，需要看到更强的服务端侧信号：

```text
同一分钟大量 client 一起 mux timeout
CPU steal / IO wait 飙升
NPS 事件循环或 goroutine 明显堆积
所有设备同时受影响
```

现在看到的 mux timeout 更分散，且不同客户端在不同时间重连。这个形态更偏向各设备侧 4G/npc 链路不稳定。

所以更稳妥的判断是：

```text
已确认：
  多个客户端出现 NPS mux 心跳超时；
  目标设备的 SSH 故障与 NPS 后端连接失败时间对上。

更直接支持：
  设备侧 4G/npc 链路不稳定。

同时成立：
  云端 NPS 压力和配置会放大问题。

尚未证实：
  NPS 因服务端处理异常漏掉 ping return。
```

## 处置建议

短期止血应该从影响面最小的动作开始：

```text
1. 对单台异常设备，优先重启设备侧 npc
2. 如果多台设备集中异常，再考虑重启 NPS 容器
3. 重启 NPS 会影响所有隧道，需要窗口
```

中期要补两个能力。

第一，把健康检查从“进程存在”升级到“端到端可用”：

```text
云端定期连接每个设备的 SSH 映射端口
要求能在限定时间内拿到 SSH banner
拿不到 banner，就判定该设备隧道不可用
触发 npc 重连或告警
```

第二，治理 NPS 服务端压力：

```text
降低 NPS 日志级别，避免长期 debug
清理宿主机磁盘和 swap 压力
观察 NPS CPU、连接数、CLOSE-WAIT / FIN-WAIT-2 数量
评估 NPS/npc 版本升级
```

配置上，`disconnect_timeout` 不应该再被理解成“单个 SSH 命令最多等多久”。它控制的是 NPS 和 npc 之间 mux 通道的失联判定阈值。提高它可以减少弱网下的误杀，但也会延长半死连接的存活时间，不能替代端到端健康检查。

## 半死连接和新建连接不是一回事

这次还有一个容易混淆的点：新开一个 SSH 窗口，不等于新建了一条健康的 NPS 隧道。

链路里有两层连接：

```text
外层：本机新建的 SSH TCP 连接
内层：NPS 服务端和设备侧 npc 之间已经存在的 mux 长连接
```

当执行一次新的 `ssh device` 时，实际过程是：

```text
本机新建 SSH
  -> 连到云端 NPS 的映射端口
  -> NPS 复用已有的 mux 长连接
  -> 请求设备侧 npc 再去连接设备本机 sshd:22
```

所以“新建 SSH 连接”只是在外层新建了连接。它不代表 NPS 和 npc 之间的 mux 长连接也是新的。

这里说的半死连接，指的是底层 mux 通道处在一种不彻底死亡的状态：

```text
进程还在
TCP 连接可能还没被内核判死
NPS 映射端口还能 accept
但数据转发、心跳响应、创建后端连接已经不可靠
```

这时会出现几个看似矛盾的现象：

```text
旧 SSH 窗口偶尔还能回显
新 SSH 连接卡在 banner exchange
NPS 日志里能看到 new tcp connection
但后续 create connection fail 或 server refused
```

这不矛盾。因为新的 SSH 连接仍然要复用那条可能已经半死的 mux 通道。真正能让后续 SSH 恢复健康的动作，是让底层 mux 重新建立：

```text
重启设备侧 npc
重启 NPS 容器
mux 被关闭后 npc 重新连上 NPS
设备网络接口重新拨号
```

只有这些动作让 NPS 和 npc 之间重新建立了 mux 长连接，新建 SSH 才可能真的走上一条健康链路。

所以这次 NPS 日志里的失败点很关键：

```text
get connection from client id N error create connection fail, the server refused the connection
```

它说明外层连接已经来了，NPS 也接到了，但内层 mux 或后端 target 连接创建失败。问题不在“有没有新开 SSH 窗口”，而在“NPS 是否还能通过 mux 成功让 npc 创建到 sshd:22 的后端连接”。

## 这次排查的收获

这类问题最容易误判的地方，是把最终现象当成根因：

```text
SSH 断了 -> 改 SSH keepalive
设备连不上 -> 怀疑设备 sshd
NPS 有 timeout -> 认定 NPS 服务端错
```

这次真正有用的是三端对照：

```text
本机到跳板正常
跳板到 NPS 映射端口能打开
目标 SSH banner 回不来
NPS 日志里对应客户端后端连接失败
NPS mux 日志出现多客户端心跳超时
设备本机资源没有耗尽
```

证据链把问题从“SSH 设置”收敛到了“NPS/npc mux 通道和设备侧网络”。结论不是某一行配置能解决全部问题，而是要同时做两件事：设备侧隧道要能自恢复，云端 NPS 要降低压力并补端到端可用性监控。
