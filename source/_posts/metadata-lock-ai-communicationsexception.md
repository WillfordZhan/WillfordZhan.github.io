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

这篇文章记录一次线上故障：Java 应用里一条普通查询，最终抛出来的是 `CommunicationsException`。表面看像网络或连接池问题，实际是被 DDL 等待放大的 `metadata lock`。

排查过程横跨 4 层：

- MySQL DDL 与 metadata lock 机制
- JDBC 驱动的超时表现
- 连接池里的空闲连接与未结束事务
- 应用层对异常语义的误判

## 先说结论

根因是：

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

下面重点讲 5 个问题：

- metadata lock 怎样拖住普通查询
- JDBC 为什么把它报成通信失败
- 为什么 blocker 常常是 `Sleep` 连接
- 为什么 Java 默认不易复现，手写连接更容易踩中
- 为什么这次 Python 修复能降低复发概率

## 现场时间线：现象是怎么一步步放大的

时间线很短：

1. 某些历史连接已经进入 `Sleep`
2. 这些连接背后仍带着未结束事务
3. DataGrip 发起 `ALTER TABLE ai_chat_conversations ...`
4. DDL 进入 `Waiting for table metadata lock`
5. 后续新的查询也开始排队等待 metadata lock
6. 应用端 `socketTimeout=4000`
7. 4 秒后，JDBC 抛出 `CommunicationsException`

如果只盯第 7 步，方向很容易跑偏。

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

第一反应通常是：

- 数据库网络抖动
- 连接池拿到了坏连接
- MyBatis 参数绑定异常
- 数据源配置超时过短

这些方向都可以查，但都不是主因。

### 从报错文本里先抽出 2 个信号

先抓两个信号：

```text
The last packet successfully received from the server was 4,016 milliseconds ago.
The last packet sent successfully to the server was 4,017 milliseconds ago.
```

一是时间非常固定。稳定在 4 秒左右，通常意味着某个明确的超时配置在生效，不像随机网络抖动。

二是 SQL 很普通。普通查询在固定阈值上报通信失败，优先该怀疑：

- 服务端一直没返回结果
- 驱动在等响应超时
- 为什么服务端没返回，要进一步看锁、慢查询、阻塞而不是先看网卡

## 为什么会报成“通信问题”

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

这类报错容易把视线带偏到网络和连接池。

## 依据追溯 1：JDBC 配置为什么会把锁等待伪装成通信故障

这次 Java 数据源配置里，`atsIot` 对应的 JDBC URL 带了如下参数：

```text
connectTimeout=2000
socketTimeout=4000
```

可以先按这个意思理解：

- `connectTimeout`：建连阶段等多久
- `socketTimeout`：执行过程中多久收不到服务端数据就报错

关键点在于，metadata lock 等待时：

- MySQL 不是立刻报 SQL 语法错
- 也不是立刻返回 deadlock
- 它就是让这个线程等着

JDBC 看到的不是“数据库主动拒绝”，而是“服务端迟迟没有新数据包回来”，所以异常会长这样：

```text
Communications link failure
```

容易误判的点在这里：

- 错误名字里有 `Communications`
- 但本质不是网络建连失败
- 而是等待期间没有收到响应数据

## 现场证据

关键证据来自数据库侧的 `SHOW FULL PROCESSLIST`。

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

这个现象说明：

- 不是“只有 DDL 被卡住”
- 而是“DDL 一旦进入 metadata lock 等待队列，新的查询也可能被排在它后面”

很多人第一次踩到这里时会忽略这一点。

更直接的一条证据是：

```text
SELECT ... FROM ai_chat_conversations ...
Waiting for table metadata lock
```

这条信息一出现，方向就该从“网络问题”切到“锁问题”。

因为它明确告诉你：

- 查询线程已经到达 MySQL
- SQL 已经被接受
- 不是连不上
- 而是在等 metadata lock

## 为什么普通 SELECT 也会被挡住

很多人对 metadata lock 的直觉是：

