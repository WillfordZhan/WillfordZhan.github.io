---
title: "一次 SSH 隧道报错背后的 Docker 镜像层损坏排查"
date: 2026-05-06 16:22:07
categories:
  - "日常业务开发"
tags:
  - "故障排查"
  - "Docker"
  - "Nginx"
  - "SSH"
  - "远程排障"
source_archive:
  id: 20260506-docker-overlay-nginx-empty-conf
  rel_path: source_materials/posts/20260506-docker-overlay-nginx-empty-conf
  conversation_file: conversation.jsonl
---

一台现场小电脑通过 SSH 登录后不断刷：

```text
channel 3: open failed: connect failed: Connection refused
channel 4: open failed: connect failed: Connection refused
```

现场刚经历过一次升级中断，第一反应很容易落到 Java 服务、SSH 配置、端口转发、Docker 容器状态这些方向上。最后定位到的是前端镜像在本机的 Docker 存储层异常：同一个 digest 的镜像，在另一台机器上正常，在故障机里 nginx 配置文件读出来是 0 字节。

这篇记录完整排查链路。命令里的主机名、镜像仓库、业务路径都做了脱敏，只保留判断方式。

## 先确认 SSH 报错指向哪一层

这个报错来自 SSH channel，不等于 SSH 登录失败。它通常表示端口转发已经建立了一个 channel，但转发目标拒绝连接。

现场 SSH 配置里有类似这样的转发：

```sshconfig
Host device-b
    HostName 127.0.0.1
    LocalForward 127.0.0.1:30080 localhost:80
    LocalForward 127.0.0.1:38080 localhost:8080
```

所以第一步先绕开转发噪音，直接查远端端口和进程：

```bash
ssh -o ClearAllForwardings=yes device-b \
  "hostname
   date
   ss -lntp | egrep '(:80|:8080|:30080|:38080)' || true
   ps -ef | egrep 'java|nginx|docker' | grep -v grep"
```

关键输出是：

```text
LISTEN 0 100 *:8080 *:*
root ... dockerd ...
root ... java ... org.springframework.boot.loader.JarLauncher
```

这里能确认两件事：

- Java 后端在，`8080` 也在监听。
- `80` 没有监听，也没有 nginx 进程。

SSH channel 报错和 `80` 没服务能对上，下一步收敛到前端/nginx 容器。

## 看容器状态，不先看业务日志

现场用户不是 docker 组成员，直接跑 `docker ps -a` 会报：

```text
permission denied while trying to connect to the Docker daemon socket
```

改用 sudo：

```bash
sudo docker ps -a
```

关键输出：

```text
NAMES              IMAGE                                  STATUS
web-frontend-1     registry.example.com/app/web:dev       Restarting (1) 54 seconds ago
java-backend-1     registry.example.com/app/backend:prod  Up About a minute
```

这一步把范围继续缩小：

- 后端容器是 `Up`。
- 前端容器在反复 `Restarting (1)`。
- 远端 `80` 不监听，是前端容器没起来带来的结果。

## 日志读不到时，先看日志驱动和退出状态

正常情况下会先看：

```bash
sudo docker logs --tail=120 web-frontend-1
```

但这次返回：

```text
Error response from daemon: configured logging driver does not support reading
```

这个输出说明当前容器日志驱动不支持 `docker logs`。继续用 `inspect` 查容器状态、日志驱动和启动命令：

```bash
sudo docker inspect web-frontend-1 \
  --format '{{json .State}} {{json .HostConfig.LogConfig}} {{json .Config.Cmd}} {{json .Config.Entrypoint}}'
```

关键输出：

```json
{"Status":"restarting","Restarting":true,"Pid":0,"ExitCode":1,
 "StartedAt":"2026-05-06T00:31:44.228819009Z",
 "FinishedAt":"2026-05-06T00:31:44.389715684Z"}
{"Type":"none","Config":{}}
["nginx","-g","daemon off;"]
["/docker-entrypoint.sh"]
```

这里的信息比日志更直接：

- 容器启动后约 0.16 秒退出。
- 退出码是 1。
- 日志驱动是 `none`，所以 `docker logs` 没有入口。
- 主进程是 nginx。

既然主进程是 nginx，下一步直接用同一个镜像跑 nginx 自检。

## 用同镜像复现 nginx 启动失败

正在重启的容器不方便读日志，可以起一个临时容器，只执行 nginx 配置检查：

```bash
sudo docker run --rm --network host --entrypoint nginx \
  registry.example.com/app/web:dev -t
```

