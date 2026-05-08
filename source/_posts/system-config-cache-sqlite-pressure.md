---
title: "端侧 Java 服务的系统配置读写降压设计"
date: 2026-05-08 14:39:51
categories:
  - "日常开发"
tags:
  - "Java"
  - "SQLite"
  - "性能优化"
  - "缓存"
  - "开发回顾"
source_archive:
  id: 20260508-system-config-cache-sqlite-pressure
  rel_path: source_materials/posts/20260508-system-config-cache-sqlite-pressure
  conversation_file: conversation.jsonl
---

端侧 Java 服务里有一类配置读写很容易被忽略：系统配置表看起来很小，单次 `selectById` 也很快，但高频轮询、状态推送、版本上报叠在一起后，会把 SQLite 打成持续背景负载。

这次要处理的不是一次慢 SQL，而是低价值的高频读写。目标也很明确：不改变业务配置语义，减少系统配置读写次数，把优化开关做成可回退能力。

## 现场数据

监控窗口是 30 秒。某台端侧设备上的数据库监控大致是这样：

```text
system_config.select_by_id  ≈ 22,000 次 / 30s
system_config.read          ≈ 20,000 次 / 30s
system_config.update        ≈    360 次 / 30s
```

单次耗时并不吓人：

```text
select avg ≈ 0.29ms, p99 ≈ 3ms
update avg ≈ 4.7ms, p99 ≈ 8ms
```

如果只看平均值，很容易得出“问题不大”的判断。但换成调用频率，意义就不一样了：

```text
selectById 约 700 次 / 秒
updateById 约 12 次 / 秒
```

其中一部分写入是版本号这类同值写。值没有变，但链路仍然会走一遍查询、更新、配置变更通知和同步摘要失效。这类写入没有业务收益，只会制造 SQLite 写锁、MyBatis 对象分配和线程等待。

## 原链路的问题

原来的系统配置读取基本是直打数据库：

```text
业务代码
  -> getValByKey / getBoolByKey / getIntOrDefaultByKey
  -> selectById(config_key)
```

写入链路也没有判断值是否真的变化：

```text
insertOrUpdate(key, val)
  -> selectOne(config_key)
  -> 已存在: updateById(entity)
  -> onModifySystemConfig(key)
```

这里有两个问题：

1. 高频读每次都走 SQLite，即使配置值很少变化。
2. 同值写也会 update，并触发后续副作用。

第一反应可能是针对热点 key 做白名单，比如只缓存 LoRa、音量、版本号配置。但这种做法会不断追监控榜单：今天这个 key 热，明天另一个 key 热。问题本质不是某几个 key 特殊，而是系统配置值读取入口缺少统一的读优化。

## 开关先行

这类优化必须能关。端侧设备数量多，现场版本、配置、历史库状态都可能有差异。我们最后定的是一个总开关：

```text
ENABLE_SYSTEM_CONFIG_ACCESS_OPTIMIZATION
```

关闭时保持原行为：

```text
getValByKey -> selectById
insertOrUpdate -> 同值也 update
```

开启时启用两件事：

```text
getValByKey -> 进程内缓存，miss 后查 DB
insertOrUpdate -> 同值跳过 update 和后续变更通知
```

开关本身也要缓存。否则关闭优化时，每次读取配置都要先查一次开关，再查一次真正的配置，等于把一次 DB 读变成两次。

这里的开关缓存和配置值缓存是两层东西：

```text
开关缓存：
  始终启用，避免每次判断都查 DB。

配置值缓存：
  只有总开关开启后才启用。
```

## 缓存只做值镜像

缓存不能变成新的配置真源。SQLite 仍然是唯一持久化真源，缓存只是进程内读优化镜像。

配置表当前约束是：

```sql
config_key   text not null primary key
config_value text not null
```

因此缓存模型保持最小：

```text
ConcurrentHashMap<String, String>
```

只缓存这些值：

```text
DB 行存在
config_value != null
```

这些情况不缓存：

```text
DB 行不存在
config_value 为 null
写入入参为 null
```

空字符串不是特殊情况，原样缓存：

```text
""    -> ""
" "   -> " "
"0"   -> "0"
"false" -> "false"
```

这里没有额外加 `requireNonNull`。虽然表结构不允许 null，但如果已有业务链路真的传了 null，提前抛异常会改变异常位置和异常类型。优化层不应该改变原链路。写成功后如果值非 null，就更新缓存；如果值为 null，就移除缓存。

