---
title: "一次 SQLite 超时排查：测点缓存、单连接和先监测再优化"
date: 2026-05-06 17:26:12
tags:
  - "SQLite"
  - "Java"
  - "线上排障"
  - "性能监测"
source_archive:
  id: 20260506-sqlite-single-connection-monitor
  rel_path: source_materials/posts/20260506-sqlite-single-connection-monitor
  conversation_file: conversation.jsonl
---

这次排查的是边缘端 Java 服务的一次现场 CPU 飙高。

现象很直接：某天 15:30 到 16:00 左右，Java 进程 CPU 很高，日志里持续报 SQLite/JDBC 连接获取失败。现场关闭“测点缓存”功能并重启后，服务恢复。这个功能之前一直开着，只有那天爆了一次，后面也没有再打开。

一开始很容易把问题归到测点缓存上：关了它就好了，那是不是缓存库坏了？但日志和库文件检查对不上这个判断。更接近事实的是：测点缓存增加了主库 `app.db` 的读取频率，而主库连接池只有一个连接。当天现场压力叠上来以后，这个单连接先变成排队点，后面才出现连接超时、异常日志刷屏和 CPU 被拖高。

## 日志里真正关键的一行

当时最重要的报错是这一类：

```text
CannotGetJdbcConnectionException:
Failed to obtain JDBC Connection;
nested exception is java.sql.SQLTransientConnectionException:
file - Connection is not available, request timed out after 30000ms.
```

这里的 `file` 是主数据源，也就是 `app.db`。`request timed out after 30000ms` 也不是说某条 SQL 执行了 30 秒，而是线程等了 30 秒都没有从连接池拿到连接。

这个区别很重要。

如果是 SQL 慢，重点要看执行计划、索引、表大小。如果是连接拿不到，重点要看谁在占连接、连接池有多大、是不是大量线程一起进来排队。

当时异常也不是只出现在某一个业务点。子设备状态上报、设备轮询、语音播报、WebSocket 推送、系统配置读取都能撞上这个问题。它更像一个共享资源被挤爆了，而不是某个单独任务写错了。

简化一下链路：

```text
后台任务 / 推送 / 设备轮询
        |
        v
读取配置或业务状态
        |
        v
Hikari 连接池
        |
        v
app.db
```

如果连接池只有一个连接，所有读写主库的线程都要从这一扇门过。某个线程还没还连接，其他线程只能等。

## 测点缓存库本身没有坏

测点缓存写的是按天生成的本地库，例如：

```text
metric-20260415.sqlite
```

这次检查下来，这个库的完整性是正常的：

```text
integrity_check = ok
```

当天库里也有正常数据，不像是文件损坏或表结构损坏。并且日志里超时的数据源不是这个 `metric-*.sqlite`，而是主数据源 `file`。

所以这次不能简单写成“测点缓存 SQLite 坏了”。更准确的说法是：测点缓存打开后，会增加一部分对主库的访问；主库连接池太窄时，这部分访问会放大已有压力。

## 单连接到底卡在哪里

当时主库连接池大致是这样的配置：

```yaml
spring:
  datasource:
    dynamic:
      primary: file
      datasource:
        file:
          driver-class-name: org.sqlite.JDBC
          url: jdbc:sqlite:db/app.db
      hikari:
        max-pool-size: 1
```

`max-pool-size: 1` 的意思是，整个 Java 进程访问主库时，最多只有一个连接。

SQLite 是文件数据库，但不等于一个应用只能开一个连接。多个连接可以访问同一个 SQLite 文件，尤其是读操作，不是天然只能串行。这里真正把并发读挡住的，是应用层连接池。

可以这样理解：

```text
线程 A: 读系统配置  ----\
线程 B: 上报设备状态 -----\
线程 C: 推送前查配置 ------> 连接池只有 1 个连接 -> app.db
线程 D: 测点缓存检查 -----/
线程 E: 设备轮询    ----/
```

只要 A 拿着连接，B、C、D、E 都要等。平时每次查询很快，可能看不出问题。但如果某天后台任务多、日志多、CPU 或磁盘也紧张，连接归还变慢，排队就会很快堆起来。

