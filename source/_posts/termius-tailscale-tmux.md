---
title: "用 iPhone 远程操控 Mac：Termius + Tailscale + tmux（Codex 常驻）"
date: 2026-02-18 00:00:00
permalink: guides/termius-tailscale-tmux/
tags:
  - "工具技巧"
  - "远程办公"
---

## 目标

用 iPhone 的 Termius 远程连接 Mac，借助 Tailscale 组网，实现随时随地安全 SSH；用 tmux 保持会话不断线（适合常驻跑 Codex）。

## 组件

- Termius：iOS SSH 客户端
- Tailscale：内网组网（避免端口映射）
- tmux：会话常驻

## Mac：开启 SSH

系统设置 → 通用 → 共享 → 远程登录（Remote Login）打开。

## Termius：生成 SSH Key 并配置

1. Termius → Keychain → + → Generate Key → Ed25519
2. 复制 Public Key（ssh-ed25519 ...）
3. Mac 追加到 `~/.ssh/authorized_keys`：

```bash
nano ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

## Tailscale：同账号组网

- Mac 安装并登录官方 Tailscale.app
- iPhone 安装并登录 Tailscale，开启 VPN
- 记下 Mac 的 Tailscale IP（100.x.y.z）或 MagicDNS

## Termius：添加 Host

- Host：Mac 的 100.x 或 MagicDNS
- Port：22
- Username：你的 macOS 用户名
- Auth：选择 Key

## tmux：保持会话

```bash
brew install tmux
tmux new -As codex
```

常用：`Ctrl-b` 后按 `d` 断开但保留会话。

## macOS 权限坑（Desktop：Operation not permitted）

如果 SSH 会话访问 `~/Desktop` 报 `Operation not permitted`，这是 macOS 隐私保护。

- 方案 1（推荐）：把工作目录放到 `~/Work` 而不是 Desktop
- 方案 2：系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 添加 `/usr/sbin/sshd`，然后重新连接

