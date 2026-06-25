---
title: "把云端部署写成 Agent Skill"
date: 2026-06-25 21:05:38
categories:
  - "AI"
tags:
  - "AI Agent"
  - "Skill"
  - "自动化部署"
  - "DevOps"
  - "AI工作日志"
source_archive:
  id: 20260625-cloud-deploy-agent-skill
  rel_path: source_materials/posts/20260625-cloud-deploy-agent-skill
  conversation_file: conversation.jsonl
---

这次做的是一个云端部署 Skill。目标不是再造一套发布平台，而是把已经存在的人工发布流程拆成 Agent 能稳定执行、能停在正确位置、能把事实说清楚的几段能力。

最后落地的形态很克制：一份服务拓扑 YAML，一份 Skill 说明，三个面向 Agent 的 Python 脚本，再加一组 Nginx 文本切流测试。部署、验证、切流仍然尊重现有服务器和脚本，不把生产发布变成一个模型自由发挥的动作。

## 先收窄边界

一开始容易把问题想大：既然要“部署”，那是不是要同时覆盖边缘设备、小电脑、测试环境、生产环境、服务健康检查、Nginx 切流、回滚记录。

实际讨论后先砍掉一半。小电脑端已经有自己的部署 Skill，这次只覆盖云端 Java 服务。已有的云端 Debug Skill 也不直接改成发布工具，因为它的边界是只读排查；发布 Skill 需要允许写操作、执行更新脚本、在生产切流前停下来等确认。

真正要建模的是这条链路：

```text
Agent -> 读取服务拓扑 -> 采集发布前快照
  -> 执行服务更新脚本 -> 采集发布后快照
  -> 校验 Git 提交和 Spring 启动日志
  -> 如需生产切流，则先 dry-run 等人工确认
  -> apply 切流后再验证流量触达目标实例
```

这个链路里最重要的不是命令本身，而是谁负责判断。脚本只返回事实，Agent 根据 Skill 的 flow 决定下一步，人只在生产切流这种高风险动作前确认。

## 先把服务分成 service 和 serviceGroup

调研现有服务器后，发布对象被拆成两类。

第一类是单实例服务，配置里叫 `service`。它直接承载流量，发布时允许原地更新，不需要做入口切流。

第二类是多实例服务组，配置里叫 `serviceGroup`。它背后有两个实例，生产入口通过 Nginx 指到其中一个。发布时不能直接更新当前承载流量的实例，而是先发布空闲实例，验证启动成功后，再把 Nginx `proxy_pass` 切过去。

这里没有用“稳定业务名 + 环境”这种混合 key，而是把服务名、环境拆成两个维度：

```text
environment: dev | prod
service: 单实例服务
serviceGroup: 多实例服务组
```

这样后面如果增加灰度、机房、租户或更多环境，不需要拆一堆已经混在一起的字符串。

## 生产入口不要靠行号改

生产服务组的关键动作是 Nginx 切流。人工操作时通常就是在同一个 `location` 里，让两个 `proxy_pass` 一开一关：

```nginx
location /example/ {
    proxy_pass http://service_a;
    # proxy_pass http://service_b;
}
```

脚本也应该像人一样做这件事，而不是用固定行号替换。因为 Nginx 配置多加一行注释、调整一行空白，都不应该导致脚本改错位置。

最终切流脚本的输入是：

```text
environment
serviceGroup
targetService
expectedCurrent
```

YAML 里记录 Nginx 文件、`location`、允许出现的 `proxy_pass` 列表。脚本执行时先定位到精确的 `location` 块，再检查当前未注释的 `proxy_pass` 是否等于 `expectedCurrent`，最后只在白名单里的两个 `proxy_pass` 之间切换注释状态。

这个设计有两个保护：

```text
dry-run: 只读取远端配置，输出计划和 diff，不写文件
apply: 必须带 expectedCurrent，不匹配就拒绝执行
```

也就是说，如果 dry-run 后到 apply 前，别人已经改过生产入口，脚本不会继续按旧认知切流。

## 脚本不要固化整条流程

中间有过一个很明显的设计调整：不要写一个“大脚本”把检查环境、部署、验证、切流三四个阶段全部包进去。

原因很简单，Skill 的价值在编排，不在把流程焊死进脚本。阶段顺序、人工确认点、失败后是否回滚，这些都应该由 Agent 按 Skill 说明来判断；脚本只负责自己那一段可验证的动作。