- `SELECT` 拿共享锁
- `ALTER TABLE` 拿排他锁
- 排他锁拿不到就等着，不影响新的读

但 MySQL 为了避免 DDL 永远饿死，在等待队列存在时，会限制后续新的 metadata lock 获取请求继续穿过队列。

可以直接理解为：

1. 某个旧事务还没结束，手里拿着与表相关的 metadata lock
2. 一个 `ALTER TABLE` 过来排队
3. 后续新来的 `SELECT`，不再总能像平时那样直接读过去
4. 于是你会看到“DDL 和查询一起卡死”

于是现场会同时出现：

- DDL 卡住
- 应用查询卡住
- 查询最终超时并伪装成通信故障

## 依据追溯 2：为什么会出现“DDL 和读一起卡住”

很多人知道“DDL 会被长事务挡住”，但不知道后续读也可能被拖住。

可以用一个简化模型来看：

假设有 3 个会话：

### 会话 A：旧连接

它执行过对 `ai_chat_conversations` 的查询，但事务没结束。

```sql
SELECT * FROM ai_chat_conversations WHERE conversation_id = 'x';
-- 没有 COMMIT / ROLLBACK
```

### 会话 B：DDL

```sql
ALTER TABLE ai_chat_conversations ADD COLUMN conversation_name VARCHAR(120);
```

这时 B 想拿更强的 metadata lock，但 A 还没释放，于是 B 进入等待。

### 会话 C：新的普通查询

```sql
SELECT * FROM ai_chat_conversations
WHERE dept_id = '100' AND user_id = 'u1'
ORDER BY created_at DESC;
```

很多人的直觉是 C 还能读。

但 MySQL 为了避免 DDL 一直饥饿，会让后续新的 metadata lock 请求不能无限制插队。所以 C 也可能被排在 B 后面，于是形成：

- A 是 blocker
- B 是等待中的 DDL
- C 是被 DDL 队列拖住的普通查询

所以线上会出现“普通读也坏了”的观感。

## 真 blocker 往往不是那条 ALTER

另一个常见误区是，看到 `ALTER TABLE ... Waiting for table metadata lock`，就以为这条 DDL 是坏人。

它通常只是等待队列里的一个受害者。

真正的 blocker 往往是更早的那个连接，它可能表现为：

- `Sleep`
- 空闲了很久
- 看上去没有在执行任何 SQL
- 但事务并没有真正结束

这次现场里，最可疑的就是一批长时间 `Sleep` 的应用连接。停掉对应的两个实例后，表锁等待立刻恢复正常，这就是非常强的反证。

这里有个很实用的判断：

> 在 processlist 里，`Waiting for table metadata lock` 的 DDL 往往不是 root cause，而是把 root cause 暴露出来的受害者。

真正应该优先怀疑的是：

- 很早创建的连接
- 当前是 `Sleep`
- 但事务没有关闭
- 背后来自具体某个应用实例

这次就是停掉两个旧实例后马上恢复，说明 blocker 更可能来自这些实例里遗留的旧连接，而不是 DataGrip 本身。

## 根因为什么会落到长事务上

这次问题还有一层更深的工程含义。

AI 聊天这条链路里，后端并不只有 Java 服务，还有一层 Python 控制面负责会话存储与事件流。排查代码后发现，MySQL 连接是手动事务模式，而部分只读查询路径执行完 `SELECT` 后没有及时 `commit` 或 `rollback`。

这类代码平时不一定立刻炸，因为：

- 查询能正常返回
- 业务看起来没问题
- 连接池还能复用连接

但一旦遇到 DDL，就会把这种“平时没感觉的问题”瞬间放大成事故。

只读查询也要正确收尾事务，这不该被当成数据库专家才关心的边角问题。

## 典型反例代码：为什么 Python/手写连接更容易中招

下面是一段被抽象后的典型危险写法：

```python
conn = pymysql.connect(..., autocommit=False)

def get_conversation(conversation_id: str):
    with conn.cursor() as cursor:
        cursor.execute(
            "SELECT conversation_id, title FROM ai_chat_conversations WHERE conversation_id = %s",
            (conversation_id,),
        )
        return cursor.fetchone()
    # 这里直接 return 了，没有 commit，也没有 rollback
```