故障机输出：

```text
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: [emerg] no "events" section in configuration
nginx: configuration file /etc/nginx/nginx.conf test failed
```

`no "events" section` 指向 nginx 主配置。这个阶段还不能直接说镜像坏了，因为也可能是：

- 镜像构建时 nginx 配置就有问题。
- 运行时挂载覆盖了 `/etc/nginx/nginx.conf`。
- 这台机器上的本地镜像层出了问题。

需要继续排除。

## 对比另一台正常机器的同 digest 镜像

同一个 tag 可能被重新推送，所以只看 tag 不够。这里对比两台机器上的 image id 和 repo digest：

```bash
sudo docker image inspect registry.example.com/app/web:dev \
  --format 'id={{.Id}} created={{.Created}} repoDigests={{json .RepoDigests}}'
```

故障机：

```text
id=sha256:591571...
created=2026-04-29T11:13:48+08:00
repoDigests=["registry.example.com/app/web@sha256:413c05..."]
```

正常机：

```text
id=sha256:591571...
created=2026-04-29T11:13:48+08:00
repoDigests=["registry.example.com/app/web@sha256:413c05..."]
```

两边 image id 和 digest 一样。按 Docker 镜像语义，它们应该能跑出一样的文件内容。

再在正常机上跑同样的 nginx 自检：

```bash
sudo docker run --rm --entrypoint nginx \
  registry.example.com/app/web:dev -t
```

正常机输出：

```text
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

到这一步，仓库镜像本身有问题的可能性已经很低。相同 digest 在两台机器表现不同，问题更像落在故障机本地的 Docker 镜像层或 overlay 文件。

## 直接读镜像内文件

最后一步是把猜测变成文件级证据：

```bash
sudo docker run --rm --entrypoint sh \
  registry.example.com/app/web:dev \
  -c 'sha256sum /etc/nginx/nginx.conf /etc/nginx/conf.d/* 2>/dev/null;
      find /etc/nginx -maxdepth 2 -type f -printf "%p %s\n"'
```

故障机输出：

```text
e3b0c44298fc...  /etc/nginx/nginx.conf
e3b0c44298fc...  /etc/nginx/conf.d/80.conf
e3b0c44298fc...  /etc/nginx/conf.d/app.conf

/etc/nginx/nginx.conf 0
/etc/nginx/conf.d/80.conf 0
/etc/nginx/conf.d/app.conf 0
/etc/nginx/proxy.conf 0
```

`e3b0c442...` 是空文件的 sha256。多个 nginx 配置文件都变成 0 字节，能解释前面的 `no "events" section`。

正常机里同一个镜像的这些文件有正常内容，nginx 自检也通过。最终判断就收口了：故障机本地 Docker 镜像层或 overlay 文件异常。

## 最小修复动作

这类问题不要在容器里手改 `/etc/nginx/nginx.conf`。容器会重建，手改也解释不了为什么同 digest 文件内容不同。

这次更合适的动作是删除故障机本地前端容器和前端镜像，重新拉取并重建：

```bash
cd /opt/app/docker/app

sudo docker compose stop f
sudo docker compose rm -sf f
sudo docker image rm registry.example.com/app/web:dev

sudo docker compose pull f
sudo docker compose up -d f
```

验证：

```bash
sudo docker ps -a | grep web-frontend
ss -lntp | egrep '(:80|:8080)'
curl -I http://127.0.0.1/
```

期望结果：

```text
web-frontend-1 ... Up
LISTEN ... *:80
LISTEN ... *:8080
HTTP/1.1 200 OK
```

`80` 恢复监听后，SSH 转发到远端 `80` 的 channel 报错也会消失。

## 这次排查的顺序

最后把链路压成一行，方便下次照着走：

```text
SSH channel refused
-> 绕开转发后查端口
-> 远端 80 不监听，8080 正常
-> 前端容器 Restarting，后端容器 Up
-> docker logs 读不到，inspect 看到日志驱动 none、主进程 nginx、退出码 1
-> 用同镜像跑 nginx -t，报 no "events" section
-> 对比正常机器同 digest，正常机器 nginx -t 通过
-> 读故障机镜像内 /etc/nginx，配置文件是 0 字节
-> 重拉镜像并重建前端容器
```

这条链路里最有用的分界点是“同 digest、不同机器、同命令结果不同”。它把排查从应用配置、SSH 配置、compose 配置里拉出来，落到本机 Docker 存储层。升级过程中断电这种背景也在这里有了对应证据，判断不再停留在经验猜测。