这也是现场现象比较绕的地方：测点缓存不是新功能，也不是每天都出事；它只是把主库单连接这个弱点暴露出来了。

## 测点缓存为什么会读主库

测点缓存本身写的是 `metric-YYYYMMDD.sqlite`，但它的开关存在主库系统配置里：

```text
SIMPLE.ENABLE_LOCAL_METRIC_CACHE
```

也就是说，缓存写入链路里会先读主库判断“功能是否打开”。

简化后的链路大概是这样：

```text
MetricCacheSampler.sample()
  |
  v
MetricCacheToggle.isEnabled()
  |
  v
SystemConfigMapper.getValByKey(...)
  |
  v
app.db

采集到测点后入队
  |
  v
MetricCacheWriter.offer()
  |
  v
再次判断开关
  |
  v
app.db

后台写线程消费队列
  |
  v
写入前再判断开关
  |
  v
app.db -> metric-YYYYMMDD.sqlite
```

这里有一个很实际的问题：缓存写到一个库，但控制开关读另一个库。只要开关判断足够频繁，就会持续打到主库。

单看一次 `select config` 不重。真正麻烦的是它在后台调度里反复出现，而且和其他任务共用同一个主库连接池。

## SQLite 并发读强，不代表这个服务就强

排查时我也问过一个问题：SQLite 的并发读不是挺强吗，为什么会这样？

这里要把几层拆开：

```text
业务线程
  |
  v
Hikari 连接池
  |
  v
SQLite JDBC 连接
  |
  v
SQLite 文件
```

SQLite 支持多个读连接，不代表连接池一定会给业务线程多个连接。当前连接池只有一个连接时，线程还没到 SQLite 那一层，已经在 Hikari 外面排队了。

所以这次不是在证明“SQLite 并发读不行”。它说明的是：应用层配置把 SQLite 的读并发能力限制住了。

## WAL 和 busy_timeout 不是一回事

这次讨论里还有两个容易混在一起的配置：WAL 和 `busy_timeout`。

WAL 主要改善 SQLite 文件层面的读写并发。启用 WAL 后，读连接通常可以读一个稳定快照，写连接把新变更写到 WAL 文件里。读不会看到写到一半的数据，也不是靠脏读换性能。

但 WAL 解决不了“连接池只有一个连接”的问题。因为线程连连接都拿不到时，还没走到 SQLite 文件锁那一层。

`busy_timeout` 也是 SQLite 文件锁层面的等待时间。它处理的是：已经拿到连接了，但 SQLite 文件暂时被锁住，要不要等一会儿再报 `SQLITE_BUSY`。

这和 Hikari 的连接等待超时不同：

```text
Hikari connectionTimeout:
线程等连接池里的连接。

SQLite busy_timeout:
连接已经拿到了，SQLite 等文件锁。
```

这次日志里更明显的是 Hikari 连接池等待超时。所以 `busy_timeout` 可以作为后续调优的一部分，但不是这次现象的直接答案。

## 连接数能不能直接调大

可以试，但不应该盲调。

如果实际瓶颈是大量读请求堵在 Hikari 外面，把主库连接数从 1 提到 2 或 4，大概率会改善读等待。尤其是系统配置、设备状态这类短查询，多连接能让它们不要全挤在一条路上。

但 SQLite 的写仍然是串行的。连接数调大以后，如果没有 WAL、没有合理的 `busy_timeout`，或者有长事务，问题可能从“等连接”变成“等文件锁”。

所以连接数不是越大越好。比较稳的做法是先看数据：

```text
pending 很高，SQL 耗时不高
  -> 更像连接池太小

SQLITE_BUSY 很多
  -> 更像 SQLite 文件锁竞争

某几个 Mapper 调用特别频繁
  -> 先看调用点和缓存策略
```

没有这些数据时，改配置只能算猜。

## 缓存可以做，但不是第一刀

系统配置确实很适合缓存。比如测点缓存开关、系统音量、功能开关，这些 key 的特点是读很多、变很少。