问题不在查询本身，而在这里：

- `autocommit=False`
- 执行完 `SELECT` 后事务仍然存在
- 连接对象长期存活
- 如果后面连接空闲下来，在 MySQL 里就会表现成 `Sleep`
- 但这个 `Sleep` 不是“绝对干净”的

这类代码平时往往不报错，但会在 DDL、锁等待、连接复用时把问题放大。

## 修复示范：为什么只读查询后显式 `rollback()` 是对的

这次 Python 修复的核心，是给只读事务一个明确结束点。

修复思路类似这样：

```python
conn = pymysql.connect(..., autocommit=False)

def get_conversation(conversation_id: str):
    try:
        with conn.cursor() as cursor:
            cursor.execute(
                "SELECT conversation_id, title FROM ai_chat_conversations WHERE conversation_id = %s",
                (conversation_id,),
            )
            return cursor.fetchone()
    finally:
        conn.rollback()
```

为什么只读查询后 `rollback()` 是合理的：

- 它不会撤销任何写入，因为本来就没有写入
- 它会显式结束当前事务
- 它能确保连接在后续复用前处于干净状态
- 它能显著降低“Sleep 连接带着旧事务”的概率

对手动事务模型来说，这是标准做法。

## `autocommit=True` 能不能一把梭解决

很自然会问：那是不是直接 `autocommit=True` 就好了？

答案是：

- 对纯只读场景，`autocommit=True` 大概率也能避开这次问题
- 但它不等于这次最合适的修复

原因在于，一个连接如果既承担读又承担写：

- 改成 `autocommit=True`，意味着整个连接的事务语义都变了
- 原本依赖显式 `commit/rollback` 的写路径，也会一起受影响
- 这属于“全局事务模型调整”，不是最小修复

这次选择的做法是：

- 保持写路径还是显式事务
- 只在读路径结束后统一 `rollback()`

原因很简单：它改动更小，也不改写现有写事务行为。

## 典型反例代码：为什么 `SELECT ... FOR UPDATE` 会放大锁竞争

除了只读事务不收尾，这次还顺手处理了另一个放大器：事件追加路径里的显式行锁。

下面是一个典型会放大竞争的写法：

```sql
SELECT 1
FROM ai_chat_conversations
WHERE conversation_id = ?
FOR UPDATE;
```

如果它只是为了确认会话存在，再去生成下一个事件序号，那么这把锁的收益和代价并不对等：

- 收益：串行化某些更新逻辑
- 代价：增加热点行竞争
- 副作用：在高并发或排障期更难看清真正的锁路径

更稳的方式通常是：

- 用唯一键约束兜底
- 冲突时做有限次重试

也就是说，把“必须先锁住再插入”的思路，改成“尝试插入，若冲突则重试”。这会让锁竞争面更小。

## 为什么 Java + Spring + Druid 平时不太容易复现

这一段也容易被误解：

> Java 端没怎么碰到过，说明 Druid 能自动规避这类问题。

这个结论不准确。更接近事实的说法是：

- 不是 Druid 自带 metadata lock 免疫能力
- 而是 Java 的默认工程模型，更不容易留下“Sleep 但事务没结束”的连接

### 1. 没显式事务时，默认就是短事务

在 Spring + MyBatis 常见用法里，如果一个查询方法没有 `@Transactional`，那么通常是：

- 从连接池借一个连接
- 执行查询
- 方法返回
- 框架把连接归还

如果 JDBC 连接是默认 `autocommit=true`，那么单条查询执行完事务就自然结束了。

### 2. 有事务时，Spring 会托管边界

如果方法上加了 `@Transactional`，Spring 会在方法退出时统一：

- 成功则 `commit`
- 异常则 `rollback`

只要开发者没有绕开框架，事务结束点是清晰的。

### 3. Druid 主要解决的是连接生命周期与健康检查

