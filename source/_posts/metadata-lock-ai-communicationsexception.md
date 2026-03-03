---
title: "一次被 Metadata Lock 隐藏的 AI 聊天故障：从 CommunicationsException 到长事务排查"
date: 2026-03-03 19:12:35
categories:
  - "AI"
tags:
  - "MySQL"
  - "Spring Boot"
  - "MyBatis"
  - "Druid"
  - "故障排查"
  - "后端工程"
  - "AI工作日志"
---

这篇文章记录一次很典型、也很容易被误判的线上故障：Java 应用里一条普通的查询 SQL，最终抛出来的却是 `CommunicationsException`。如果只盯着“通信失败”四个字，很容易沿着网络、连接池、驱动参数一路排查下去；但这次真正的根因，是一把被 DDL 队列放大的 `metadata lock`。

这个坑对后端开发工程师很有价值，因为它横跨了 4 层：

- MySQL DDL 与 metadata lock 机制
- JDBC 驱动的超时表现
- 连接池里的空闲连接与未结束事务
- 应用层对异常语义的误判

## 先说结论

最终根因不是 SQL 语法、不是 MyBatis 参数、也不是网络瞬断，而是：

- 某些旧连接处于 `Sleep` 状态，但事务没有真正结束
- 它们持有 `ai_chat_conversations` 的 metadata lock 相关资源
- DataGrip 发起 `ALTER TABLE` 后进入 `Waiting for table metadata lock`
- 后续新的 `SELECT` 也被排到 DDL 后面一起阻塞
- 应用侧 `socketTimeout=4000`，于是锁等待被包装成了 `CommunicationsException`

现场止血动作也很直接：

- 停掉两个持有旧连接的应用实例
- metadata lock 释放
- DDL 恢复
- 普通查询恢复

这说明真正要学会的不是“背结论”，而是建立一套从症状反推锁模型的排查路径。

## 故障现象

应用侧报错大意如下：

```text
CommunicationsException: Communications link failure
The last packet successfully received from the server was 4,016 milliseconds ago.
The last packet sent successfully to the server was 4,017 milliseconds ago.
```

对应 SQL 是一条非常普通的查询：

```sql
SELECT conversation_id, dept_id, user_id, conversation_name, title,
       initial_query, context_snapshot, agent_state, created_at
FROM ai_chat_conversations
WHERE dept_id = ?
  AND user_id = ?
ORDER BY created_at DESC;
```

第一眼看上去，很容易怀疑：

- 数据库网络抖动
- 连接池拿到了坏连接
- MyBatis 参数绑定异常
- 数据源配置超时过短

这些方向都不是完全错，但都不是核心根因。

## 为什么“锁问题”会长成“通信问题”

这是这次故障最有技术价值的部分。

应用使用的是 MySQL JDBC，配置里有类似下面的超时参数：

```text
connectTimeout=2000
socketTimeout=4000
```

`socketTimeout=4000` 的含义不是“4 秒内必须建立连接”，而是“执行期间如果 4 秒没有收到服务端数据，就认为通信失败”。

问题在于：

- SQL 被 metadata lock 挡住时，MySQL 服务端并不会马上报业务错误
- 它只是让这个语句一直等待
- 驱动层感知到的现象就是“迟迟没有返回数据包”

于是，锁等待在 JDBC 层面看起来就像：

```text
Communications link failure
```

这类报错最危险的地方在于，它把开发者视线从“锁与事务”引到了“网络与连接池”。

## 真正的现场证据

真正把问题打穿的，不是应用日志，而是数据库侧的 `SHOW FULL PROCESSLIST`。

排查时看到两类关键信息：

第一类，是等待中的 DDL：

```text
ALTER TABLE ai_chat_conversations ... Waiting for table metadata lock
```

第二类，是被一起挡住的普通查询：

```text
SELECT ... FROM ai_chat_conversations ...
Waiting for table metadata lock
```

这个现象很关键，因为它说明：

- 不是“只有 DDL 被卡住”
- 而是“DDL 一旦进入 metadata lock 等待队列，新的查询也可能被排在它后面”

这也是很多工程师第一次踩坑时最容易忽略的点。

## 为什么普通 SELECT 也会被挡住

很多人对 metadata lock 的直觉是：

- `SELECT` 拿共享锁
- `ALTER TABLE` 拿排他锁
- 排他锁拿不到就等着，不影响新的读

但 MySQL 为了避免 DDL 永远饿死，在等待队列存在时，会限制后续新的 metadata lock 获取请求继续穿过队列。

换句话说：

1. 某个旧事务还没结束，手里拿着与表相关的 metadata lock
2. 一个 `ALTER TABLE` 过来排队
3. 后续新来的 `SELECT`，不再总能像平时那样直接读过去
4. 于是你会看到“DDL 和查询一起卡死”