但这次我不想马上把结论落到“加缓存”。原因是现在还不知道主库日常到底有多少读写、哪些 Mapper 最热、连接池等待有多严重。直接加缓存可能会让症状消失，但也会把真实压力藏起来。

如果后面要做缓存，我更倾向先把系统配置读写收敛到一个统一入口，而不是在各个业务点零散加缓存：

```text
业务代码
  |
  v
SystemConfigStore.getBool(key)
  |
  v
本地缓存
  |
  v
SystemConfigMapper
  |
  v
app.db
```

写入也要走同一个入口：

```text
SystemConfigStore.put(key, value)
  |
  v
写 app.db
  |
  v
刷新或失效本地缓存
```

这样做有两个好处。

第一个是应用内修改可以马上刷新缓存。比如系统音量这种配置，平时不变，但一变就要立刻生效，不能只靠几分钟 TTL。

第二个是以后排查更简单。业务代码不直接到处调 Mapper，而是统一从 `SystemConfigStore` 进出，缓存、监测、兜底都能放在这里。

不过缓存也有一个边界：如果有人绕过应用，直接改 SQLite 文件，应用内事件是感知不到的。这种场景只能靠短 TTL、版本号、`PRAGMA data_version` 或配置变更表去兜底。想做到“任何外部直接改库都立刻感知”，代价会明显变高。

## 现在更值得先做的是 SQLite 监测

这次真正缺的是观测数据。

我们现在只能根据日志判断：当时连接池拿不到连接，测点缓存关闭后恢复。但还不知道日常状态是什么样：

```text
app.db 每秒多少次 select？
多少次 insert/update？
哪些 Mapper 调用最多？
慢调用集中在哪？
Hikari active/idle/pending 是多少？
有没有 SQLITE_BUSY？
打开测点缓存后，系统配置读取量增加多少？
```

第一版不需要很重。可以加一个 MyBatis Interceptor，按 Mapper 统计调用次数、耗时、异常类型；再定时读取 Hikari 的连接池状态。每 30 秒打一条聚合日志就够用。

类似这样：

```text
sqlite-monitor
total=3200 select=2950 update=230 insert=20
avg=3ms p95=18ms max=420ms errors=2 busy=0
top=SystemConfigMapper.selectById:1800, DeviceStatusMapper.selectList:500
hikari active=1 idle=0 pending=12 total=1
```

注意不要在现场日志里打印完整 SQL 参数。聚合数据足够判断方向，也更安全。

配置上默认关闭，排查时打开：

```yaml
sqlite:
  monitor:
    enabled: false
    report-interval-ms: 30000
    slow-threshold-ms: 200
    top-n: 20
```

有了这些数据，再决定怎么改会踏实很多：

```text
先部署监测
  |
  v
采 1 到 3 天数据
  |
  v
看连接池等待、SQL 耗时、SQLITE_BUSY、热点 Mapper
  |
  v
再决定连接池、WAL、busy_timeout、缓存的优先级
```

## 这次排查后的判断

这次不是一个“SQLite 坏了”的问题，也不能简单写成“测点缓存导致 CPU 高”。

更准确的链路是：

```text
测点缓存高频检查开关
        |
        v
主库 app.db 读取变多
        |
        v
主库连接池只有 1 个连接
        |
        v
后台任务开始排队等连接
        |
        v
30 秒后连接获取超时
        |
        v
异常日志、线程等待、CPU/IO 压力继续放大
```

关闭测点缓存后恢复，说明它和事故强相关。但从证据看，它更像放大器，不一定是唯一根因。

下一步我会先补 SQLite 调用监测。等知道主库真实读写量级、连接池 pending、慢 Mapper 和 `SQLITE_BUSY` 分布后，再决定是提高连接池、开启 WAL、设置 `busy_timeout`，还是把系统配置读取收敛后加 Guava Cache。

这比直接上缓存慢一点，但排障不是把症状压下去就结束。先看清楚系统平时怎么跑，后面的优化才不容易改偏。