Druid 配置里常见的是这些：

```yaml
validationQuery: SELECT 1
testWhileIdle: true
testOnBorrow: false
testOnReturn: false
```

它们主要解决的是：

- 死连接
- 空闲连接失效
- 连接池复用时的健康检查

它们并不直接解决 metadata lock。

Java 端不容易复现，主要是因为：

- 连接更短命
- 事务边界更清晰
- 框架替你做了大部分收尾动作

不是因为连接池本身会处理 metadata lock。

## 典型 Java 示范：为什么默认写法更安全

一个典型的 Java 查询服务大概是这样：

```java
public List<Conversation> listConversations(String deptId, String userId) {
    return mapper.selectList(
        Wrappers.lambdaQuery(Conversation.class)
            .eq(Conversation::getDeptId, deptId)
            .eq(Conversation::getUserId, userId)
            .orderByDesc(Conversation::getCreatedAt)
    );
}
```

这段代码的几个特点是：

- 没手写 `Connection`
- 没自己控制 cursor 生命周期
- 没自己决定何时 commit/rollback
- 没把连接挂在一个长生命周期对象上

这种写法不容易形成“历史连接 Sleep 很久但事务还活着”的状态。

但这不代表 Java 就绝对安全。只要你写成下面这种风格，一样会中招：

```java
Connection conn = dataSource.getConnection();
conn.setAutoCommit(false);

PreparedStatement ps = conn.prepareStatement(
    "select * from ai_chat_conversations where conversation_id = ?"
);
ps.setString(1, conversationId);
ps.executeQuery();

// 中间发生异常、分支返回、或者忘记 rollback/close
```

这类手写 JDBC 风格，和 Python 那次问题是同一类风险。

## 正确的排查顺序

如果以后你再遇到类似报错，我建议按下面顺序排查，而不是上来先改连接池参数。

### 1. 先问自己：这真的是网络吗

只要满足两个条件，就要立刻把锁等待列入第一怀疑对象：

- SQL 本身很普通
- 报错总在几秒这种固定阈值附近出现

固定阈值通常意味着某个超时参数在生效，而不是随机网络抖动。

### 2. 立刻看 `SHOW FULL PROCESSLIST`

看 processlist 时，不要只盯自己的查询，要同时看同表是否存在：

- `Waiting for table metadata lock`
- `alter table ...`
- 很久的 `Sleep`

如果能同时看到“等待中的 DDL”和“等待中的查询”，基本已经能把方向锁定到 metadata lock。

可以用下面这个心智模型判断：

- `Waiting for table metadata lock` 说明这不是单纯慢查询
- `Sleep` 很久说明你要开始怀疑历史事务
- 报错时间稳定等于某个超时参数，说明应用侧只是“替数据库阻塞结账”

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

如果当前业务账号没有权限查这两张表，也不要因此停住。`SHOW FULL PROCESSLIST` 加上“停实例后是否恢复”的反证，通常已经足够完成第一轮判断。

### 4. 先止血，再修代码

止血手段通常是：

- kill blocker 会话
- 或直接重启持有这些连接的应用实例

修复手段才是：

- 确保只读事务及时结束
- 避免无意义的长事务
- 调整 DDL 执行窗口

比较稳的处理方式，是把现场止血和后续治理分开：

- 先恢复业务
- 再回到代码和连接模型上做长期修复

## 工程上的 4 个经验

### 1. `CommunicationsException` 不总是网络问题

它只是驱动层视角的结果，不是数据库根因诊断。

### 2. DDL 问题会把读流量一起拖死

很多团队低估了 DDL 对在线流量的影响，尤其是对 metadata lock 的影响。

### 3. `Sleep` 连接不等于“没问题”

一个连接显示 `Sleep`，只说明当前没有在执行 SQL，不代表它没有打开事务。

很多线上事故就是在这里判断失误：

> 这个连接都 Sleep 了，应该不是它。

实际上，在数据库排查里，`Sleep + 长时间 + 同表 DDL 等待`，恰恰是最该看的对象之一。

