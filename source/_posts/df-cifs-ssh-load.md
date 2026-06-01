---
title: "一次 df 卡在 CIFS 上造成 load 虚高的排障"
date: 2026-06-01 16:36:25
tags:
  - "Linux"
  - "排障"
  - "SSH"
  - "CIFS"
  - "含金量不高"
source_archive:
  id: 20260601-df-cifs-ssh-load
  rel_path: source_materials/posts/20260601-df-cifs-ssh-load
  conversation_file: conversation.jsonl
---

一台现场小电脑的远程操作一度很卡，连接也容易断。第一眼看 CPU 又没有打满：4 核机器，CPU 总负载四成左右，温度正常。但 load average 明显偏高，1 分钟负载接近 5，5 分钟和 15 分钟更高。

排查过程中抓到一个真实异常：远程监控周期性执行的 `df` 卡在一个 CIFS/SMB 网络共享上，多个 `df` 进入 D 状态，把 load average 抬高。后续复测又补了一条重要证据：即使还有 9 个 D 状态 `df`，命令行 SSH 和 iShell 也都能保持顺畅。所以这次更准确的结论不是“`df` 一定导致 SSH 卡死”，而是：`df` 卡网络挂载会制造高 load 和监控误导，但 SSH 卡顿必须单独按链路验证。

## 现象

最初对比两台机器时，现象很不一致：

```text
对照机器：
  CPU 总负载约三成
  load average 大约 1.x
  SSH 登录和命令返回都比较顺

问题机器：
  CPU 总负载约四成
  load average 一度到 8、10 以上
  SSH banner 偶发超时
  登录后命令回显慢，连接容易断
```

如果只看 CPU，很容易误判。CPU 没满不代表系统没堵；但反过来也成立，load 高也不等于交互一定卡死。Linux 的 load average 统计的是正在等待 CPU 的任务，以及 D 状态的不可中断 I/O 等待任务。后者不一定吃 CPU，但会把 load 拉高。

## 第一轮判断

先把问题从应用层拆出去。

```text
本机 SSH 客户端
  -> 跳板机
  -> 目标机器 SSH 端口
  -> SSH banner
  -> 用户认证
  -> shell
```

对照机器能稳定返回 SSH banner，完整命令两三秒返回。问题机器有时能返回，有时在 banner 阶段就超时。这个阶段还没有进入业务服务，Java 和前端都不是第一嫌疑。这里先得到一个阶段性判断：远程链路和 SSH 握手需要单独观察，不能只靠 CPU 或 load 判断。

随后进到机器里看系统状态：

```bash
uptime
vmstat 1 8
ps -eo pid,ppid,stat,wchan:32,pcpu,pmem,comm,args --sort=-pcpu | head
ps -eo pid,ppid,stat,wchan:32,comm,args | awk 'NR==1 || $3 ~ /^D/'
```

关键输出不是 CPU 排名，而是进程状态：

```text
load average: 8.19, 7.47, 13.13
D 状态进程数量明显异常
其中大部分是 df
wchan = wait_for_response
父进程命令里带有远程监控采集脚本的分段标记
```

这说明至少有一类异常不是业务进程，而是监控采集脚本拉起的 `df` 卡住了。

## 为什么 df 会卡

`df` 查的不是一个本地缓存数字。它会遍历挂载表，对每个挂载点调用 `statfs/statvfs`，向对应文件系统查询容量。

本地盘通常很快：

```text
df
  -> 本地 ext4 / nvme
  -> 内核直接返回容量
```

但网络盘不一样：

```text
df
  -> 扫到 /mnt/share
  -> 这是 CIFS/SMB 网络共享
  -> 内核 CIFS 客户端向远端文件服务器请求容量信息
  -> 远端响应慢、会话异常或网络抖动
  -> df 卡在内核等待 wait_for_response
  -> 进程进入 D 状态
```

当时问题机器上有一个类似这样的挂载：

```text
/mnt/share //fileserver/reports cifs rw,...
```

这里的共享容量显示几百 GB，不代表本机真的有这么大空间，也不是目录实际文件大小。`df` 显示的是这个 SMB 共享所在卷返回的文件系统容量。要看目录实际占用应使用 `du`，但对网络共享跑递归 `du` 风险更高，可能比 `df` 更容易拖慢系统。

## D 状态会不会拖慢 SSH