这就是为什么现场同时出现：

- DDL 卡住
- 应用查询卡住
- 查询最终超时并伪装成通信故障

## 真 blocker 往往不是那条 ALTER

另一个常见误区是，看到 `ALTER TABLE ... Waiting for table metadata lock`，就以为这条 DDL 是坏人。

其实它通常只是“受害者之一”。

真正的 blocker 往往是更早的那个连接，它可能表现为：

- `Sleep`
- 空闲了很久
- 看上去没有在执行任何 SQL
- 但事务并没有真正结束

这次现场里，最可疑的就是一批长时间 `Sleep` 的应用连接。停掉对应的两个实例后，表锁等待立刻恢复正常，这就是非常强的反证。

## 根因为什么会落到长事务上

这次问题还有一层更深的工程含义。

AI 聊天这条链路里，后端并不只有 Java 服务，还有一层 Python 控制面负责会话存储与事件流。排查代码后发现，MySQL 连接是手动事务模式，而部分只读查询路径执行完 `SELECT` 后没有及时 `commit` 或 `rollback`。

这类代码平时不一定立刻炸，因为：

- 查询能正常返回
- 业务看起来没问题
- 连接池还能复用连接

但一旦遇到 DDL，就会把这种“平时没感觉的问题”瞬间放大成事故。

这也是为什么我一直认为，开发工程师进阶的重要标志之一，是开始把“只读查询也要正确收尾事务”当成默认工程纪律，而不是数据库专家才需要关心的边角知识。

## 正确的排查顺序

如果以后你再遇到类似报错，我建议按下面顺序排查，而不是上来先改连接池参数。

### 1. 先问自己：这真的是网络吗

只要满足两个条件，就要立刻把锁等待列入第一怀疑对象：

- SQL 本身很普通
- 报错总在几秒这种固定阈值附近出现

固定阈值通常意味着某个超时参数在生效，而不是随机网络抖动。

### 2. 立刻看 `SHOW FULL PROCESSLIST`

重点不是只看你的查询，而是看同表是否存在：

- `Waiting for table metadata lock`
- `alter table ...`
- 很久的 `Sleep`

如果能同时看到“等待中的 DDL”和“等待中的查询”，基本已经能把方向锁定到 metadata lock。

### 3. 分清谁是 waiter，谁是 blocker

等待中的 DDL 只是 waiter。

真正 blocker 通常是：

- 更早建立的连接
- 处于 `Sleep`
- 背后挂着未结束事务

如果权限足够，最好继续查：

- `information_schema.innodb_trx`
- `performance_schema.metadata_locks`

这两张表能更准确地把等待关系串起来。

### 4. 先止血，再修代码

止血手段通常是：

- kill blocker 会话
- 或直接重启持有这些连接的应用实例

修复手段才是：

- 确保只读事务及时结束
- 避免无意义的长事务
- 调整 DDL 执行窗口

## 工程上的 4 个经验

### 1. `CommunicationsException` 不总是网络问题

它只是驱动层视角的结果，不是数据库根因诊断。

### 2. DDL 问题会把读流量一起拖死

很多团队低估了 DDL 对在线流量的影响，尤其是对 metadata lock 的影响。

### 3. `Sleep` 连接不等于“没问题”

一个连接显示 `Sleep`，只说明当前没有在执行 SQL，不代表它没有打开事务。

### 4. 连接池参数只能缓解表象，解决不了 blocker

把 `socketTimeout` 从 4 秒改成 30 秒，确实能减少误报，但它只能让错误“晚一点暴露”，不能让 metadata lock 自动消失。

## 我会怎么做长期治理

如果把这次事故当作一个长期治理样本，我会做下面几件事。

### 代码层

- 明确所有只读查询路径的事务收尾策略
- 对手动事务连接，要求查询结束后显式 `rollback`
- 审查是否存在无必要的 `SELECT ... FOR UPDATE`

### 运维层

- 给 DDL 设固定窗口
- 建立 metadata lock 排查脚本
- 对长时间 `Sleep` 且处于事务中的连接做巡检

### 应用层

- 记录 SQL 超时与锁等待的关联指标
- 把“固定 4 秒/5 秒超时报错”纳入锁等待排查模板
- 不把 `CommunicationsException` 简单等同于网络异常

## 最后

这次故障最值得记住的一点是：

> 当一条普通查询在固定超时阈值上报通信失败时，开发工程师应该本能地怀疑“是不是锁在伪装成网络问题”。

很多进阶能力，并不是你学会了多复杂的中间件，而是你开始建立跨层排查的因果链：

- 数据库锁怎么表现
- 驱动超时怎么包装
- 连接池怎么放大问题
- 应用日志为什么会误导你

这条链一旦建立起来，很多“看起来玄学”的线上问题，就会开始变得非常具体。