### 4. 连接池参数只能缓解表象，解决不了 blocker

把 `socketTimeout` 从 4 秒改成 30 秒，确实能减少误报，但它只能让错误“晚一点暴露”，不能让 metadata lock 自动消失。

线上排障时，最好把改动分成两类：

- 止血型：调大超时、先重启实例、先取消 DDL
- 根因型：收紧事务边界、清理长事务、改掉不必要的锁竞争

## 我会怎么做长期治理

如果把这次事故当作一个长期治理样本，我会做下面几件事。

### 代码层

- 明确所有只读查询路径的事务收尾策略
- 对手动事务连接，要求查询结束后显式 `rollback`
- 审查是否存在无必要的 `SELECT ... FOR UPDATE`

### 连接与框架层

- 尽量避免长期持有裸 `Connection`
- 让读请求走框架托管的短连接模型
- 对必须手写事务的代码，统一封装事务收尾模板

### 排障规范层

- 把 `SHOW FULL PROCESSLIST` 纳入数据库故障第一现场动作
- 把“固定 4 秒/5 秒/30 秒超时”与具体连接参数建立映射
- 形成 blocker / waiter 的统一术语，避免团队排障时混乱

### 运维层

- 给 DDL 设固定窗口
- 建立 metadata lock 排查脚本
- 对长时间 `Sleep` 且处于事务中的连接做巡检

### 应用层

- 记录 SQL 超时与锁等待的关联指标
- 把“固定 4 秒/5 秒超时报错”纳入锁等待排查模板
- 不把 `CommunicationsException` 简单等同于网络异常

## 延伸问答：这次排障里的几个关键追问

下面这些追问，基本把这次故障的关键点都补全了。

### 追问 1：Python 这次改动的目的到底是什么

Python 侧这次改动要解决的是一个很具体的问题：

- MySQL 连接是长生命周期对象
- 连接工作在 `autocommit=False`
- 只读查询执行完之后，没有显式结束事务

表面上看，查询已经返回，代码也没报错；但数据库视角下，这个事务可能并没有真正结束。连接一旦空闲，就会表现成：

- processlist 里是 `Sleep`
- 但它不是一个绝对干净的空闲连接
- 当同表发生 DDL 时，它就可能成为隐形 blocker

目标是把只读查询从：

- “查询完成但事务可能还活着”

改成：

- “查询完成后明确结束事务，再把连接留给后续复用”

所以修复点不在 SQL，而在事务收尾。

### 追问 2：为什么这个改动可以防止再次发生

先把根因写清楚：

> 这次事故的一类 blocker，来自“旧连接进入 Sleep，但背后事务没有结束”。

只要修复动作能稳定打断这条链，问题就会明显下降。

Python 修复为什么有效：

1. 读查询结束后统一 `rollback()`
2. `rollback()` 显式结束当前事务
3. 连接回到空闲态时，不再携带上一次查询对应的未结束事务
4. DDL 到来时，这批连接不再容易成为 metadata lock 的 blocker

这不是经验判断，是数据库会话模型本身决定的：

- 事务不结束，锁语义就可能继续存在
- 事务一旦结束，相关锁上下文才会被释放

这次修复对准的就是根因链条里最关键的一环。

### 追问 3：如果直接把 Python 改成 `autocommit=True`，是不是也能解决

答案是：对只读场景，很多时候也能缓解，但它不是这次最稳妥的修法。

原因在于，`autocommit=True` 改的是整个连接的默认事务行为。它带来的不是一个局部修复，而是“连接级事务模型切换”。

如果一个连接同时承担：

- 只读查询
- 会话写入
- 事件追加
- 状态更新

那么把它整体切成 `autocommit=True`，意味着：

- 原本依赖显式 `commit/rollback` 的写路径语义也变了
- 某些多语句逻辑可能会从“一个事务里提交”变成“每条语句独立提交”
- 这会把修复范围从“只读查询收尾”放大成“全链路事务模型变更”

所以更稳的做法是：

