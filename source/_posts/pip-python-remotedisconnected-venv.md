---
title: "一场被 pip 镜像污染带偏的 Python 升级故障：从 RemoteDisconnected 到干净 venv"
date: 2026-03-10 11:26:57
categories:
  - "AI"
tags:
  - "Python"
  - "Ubuntu"
  - "pip"
  - "故障排查"
  - "运维"
  - "AI工作日志"
---

这篇文章整理自一段公开聊天记录，主题很朴素：一台 Ubuntu 服务器上，项目本来只是想装依赖，结果 `pip install -r requirements.txt` 一路刷出 `RemoteDisconnected('Remote end closed connection without response')`。乍看像镜像站抽风，再看像 Python 3.11 升级后遗症，继续看又像 SSL、DNS、代理、`needrestart` 集体搞事情。

最后发现，问题确实和网络有关，但不是那种“换个源再试试吧”的浅层网络问题，而是几个小坑叠在一起：

- 机器里同时存在多个 `pip` 镜像配置
- 命令行里写了 `-i`，但并没有真正隔离掉 `extra-index-url`
- 系统里确实装了 Python 3.11，但默认 `python3` 仍然是 3.10
- 升级 Python 之后继续沿用旧 shell、旧 `.venv`，会把诊断方向搅浑

这一类问题很适合记成踩坑记录，因为它不难修，但非常容易误判。

## 先说结论

这次排查最后收敛成 4 个确定结论：

1. `RemoteDisconnected` 说明连接建立后被远端或中间链路掐断，不是 `requirements.txt` 写错。
2. 命令里写了 `-i https://...`，不代表 `pip` 只会访问这一个源；如果全局还配了 `extra-index-url`，它照样会继续扫别的镜像。
3. “我升级到了 Python 3.11” 和 “系统默认 `python3` 已经切到 3.11” 是两回事，必须用 `which python3`、`python3 --version`、`readlink -f /usr/bin/python3` 说话。
4. 业务修复的最小动作不是折腾系统 Python，而是先明确项目到底用 3.10 还是 3.11，然后删掉旧 `.venv` 重建。

如果你只想抄最短修复路径，可以直接看这组命令：

```bash
cd /path/to/project
deactivate 2>/dev/null || true
rm -rf .venv

python3.11 -m venv .venv
source .venv/bin/activate

python -V
python -m pip --version

python -m pip --isolated install --upgrade pip setuptools wheel \
  -i https://pypi.tuna.tsinghua.edu.cn/simple \
  --timeout 120 \
  --retries 10

python -m pip --isolated install -r requirements.txt \
  -i https://pypi.tuna.tsinghua.edu.cn/simple \
  --timeout 120 \
  --retries 10
```

关键是 `--isolated`。这玩意不像咖啡，但很能让人清醒。

## 故障现象

最开始的日志大概长这样：

```text
pip install -r requirements.txt
Looking in indexes: https://mirrors.aliyun.com/pypi/simple,
https://pypi.tuna.tsinghua.edu.cn/simple/,
https://pypi.douban.com/simple/,
https://mirrors.cloud.tencent.com/pypi/simple/

WARNING: Retrying (...) after connection broken by
'ProtocolError('Connection aborted.',
RemoteDisconnected('Remote end closed connection without response'))'
```

这里有两个很关键的信号。

第一个信号：不是所有包都失败。有的包能从某个镜像下载成功，有的包在访问镜像索引时被掐断。

第二个信号：输出里出现了 4 个镜像源。这个细节当时看着像“配得挺周到”，实际上更像“埋了 4 个随机坑位”。

## 第一个误判：把它当成单纯镜像抖动

最开始很容易得出一个判断：

- 镜像站不稳定
- 换个国内源
- 加大 `--timeout`
- 多试几次

这套思路不能说完全错，但只对了一半。

对的一半在于：`RemoteDisconnected` 的确说明 HTTP/TLS 链路上存在中断，问题发生在下载阶段，不是依赖文件语法错误。

错的一半在于：如果你没有先把 `pip` 的配置边界收紧，那么你每次“换源重试”，可能根本没有真正换到单一源。你以为自己在测清华，实际上阿里、豆瓣、腾讯还在队伍里轮流上场。

## 第二个误判：以为系统已经切到了 3.11

用户补充了一条很有迷惑性的背景信息：

- Ubuntu
- 原系统 Python 是 3.10
- 后来安装了 3.11
- 期间触发过 `needrestart`

这时候人脑会自动补全成一个剧情：

“哦，系统 Python 从 3.10 升到 3.11 了，后面 pip 出问题，多半是升级把环境搞乱了。”

剧情很顺，事实不一定。

真正查出来的现场是：

```bash
which python3
/usr/bin/python3

python3 --version
Python 3.10.12

readlink -f /usr/bin/python3
/usr/bin/python3.10

which python3.11
/usr/bin/python3.11
```

这说明什么？

- 3.11 确实装了
- 但系统默认 `python3` 仍然是 3.10
- 也没有通过 `update-alternatives` 正式接管 `python3`

换句话说，系统并没有“切坏”，只是机器上同时存在两个版本。很多时候，故障不是因为你把系统 Python 改坏了，而是因为你以为自己改坏了，于是开始修一个并不存在的问题。