## 写后立即可见

运行时配置里有一些值需要修改后立即生效，比如音量、LoRa 轮询参数、设备绑定关系等。缓存不能靠 TTL 等到过期才生效。

所以一致性语义定成：

```text
同一个 Java 进程内：
配置写接口返回成功后，后续 mapper 配置读取必须立即看到新值。
```

写入成功后直接更新缓存：

```text
insert/update 成功
  -> value != null: cache.put(key, value)
  -> value == null: cache.remove(key)
```

同值跳过只在开关开启时生效：

```text
entity exists && Objects.equals(entity.configValue, val)
  -> 跳过 update
  -> 不触发 onUpdate
  -> 不触发配置变更通知
```

这个判断不能用 `nullToEmpty`。即使当前 schema 不允许 null，比较也要按原始值来做：

```java
Objects.equals(oldValue, newValue)
```

## 自刷新只刷新活跃 key

自刷新不是为了预热全表。系统已经有读穿透和写后更新：

```text
读操作：miss 后查 DB，并放入缓存。
写操作：写成功后更新缓存。
```

所以刷新只做兜底，处理人工改库、绕过 mapper 写入、缓存漂移这类情况。

最终策略是：

```text
每 60 秒：
  刷新总开关
  如果优化开启：
    批量刷新当前已缓存的 key
```

不全量扫描系统配置表，不逐个 key 查询：

```text
keys = cache.keySet()
select config_key, config_value
from system_config
where config_key in (...)
```

查询回来后做 reconcile：

```text
查到且 value != null -> cache.put(key, value)
查到但 value == null -> cache.remove(key)
没查回来的 key       -> cache.remove(key)
```

低频 key 不会被主动加载。它第一次被业务读到时再查库并进入缓存。这样缓存更贴近真实热点，也避免周期性把所有冷配置扫进内存。

## 接入位置

缓存组件放在 util 层，做成静态组件：

```text
SystemConfigCache
```

它不持有 Spring Bean，不复用已有的业务缓存。原因是已有缓存有自己的业务语义，而且会把不存在值转成空字符串，不适合承载系统配置的原值镜像。

刷新任务不单独建新 task 类，也不塞到顶层启动监听器里。顶层启动监听器不应该为了这个能力再依赖具体 mapper。更合适的位置是已有的周期任务服务：

```text
CronTaskService.init()
  -> CoreUtils.startDaemonTask(
       "systemConfigCacheRefresh",
       () -> SystemConfigCache.refresh(systemConfigMapper),
       Duration.ofSeconds(60)
     )
```

这个位置有两个好处：

1. 数据库初始化已经完成。
2. 周期任务职责本来就在这里，抽象边界比顶层启动监听器更合适。

## 监控边界

这次还顺手收了一处监控实现问题。

系统配置 mapper 里原来为了记录 key 级错误，把读写方法外层都包了一层 `try/catch`：

```text
try
  -> 原始 DB 操作
  -> DbMonitor.record(success)
catch
  -> DbMonitor.record(error)
  -> throw
```

这会让监控侵入热路径结构。`DbMonitor.recordXxx()` 自己已经会吞掉监控异常，SQL 级错误也有 MyBatis 拦截器记录。mapper 这层没有必要为了 key 级失败样本再包外层异常。

调整后只保留成功路径打点：

```text
原始 DB 操作
  -> DbMonitor.record(success)
```

异常仍按原链路抛出，SQL 级错误交给拦截器统计。监控不应该改变业务代码的控制流。

## 预期结果

上线后主要看两个指标：

```text
system_config.select_by_id
system_config.update_by_id
```

读缓存开启后，`selectById` 应该明显下降；同值写跳过后，版本号这类重复写应该接近消失。

这不是为了证明单条 SQL 变快，而是为了减少低价值调用次数。对端侧设备来说，这类优化的价值在于长期运行时少一点 SQLite 写锁、少一点对象分配、少一点线程等待。单台机器看起来只是背景负载，设备规模上来后，这些背景负载就会变成稳定成本。

这次实现刻意没有做更多东西：

```text
不做 app-monitor 指标
不做 cache hit/miss 指标
不做全表预热
不做分片刷新
不缓存 missing/null
不提前改变 null 入参行为
```

先把读写次数降下来，再用现有 db-monitor 对比前后效果。后续如果要证明 CPU、内存等硬件资源收益，再补应用资源监控，不把第一版做重。