- 保留写路径的显式事务模型
- 只给读路径补一个确定的结束点

这也解释了为什么这次修复选择的是：

```python
try:
    ...
finally:
    conn.rollback()
```

而不是直接把整个连接改成 `autocommit=True`。

### 追问 4：Java 里用了 Druid，为什么平时基本没碰到这个问题

这个问题特别有价值，因为它很容易引出一个误解：

> Java + Druid 是不是天然能避免 metadata lock 这类问题？

答案不是。

Druid 本身主要解决的是：

- 连接池化
- 连接复用
- 空闲连接健康检查
- 坏连接剔除

它并不直接解决“事务边界不清晰”。

Java 端平时不容易踩中，更常见的真实原因是：

#### 1. 默认工程模型更健康

Spring + MyBatis 的常见写法通常是：

- 方法内调用 Mapper
- 框架从连接池借连接
- 执行 SQL
- 方法返回后归还连接

如果方法没有显式 `@Transactional`，很多只读查询天然就是短事务。

#### 2. 有事务时，框架托管边界

如果加了 `@Transactional`，Spring 会负责：

- 成功时 `commit`
- 异常时 `rollback`

也就是说，很多 Java 项目不是开发者自己手搓 `Connection` 和 `commit/rollback`，而是把事务生命周期交给了框架。

#### 3. Druid 让“坏连接”不容易暴露成同样的现象

像下面这类配置：

```yaml
validationQuery: SELECT 1
testWhileIdle: true
testOnBorrow: false
testOnReturn: false
```

可以减少死连接、失效连接、长时间空闲后借出坏连接这类问题。但它并不会替你结束一个没结束的事务。

更贴切的表述是：

- 不是 Druid 规避了 metadata lock
- 而是 Java 这套默认用法更不容易形成“Sleep 但事务还活着”的连接

### 追问 5：那 Java 端是不是就绝对安全

也不是。

如果 Java 代码写成下面这样，一样会踩中本质相同的问题：

```java
Connection conn = dataSource.getConnection();
conn.setAutoCommit(false);

PreparedStatement ps = conn.prepareStatement(
    "select * from ai_chat_conversations where conversation_id = ?"
);
ps.setString(1, conversationId);
ps.executeQuery();

// 某个异常路径提前 return，或者忘记 rollback/close
```

这种写法和 Python 那次问题在本质上没有区别：

- 都是长生命周期连接
- 都是手动事务
- 都依赖开发者自己收尾

关键不在语言，在连接和事务的组织方式。

### 追问 6：这次经验对开发工程师真正有价值的点是什么

更值得带走的是下面这条排障思路：

> 当普通查询在一个固定超时阈值上报 `CommunicationsException` 时，不要只看网络，也不要只看连接池，要立刻问一句：服务端是不是因为锁等待而一直没有返回数据。

这条思路要求同时看几件事：

- 你知道异常名字不等于根因
- 你知道固定超时通常意味着配置阈值而不是随机抖动
- 你知道 processlist 里的 waiter 和 blocker 要分开看
- 你知道 `Sleep` 连接不代表没有问题
- 你知道修复要对准因果链，而不是只改表象参数

这类故障很适合拿来做开发工程师进阶复盘，因为数据库、驱动、连接池、事务边界和工程写法都在里面。

## 最后

这次故障最该记住的一点是：

> 当一条普通查询在固定超时阈值上报通信失败时，开发工程师应该本能地怀疑“是不是锁在伪装成网络问题”。

很多进阶能力，不在于会多少中间件，而在于能不能建立跨层排查的因果链：

- 数据库锁怎么表现
- 驱动超时怎么包装
- 连接池怎么放大问题
- 应用日志为什么会误导你

这条链一旦建立起来，很多“看起来玄学”的线上问题，就会开始变得非常具体。

把这次问题压成一句话：

> 当普通查询在固定超时阈值上报 `CommunicationsException` 时，先别急着怪网络，先问一句：是不是某个旧事务正通过 metadata lock 让 MySQL 沉默。
