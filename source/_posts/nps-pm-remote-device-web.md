---
title: "把 NPS/NPC 隧道接进管理平台：小电脑 Web 页面的动态代理与 iframe 踩坑"
date: 2026-09-22 11:50:05
categories:
  - "后端"
tags:
  - "NPS"
  - "Nginx"
  - "WebSocket"
  - "Spring Boot"
  - "Vue"
  - "运维"
source_archive:
  id: 20260922-nps-pm-remote-device-web
  rel_path: source_materials/posts/20260922-nps-pm-remote-device-web
  conversation_file: conversation.jsonl
---

我们有一批部署在客户现场的小电脑，每台机器都运行自己的 Web 页面，入口是 `localhost:80`。中心服务器已经部署 NPS，各小电脑运行 NPC，SSH、VNC 和 HTTP 都能通过 TCP 隧道回到中心服务器。运维人员原先可以登录中心服务器，再访问某台设备的映射地址；业务人员无法在管理平台里直接打开这些页面。

这次开发把已有隧道接进了管理平台：用户选择设备后，页面用 iframe 打开该设备的 Web 系统，静态资源、HTTP API 和 WebSocket 都继续工作。最终没有修改 NPC，也没有为每台设备生成一份 Nginx 配置。新增部分集中在一段 NPS 状态同步脚本、一个动态 Nginx `map`、一个 Spring Boot 投影接口和一个 Vue 页面。

## 开发前已有的基建

NPS/NPC 已经承担了设备网络入口。每台小电脑主动连接中心服务器，所以客户现场不需要开放入站端口。已有管理脚本根据设备表为每个 NPC 创建三条 TCP 隧道：

| 中心侧端口 | 小电脑目标 | 用途 |
| --- | --- | --- |
| `50022` | `localhost:22` | SSH |
| `50023` | `localhost:5900` | VNC |
| `50024` | `localhost:80` | Web 页面 |

不同设备绑定不同的中心侧映射 IP，因此可以复用同一组端口。链路类似这样：

```text
运维终端 -> 10.20.3.36:50022 -> NPS -> NPC -> 小电脑 localhost:22
运维终端 -> 10.20.3.36:50023 -> NPS -> NPC -> 小电脑 localhost:5900
中心服务器 -> 10.20.3.36:50024 -> NPS -> NPC -> 小电脑 localhost:80
```

这里的映射 IP 只在中心侧网络有意义。浏览器直接打开 `10.20.3.36` 会从用户电脑自己的路由出发，并不会自动经过中心服务器。管理平台需要一个浏览器可达的入口，再由中心服务器把请求送进 NPS。

已有 NPS 管理脚本还能调用管理 API 创建和删除隧道，但它承担的是“期望配置”管理，权限也比较高。管理平台的远程页面只需要读取当前运行状态，没有必要持有 NPS 管理凭据。最终同步任务直接只读 NPS 容器卷中的 `tasks.json`，把写权限和管理 API 留在原来的运维边界。

## 为什么选择设备子域名

最早考虑过路径代理：

```text
https://pm.example.com/remote/AT_1000_0001/
```

小电脑页面并不知道自己被挂在 `/remote/.../` 下面。它会继续请求根路径资源：

```text
/assets/index.js
/local-api/...
/cloud-api/...
/api-ws/...
```

路径代理需要重写 HTML、静态资源地址、接口前缀和 WebSocket 地址。不同版本的小电脑页面只要多出一个根路径，规则就可能漏掉。每台设备使用独立子域名后，页面仍运行在 `/`：

```text
https://at-1000-0001.remote.example.com/
https://at-1000-0002.remote.example.com/
```

浏览器同源策略不会阻止 iframe 展示另一个 origin。父页面不能直接读取 iframe 内部 DOM，但用户仍可在 iframe 里点击和输入。设备页面的脚本、接口和 WebSocket 全部留在同一个设备子域名下，也不需要把 CORS 放宽给管理平台。

完整访问链路变成：

```text
管理平台
  -> GET /deviceRemoteAccess/list
  -> 返回 PID、在线状态和 remoteUrl
  -> iframe 打开 https://<pid>.remote.example.com/
  -> DNS 解析到中心服务器 VPC 地址
  -> Nginx 按 Host 查询 upstream
  -> 10.20.x.x:50024
  -> NPS/NPC
  -> 小电脑 localhost:80
```

PID 经过小写和字符归一化后作为域名前缀。例如 `AT_1000_0001` 转成 `at-1000-0001`。URL 保留 PID 信息，排障时能直接从域名定位设备，也省掉了第一版并不需要的 session 路由。

## 从 NPS 状态生成两份投影

手工维护少量 JSON 可以验证页面，但设备规模上来后，手工同步 NPS、Nginx 和管理平台清单很快会失控。最终增加了一个每分钟运行的 oneshot 任务：

```text
NPS tasks.json
  -> 筛选 Target=80 且已启用的 TCP 隧道
  -> 从 Client.Remark 提取 PID
  -> 读取 ServerIp、Port、Client.IsConnect
  -> 按 PID 去重，重复时优先在线隧道
  -> 生成 Nginx Host map
  -> 生成管理平台 JSON
```

Nginx 投影只关心路由：

```nginx
map $host $device_upstream {
    default "";
    at-1000-0001.remote.example.com 10.20.3.36:50024;
    at-1000-0002.remote.example.com 10.20.3.37:50024;
}
```

管理平台 JSON 保存 PID、映射地址、端口、在线状态和域名参数。Spring Boot 接口每次请求都重新读取外部 JSON，再生成 `remoteUrl`。NPS 新增设备后，定时任务下一轮更新文件，管理服务无需重启。