最后保留下来的脚本是：

```text
snapshot-service.py
  采集环境、实例、端口、当前进程、日志、Git 信息等状态。

deploy-service.py
  发布服务。内部固定执行发布前 snapshot、update.sh、发布后 snapshot、日志验证。

cutover-nginx-route.py
  对生产入口做 dry-run / apply 切流，只改 proxy_pass 注释状态。
```

环境检查没有单独做成 `check-env.py`。Agent 在 Skill 里按普通命令检查即可，例如：

```bash
python3 -c "import yaml"
ssh -o BatchMode=yes <user>@<host> true
```

这类动作本质是前置确认，不需要为了它再暴露一个工具入口。

## JSON 只输出事实

另一个重要收口是脚本输出。

一开始很容易在 JSON 里加这些字段：

```json
{
  "ok": false,
  "failedPhase": "verify",
  "nextRequiredAction": "investigate-or-confirm-rollback"
}
```

但这些其实是语义判断，不是脚本事实。更新脚本成功、日志验证失败，这就是两个事实；下一步是排查、重试、回滚还是让人确认，不应该由脚本替 Agent 做决定。

所以脚本输出保持为阶段事实，例如命令、返回码、stdout/stderr 摘要、快照、验证项结果、Nginx diff。SSH host、用户名、服务名可以保留，因为团队通过密钥登录，不依赖密码；token 不记录，因为这个流程用不到。

这个取舍让工具更无聊，但也更好用。Agent 拿到的是证据，不是一个脚本提前写死的“建议”。

## 验证口径也收窄

后台 Java 服务发布成功，不等于业务链路全部验证成功。第一版验证只看两个东西：

```text
1. 启动日志里输出了最新 Git 提交信息，并且与部署分支最新提交一致。
2. Spring 程序正常启动。
```

如果是带切流的服务组，切流后再补一个确认：流量确实触达到目标服务实例。

业务逻辑不在这个发布 Skill 里验证。业务验证可以由接口测试、数据库只读核验或专门的业务 Debug Skill 接住。把它塞进发布脚本，只会让发布成功与业务正确性混在一起，后面很难判断失败到底属于哪一层。

日志提示也没有放进 YAML。大多数 Java 服务的日志形式很统一，例如控制台日志和错误日志有固定命名习惯，这些语义提示写在 Skill 说明里就够了。YAML 只维护机器需要精确读取的拓扑和入口信息。

## 用真实配置副本测文本切流

这次唯一比较适合单测的地方，是 Nginx 文本修改。

测试先写了切流函数的失败用例，再补实现。除了最小样例，也放了生产入口配置的本地副本做 fixture，用来验证脚本不会因为真实配置里的空行、注释、多个 `location` 或相邻代理配置而改错。

最后本地验证结果是：

```text
python3 -m pytest tests -q
6 passed
```

另外还跑了三类 dry-run：

```text
snapshot-service.py --env prod --group service-group-a
deploy-service.py dry-run --env prod --group service-group-a
cutover-nginx-route.py dry-run --env prod --group service-group-b --target-service service-b-2
```

这些 dry-run 都只读远端状态，不写文件。对生产入口来说，这一点很关键：Agent 可以提前把计划、当前目标、目标实例和 diff 展示出来，但真正 apply 必须等人确认。

## 结果

这次产物不是一个“自动发布系统”，而是一套可被 Agent 调用的发布能力边界。

它解决了几个具体问题：

```text
服务拓扑:
  用 YAML 维护环境、单实例服务、多实例服务组。

发布:
  继续调用现有 update.sh，不重写团队已有发布脚本。

验证:
  聚焦 Git 提交信息和 Spring 启动，不混入业务验证。

生产切流:
  dry-run / apply 两段式，apply 必须校验 expectedCurrent。

输出:
  脚本只返回事实 JSON，语义判断留给 Agent 和 Skill flow。
```

代价也很明确：YAML 要维护准确，Nginx fixture 要跟入口配置形态保持同步，真实发布记录第一版只写会话报告，还没有做成可审计的发布台账。

但这个边界是合适的。它没有让模型直接掌控生产，也没有把所有发布细节藏进一个大脚本里。Agent 负责读事实、编排阶段、解释风险；脚本负责做小而确定的事情；人只在真正需要承担风险的位置确认。