D 状态不是“占满 CPU”。它通常不怎么消耗 CPU，但它有几个麻烦点：

```text
1. 计入 load average
2. 普通 kill 不一定立即生效
3. 占着进程、文件描述符、父进程等待关系和内核 I/O 等待链路
4. 如果监控持续拉起新 df，会不断堆积
```

单个 `df` 卡住不一定会让机器不可用。真正危险的是周期性采集没有超时、没有去重：

```text
第 1 次采集 -> df 卡住
第 2 次采集 -> 又启动一个 df，也卡住
第 3 次采集 -> 再启动一个 df
...
```

几分钟后，D 状态 `df` 可能堆到十几个。4 核机器上，CPU 可能还只有四成，但 load 已经十几。

不过这一步不能直接推出“SSH 一定卡”。SSH 的交互需要 `sshd` 调度、PTY 读写、shell fork、日志写入和网络收发。只有当 D 状态等待影响到这些关键路径，或者监控采集在客户端/服务端持续堆积，交互才会明显变慢。后来复测时，问题机器仍然有 9 个 D 状态 `df`，但命令行 SSH 和 iShell 都能顺畅使用，这说明 `df` 更像是 load 虚高和监控噪音的来源，而不是 SSH 卡顿的充分条件。

这也是这次排障里最需要修正的地方：

```text
错误简化：
  D 状态 df 多 -> SSH 一定卡

更准确：
  D 状态 df 多 -> load 会虚高，系统存在网络文件系统等待
  SSH 是否卡 -> 还要看 banner、登录耗时、命令返回耗时、客户端采集是否堆积
```

## 清理动作

这次只清理采集进程，不动挂载。

先看卡住的采集：

```bash
ps -eo pid,ppid,stat,wchan:32,comm,args \
  | awk 'NR==1 || /---MONITOR_SECTION---/ || ($5 == "df" && /df -P -B1/)'
```

再按特征杀掉监控脚本和它拉起的 `df`：

```bash
ps -eo pid=,comm=,args= | awk '
  $2 == "sh" && index($0, "---MONITOR_SECTION---") > 0 {print $1}
  $2 == "df" && index($0, "df -P -B1") > 0 {print $1}
' | xargs -r kill -TERM

sleep 2

ps -eo pid=,comm=,args= | awk '
  $2 == "sh" && index($0, "---MONITOR_SECTION---") > 0 {print $1}
  $2 == "df" && index($0, "df -P -B1") > 0 {print $1}
' | xargs -r kill -KILL
```

清理前后变化：

```text
清理前：
  D_total=14
  D_df=13
  collector_shell=13
  collector_df=13

清理后：
  D_total=1
  D_df=0
  collector_shell=0
  collector_df=0
```

复查挂载仍然存在：

```bash
findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS /mnt/share
```

这一步只清理进程，不卸载 CIFS 共享。load average 会按 1/5/15 分钟窗口慢慢回落，不会立刻归零。

后续又观察到，这些 `df` 会重新由监控采集拉起并进入 D 状态，但在同一时间 SSH 和 iShell 可以很顺。这证明清理动作只能作为临时止血或降低 load 噪音，不能当作“修复 SSH 卡顿”的充分证据。

## 后续改法

临时止血是清理卡住的采集进程。长期应该改监控采集策略，避免让 load 指标被网络挂载污染。

安全一些的磁盘采集方式：

```bash
# 排除网络文件系统
timeout 3 df -hT -x cifs -x smb3 -x nfs -x fuse

# 或者只查本地关键挂载点
timeout 3 df -h /
timeout 3 df -h /home
```

监控侧还应该保证：

```text
上一轮采集没结束，不启动下一轮
所有外部命令都有 timeout
默认排除 cifs/nfs/fuse/smb 等网络或用户态文件系统
采集失败返回降级数据，而不是无限堆进程
```

这次问题的核心不是 `df` 危险，也不是“看到 D 状态就认定机器卡死”。更准确的经验是：

```text
周期性监控 + 全量 df + 网络挂载 + 无超时/无去重
  -> 容易制造 D 状态进程
  -> 容易让 load average 失真
  -> 可能放大交互问题，但不必然导致 SSH 卡死
```

CPU 不高但 load 高时，第一反应不该只盯业务进程，也不该直接下结论。先看 D 状态和 `wchan`，再单独测 SSH banner、登录耗时和命令返回耗时。指标解释和链路验证要分开做。