同步脚本没有每分钟无条件覆盖文件。新内容与旧内容一致时直接跳过；有变化时先原子替换临时文件，再运行 `nginx -t`。校验失败会恢复旧 map，不执行 reload。这样既避免 Nginx 每分钟重载，也不会因为一条坏记录打断全部远程入口。

## Nginx 如何承接整站和 WebSocket

Nginx 配置保持一个泛域名 `server`，设备差异全部放在 `map` 中：

```nginx
map_hash_max_size 4096;
map_hash_bucket_size 128;
include /etc/nginx/conf.d/remote-map.generated;

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 80;
    server_name *.remote.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name *.remote.example.com;

    ssl_certificate /etc/letsencrypt/live/remote.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/remote.example.com/privkey.pem;

    if ($device_upstream = "") {
        return 404;
    }

    location / {
        proxy_pass http://$device_upstream;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
```

`Upgrade` 和 `Connection` 头决定 WebSocket 能否从浏览器穿过 Nginx。设备前端使用同源相对地址 `/api-ws/...`，HTTPS 页面会建立安全 WebSocket，再由 Nginx 把升级请求转给小电脑。长连接同时需要放宽读写超时并关闭缓冲。

没有登记的 Host 返回 404，避免未知子域名落到默认后端。`baseDomain` 也只存在于远程访问 JSON 和同步脚本中，没有复用全局域名配置，因此不会改变中心服务器上的其他站点。

## DNS 配置与访问边界

DNS 只需要一条泛解析：

```text
记录类型：A
主机记录：*.remote
记录值：中心服务器的 VPC 私网地址，例如 10.0.0.20
```

外部 DNS 即使返回这个私网地址，普通公网客户端也没有到 VPC 的路由，连接不会到达服务器；接入公司 VPN 或位于同一 VPC 的客户端才能访问。使用 PrivateZone 会进一步避免向公网 DNS 暴露私网地址，访问路径不变。

记录值也可以用 CNAME 指向一个最终解析到 VPC 私网地址的内部域名。CNAME 只减少 IP 变更时的维护点，不会赋予公网客户端 VPC 路由能力。

## 几个实际踩过的坑

### 1. NPS 的目标端口和服务端监听端口不是一回事

`Target=80` 表示 NPC 最终访问小电脑的 80 端口，中心服务器真正连接的是 NPS 隧道的 `ServerIp:Port`。这次 HTTP 隧道的服务端端口是 `50024`。初版把 upstream 写成映射 IP 的 `:80`，请求自然不通。

### 2. `map` 不能放进 `server`

Nginx 的 `map` 只能出现在 `http` 上下文。生成文件也不能取 `.conf` 后缀后再同时被顶层通配 include，否则会加载两次。最终生成文件命名为 `remote-map.generated`，由固定配置在 `server` 之前显式 include。

### 3. 一台设备一份 Nginx 配置扩展性太差

现场已有百余条设备隧道，逐台生成 `server` 块会让配置和 reload 管理迅速膨胀。一个泛域名 `server` 加一个动态 `map` 已经足够，新增设备只增加一行 Host 到 upstream 的映射。

### 4. HTTPS 主站不能嵌 HTTP iframe

远程页面最初使用 HTTP。单独在新窗口打开一直正常，放进 HTTPS 管理平台后却是空白。设备页面没有 `X-Frame-Options`，也没有 CSP `frame-ancestors` 限制，浏览器真正拦截的是 Mixed Content：HTTPS 父页面不能嵌入 HTTP 子页面。

修复链路如下：

```text
原链路：HTTPS 管理平台 -> HTTP iframe -> 浏览器拦截
新链路：HTTPS 管理平台 -> HTTPS 设备子域名 -> Nginx -> HTTP 内网 upstream
```

TLS 终止在中心服务器即可，NPS 到小电脑仍可使用内网 HTTP。修复后验证到首页 `200`、HTTP 入口 `301`、静态资源正常加载，WebSocket 握手返回 `101 Switching Protocols`，iframe 内的登录输入框可以实际操作。

### 5. 泛域名证书只覆盖一层

已有的 `*.example.com` 可以覆盖 `pm.example.com`，不能覆盖 `device.remote.example.com`。远程入口必须申请 `*.remote.example.com` 证书。Let's Encrypt 的泛域名证书需要 DNS-01 校验，手工添加 TXT 能完成首次签发，却不能无人值守续期。

现有 Certbot 定时器只负责“到期前尝试续期”。DNS 校验仍需要一段具备最小 AliDNS 权限的 hook，自动创建 `_acme-challenge.remote`、等待解析、完成校验后删除记录，再执行 `nginx -t` 和 reload。实例 RAM 角色比长期 AccessKey 更适合服务器任务；在这项权限配置完成前，证书续期仍是明确的运维欠账。

## 当前实现的边界

这套能力提供的是“浏览器访问小电脑 Web 页面”，没有扩展成 SSH 终端、远程桌面或通用代理平台。NPS 仍负责隧道，Nginx 只做 Host 路由，Spring Boot 只输出管理平台需要的设备投影，Vue 只负责选择设备和承载 iframe。

同步任务直接读取 NPS 本机数据文件，省掉了管理 API 凭据和额外网络调用，也意味着它必须和 NPS 部署在同一台服务器。未来 NPS 独立部署时，替换数据源即可；Nginx map、管理平台接口和 iframe 地址都不需要跟着重写。

最终维护面只有四个：NPS 隧道状态、每分钟同步任务、泛域名 DNS/证书和一份 Nginx 入口。这个范围足以覆盖当前内网远程页面需求，也把证书续期和访问鉴权留成了清晰、可单独处理的后续事项。
