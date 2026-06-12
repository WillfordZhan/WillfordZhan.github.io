---
title: "一次数据库查询 Skill 的小步优化"
date: 2026-06-12 18:13:45
categories:
  - "AI"
tags:
  - "AI工作日志"
  - "Agent"
  - "工程效率"
---

最近整理了一个给 Agent 用的数据库只读查询 Skill。目标很普通：让 Agent 能在本地通过固定脚本查 MySQL 和 Mongo，验证接口副作用、业务数据、测点数据，不要每次都临时拼连接、猜表、猜字段。

真正改起来，重点并不是“怎么查数据库”，而是三个更工程化的问题：

1. 这套 Skill 要给团队共享，不能带任何真实凭证。
2. Agent 查库时要少走弯路，不能靠全仓宽泛搜索碰运气。
3. Cookbook 要足够短，只沉淀高频口径，不把文档写成第二套系统。

## 先把凭证从配置里拆出去

最开始的 Skill 是从一份本地配置里读取数据库连接信息。这个方式自己用没问题，但一旦要 push 给团队，风险很明显：地址、库名、账号、密码混在一个文件里，稍不注意就把凭证也发出去了。

后面改成了两层配置：

```text
团队配置:
  db-config.yml
  只放环境、host、port、database、datasource、Mongo 地址

个人凭证:
  credentials.yml
  放在 Skill 目录下，被 .gitignore 忽略
```

脚本启动时先读团队配置，再读本地凭证，合并成实际连接信息。没有凭证、凭证为空、还是占位符，直接失败并提示先复制模板填写。

这里还有一个小坑：一开始我想把 MySQL 凭证做成“环境级一套”。后来发现不同 datasource 的账号可能不完全一样，于是改成了：

```text
datasource 级凭证优先
环境级凭证兜底
```

这样既能保持配置简单，也不会在某个 datasource 上因为账号不匹配而查询失败。

## 输出也要克制

中间有一个细节很小，但很典型：`list-ds` 成功时我打印了 `credential=ready`。

这其实没必要。用户只关心现在能不能用，缺凭证时脚本已经会失败并提示填写。成功时再打印一个 `credential=ready`，只是噪音。

最后输出收敛成：

```text
datasource    mysql://host:port/database    env=prod
```

这种输出更适合 Agent 继续读，也更适合人扫一眼。

## 查询路径不要靠全仓 rg 硬扫

这次最明显的浪费，是我在查业务口径时用了两次过宽的 `rg`。

这段有具体数字。根据归档的原始会话日志，从“填充凭证并验证 prod Mongo / MySQL 查询”开始，到 Mongo 和班次结果返回前，一共触发了 20 个工具调用。里面最浪费的是三次代码搜索：

```text
rg "班次|shift|Shift|class|排班|sys_dept|tenant_id|dept_id|tm_device_metric_last_data|mtc_no"
  原始输出 425316 tokens，8988 行

rg "tm_device_metric_last_data|mtc_no|metric.*last|did|alias|point|测点"
  原始输出 137602 tokens，2787 行

rg "class MongoHelper|metricNo\\("
  原始输出 10214 tokens，194 行
```

这些数字不是估算，是工具输出里的 `Original token count` 和 `Total output lines`。

当时想一次性确认：

- 班次表在哪里；
- 工厂 ID、车间 ID、设备 ID 怎么关联；
- Mongo 最新测点集合叫什么；
- `30:138` 这种测点口径怎么换成 Mongo 里的字段。

结果用了类似这种组合词去扫全仓：

```text
class / did / point / shift / dept_id / mtc_no
```

这类词太泛，尤其是 `class`、`did`、`point`，会命中大量无关 Java 类和设备逻辑。真正有价值的信息反而被淹没了。

更好的路径是：

```text
先用 information_schema 查表和字段
  -> 再用精确表名 rg -l 定位代码
  -> 最后 sed 目标文件片段
```

比如查班次表，优先问数据库：

```sql
select table_name
from information_schema.tables
where table_schema = database()
  and table_name like '%shift%';
```

需要确认字段时：

```sql
select column_name, data_type
from information_schema.columns
where table_schema = database()
  and table_name = 'xxx'
order by ordinal_position;
```

这比在代码仓库里扫 `shift|dept_id|class` 稳得多，也省上下文。

## Cookbook 只放高频入口

我一开始把 Cookbook 写得偏多：工厂名查部门、设备反查、Mongo 查询模板、历史桶查询、班次查询都想放进去。后来收了一轮，保留两类真正高频的东西。

第一类是 Mongo 测点规则，放进 `mongo.md`：

```text
did = device_internal_id
mtc_no = mod_no * 100000 + def_no
30:138 = 3000138

tm_device_metric_last_data:
  最新测点值

tm_device_metric_data_bucket:
  历史桶数据
  按 did + mtc_no + bkt_date 查询
  历史值在 map 里
```

第二类是工厂、设备、炉体常用 ID，放进一个很短的 cookbook：

```text
优先查 factory_furnaces 视图
一次拿到:
  dept_id
  workshop_id
  device_internal_id
  device_name
  fn_code
  fn_no
```

还有一个实用 hint：如果用户给的是 `AT_XXXX_XXXX`、`HX_XXXX_XXXX` 这种设备名，优先用 `device_name` 在这个视图里反查 `did`，再拿 did 去查 Mongo 或业务表。

这类内容够了。再往下写，就会变成“把所有查询都写进文档”，维护成本高，也会诱导 Agent 直接套模板，而不是先判断当前任务需要什么。

## 最后留下的约束

这次优化后，Skill 的边界更清楚了：

- 共享配置可以提交，真实凭证不能提交；
- MySQL 只允许 SELECT，Mongo 只允许 find/count；
- 缺凭证直接失败，不做隐式猜测；
- 常用业务口径写进 reference，但只写高频入口；
- 查 schema 优先走数据库元信息，少用宽泛代码搜索。

对 Agent 来说，这类 Skill 最重要的不是“能不能写出一条 SQL”，而是把容易出错的边界提前固定住：凭证边界、只读边界、配置边界、查询入口边界。

这些边界固定住以后，Agent 的自由度反而更高。它不用在连接方式、凭证来源、字段口径上反复猜，可以把上下文用在真正的问题判断上。