## 真正的排查拐点：命令写了 `-i`，输出还是四个源

后面做了一个很关键的验证：重建 `.venv` 后，再执行：

```bash
python -m pip install -r requirements.txt \
  -i https://pypi.tuna.tsinghua.edu.cn/simple \
  --timeout 120 \
  --retries 10
```

按直觉，输出应该只剩一个索引地址。

结果不是。

输出里仍然是：

```text
Looking in indexes: 阿里云、清华、豆瓣、腾讯
```

这条日志一出来，方向就彻底变了。因为它证明了：

- 问题不是 Python 3.10 还是 3.11
- `.venv` 即使重建成功，`pip` 仍然在读到额外配置
- 机器上存在 `pip.conf`、环境变量或者全局 `/etc/pip.conf` 注入的镜像污染

这个结论非常关键。它把“网络不稳”从泛化判断，压缩成了可验证的配置问题。

## 为什么 `-i` 不够

这是这次最值得单独记住的坑。

很多人把 `-i` 理解成“这次安装只走这个源”。但 `pip` 还有一堆别的入口：

- `~/.pip/pip.conf`
- `~/.config/pip/pip.conf`
- `/etc/pip.conf`
- `PIP_INDEX_URL`
- `PIP_EXTRA_INDEX_URL`

如果这些地方配了 `extra-index-url`，那你命令行里单独传 `-i`，并不天然等于全局配置失效。

所以真正稳妥的诊断姿势应该是：

```bash
python -m pip config list -v
env | grep -i ^PIP
cat ~/.pip/pip.conf 2>/dev/null
cat ~/.config/pip/pip.conf 2>/dev/null
cat /etc/pip.conf 2>/dev/null
```

如果你想先绕开污染，直接上：

```bash
python -m pip --isolated install ...
```

`--isolated` 的价值不是优雅，而是粗暴地把不确定性先砍掉。

## `needrestart` 和旧 `.venv` 为什么也值得怀疑

虽然最终主因更偏向 `pip` 源配置污染，但 `needrestart` 和旧 `.venv` 也不是冤枉群众。

它们会显著放大排查难度，原因很简单：

- 旧 shell 可能仍然保留升级前的环境状态
- 旧 `.venv` 可能绑定过另一个解释器路径
- `pip`、`python`、`openssl`、证书链的组合关系会被你脑补得越来越复杂

所以排查这类问题时，最值钱的不是多懂几个概念，而是先把运行边界做干净：

1. 明确项目要用哪个 Python 版本。
2. 只在项目 `.venv` 里做实验，不碰系统默认 `python3`。
3. 先删 `.venv` 重建，再谈网络和镜像。
4. 先让 `pip` 进入隔离模式，再谈源快不快。

这几步做完，很多“玄学问题”会自动降级成普通配置问题。

## 这次复盘里最容易踩的 5 个坑

### 1. 把 `RemoteDisconnected` 当成包本身有问题

这类报错先看链路，不要先看 `requirements.txt`。

### 2. 看到装了 Python 3.11，就以为默认解释器已经切换

`which`、`--version`、`readlink` 三件套跑完再下结论。

### 3. 以为 `-i` 会自动屏蔽其他镜像

不会。全局 `pip.conf` 和环境变量可能还在后面悄悄加料。

### 4. 不愿意删旧 `.venv`

很多人舍不得删，最后花两小时证明“旧环境确实有可能脏”。不如一开始就删。

### 5. 一上来就想改系统 Python

在 Ubuntu 上，这是最容易把问题从“项目环境异常”升级成“机器环境异常”的操作。项目能用 `python3.11 -m venv` 解决的事，没必要碰 `/usr/bin/python3`。

## 我建议保留的最小排查模板

以后再遇到类似问题，我会先跑这一组：

```bash
which python3
python3 --version
readlink -f /usr/bin/python3

python -m pip config list -v
env | grep -i ^PIP

rm -rf .venv
python3.11 -m venv .venv
source .venv/bin/activate

python -V
python -m pip --version

python -m pip --isolated install -r requirements.txt \
  -i https://pypi.tuna.tsinghua.edu.cn/simple \
  --timeout 120 \
  --retries 10
```

这套动作的优点是：

- 先把“解释器是谁”说清楚
- 再把“pip 实际读了什么配置”说清楚
- 最后才是“网络到底稳不稳”

顺序一旦反过来，排查就很容易变成一场和自己想象力的搏斗。

## 小结

这次故障表面上是 `pip install` 随机断连，实际上是三件事串在一起：

- 多镜像配置把单源诊断搞脏了
- Python 3.11 的存在感比它的实际控制权更强
- 旧 `.venv` 和 `needrestart` 让人很想把锅甩给系统升级

真正有效的修复动作并不复杂：

- 不折腾系统默认 Python
- 明确项目使用的版本
- 重建 `.venv`
- 用 `--isolated` 清掉镜像配置污染

很多环境问题并不神秘，只是日志里同时出现了 5 个可疑对象，大家就容易选中最戏剧化的那个。

如果你也遇到过“我明明指定了一个源，`pip` 却偷偷访问四个源”的场面，欢迎把那份配置文件翻出来看看。它大概率比你的网络更会演。
