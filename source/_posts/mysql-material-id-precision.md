---
title: "MySQL 隐式类型转换导致物料串查：一次 Duplicate key C 排障"
date: 2026-09-12 18:00:00
categories:
  - "后端"
tags:
  - "Java"
  - "MySQL"
  - "数据库"
  - "排障"
  - "踩坑复盘"
source_archive:
  id: 20260912-mysql-material-id-precision
  rel_path: source_materials/posts/20260912-mysql-material-id-precision
  conversation_file: conversation.jsonl
---

一次铁水批次配料试算报错，表面看是 Java 在把元素含量压成 Map 时遇到了重复的 C：

~~~text
java.lang.IllegalStateException: Duplicate key C
~~~

异常里出现了两个不同物料的碳含量记录。最初容易怀疑物料主数据重复、查询查了两个数据库，或者 toMap 的去重策略有问题。最后确认，真正的原因在 SQL 参数类型：数据库的 material_id 是字符串，Java 实体却使用了 Long。19 位物料 ID 在 MySQL 做隐式数值比较时发生了精度折叠，单物料查询因此返回了多个物料的记录。

## 现场链路

请求来自铁水批次配料试算接口，候选物料有三个。Java 会为每个物料构造一个 Python 求解器请求：

~~~text
calculate
  -> calcMoltenIronBatch
  -> 遍历候选物料
  -> toMeltingMaterial
  -> toConstraintMaterialElements
  -> 查询该物料的元素含量
  -> 按 elementName 组装 Map
  -> 调用 Python 求解器
~~~

异常发生在最后一步之前。Python 没有收到请求，Java 在组装第一个物料的元素 Map 时就失败了。

相关代码的意图很清楚：

~~~java
TbMaterialElementContent condition = new TbMaterialElementContent();
condition.setMaterialId(materialId);
condition.setTenantId(currentDeptId);

List<TbMaterialElementContent> rows =
    tbMaterialElementContentMapper.selectList(Wrappers.query(condition));

return rows.stream().collect(Collectors.toMap(
    TbMaterialElementContent::getElementName,
    Function.identity()
));
~~~

这个 Map 是“单个物料的元素名 -> 元素含量”，不是把所有物料压成一个全局 Map。只要查询结果确实属于同一个物料，同名元素 C 出现一次是正常的。

## 证据一：SQL 看起来只查一个物料

现场 SQL 日志显示：

~~~sql
SELECT id, material_id, element_name, ...
FROM ats_erp.tb_material_element_content
WHERE delete_flag = '0'
  AND material_id = ?
  AND tenant_id = ?
~~~

参数只有一个物料 ID，结果数量为 10。异常对象却分别来自两个物料：

~~~text
物料 A：C = 1.8000
物料 B：C = 3.2000 ~ 3.8000
~~~

这就是最迷惑的地方：SQL 文本和参数看起来没有问题，返回结果却越过了物料边界。

## 证据二：表字段和 Java 字段类型不一致

在 DEV 租户实际使用的 ERP 库中，表结构是：

~~~sql
material_id varchar(32)
~~~

而 Java 实体定义是：

~~~java
private Long materialId;
~~~

MyBatis-Plus 根据实体类型把参数按 Long 绑定。于是数据库实际执行的是“字符串列和数值参数比较”：

~~~text
VARCHAR material_id = Long 参数
~~~

这不是存储阶段的数据损坏。数据库里保存的字符串是完整的，Java 里的 Long 也没有丢位；转换发生在 MySQL 判断 WHERE 条件的过程中。

## 为什么完整数字仍然会匹配错

这些 ID 已经是 19 位整数：

~~~text
7000000000000000001
7000000000000000002
7000000000000000003
~~~

当 MySQL 用数值方式比较字符串列和 Long 参数时，会先把字符串转成数值。这个数量级超过了双精度浮点数可以逐个区分相邻整数的范围，几个只相差 1 或 2 的 ID 可能转换成同一个近似值。

对照查询结果可以直接验证：

~~~text
按 Long 绑定查询：返回 3 个相邻物料的记录，共 10 条
按 String 绑定查询：只返回目标物料的 3 条记录
~~~

所以“数据库存的是完整值”和“查询结果错误”并不矛盾。值没有在存储时坏掉，而是在比较时被转换了。

## 为什么不是两个数据库合并

这个项目的 ERP Mapper 标记了 @TenantStorage。调用链是：

~~~text
Mapper 上的 @TenantStorage
  -> TenantStorageMybatisInterceptor
  -> TenantRouteContext
  -> TenantAwareDataSource
  -> 当前租户的客户库
~~~

一次 MyBatis selectList 只从一个物理数据源拿结果，代码里没有把云端库和客户库查询结果拼接起来。现场读取租户绑定配置后，也确认这次查询走的是租户客户库。

因此本次问题不是“两个数据库各返回一部分，然后合并出了重复 C”，而是单库中的一次错误类型比较，让一个 SQL 返回了多个物料。

## 为什么最后会报 Duplicate key C

查询结果实际类似这样：

~~~text
[
  { materialId: A, elementName: C, contentFixed: 1.8000 },
  { materialId: B, elementName: C, contentMin: 3.2000, contentMax: 3.8000 }
]
~~~

代码只使用 elementName 作为 Map 的 key：

~~~text
A + C -> key "C"
B + C -> key "C"
~~~

Java 的 Collectors.toMap 默认不允许重复 key，所以抛出异常。这个异常只是最后暴露问题的地方，根因已经发生在 SQL 查询阶段。

## 修复应该落在哪里

最小且正确的修复是让两边的类型一致：

- 如果 material_id 继续使用 VARCHAR，Java 查询条件必须按字符串绑定；
- 如果物料 ID 在整个系统都被定义为数值，应统一数据库字段为 BIGINT，并检查所有关联表和历史数据。

不应该直接把 toMap 改成“重复时取第一条”。这样只能让接口暂时不报错，却会丢掉另一个物料的真实成分，Python 后续计算结果也可能错误。

修复后还需要补一个跨物料回归场景：

~~~text
物料 A 和物料 B 都有 C
  -> 查询 A 的元素
  -> 结果只能包含 A
  -> 生成 A 自己的 elements Map
  -> 物料 B 同理
~~~

## 排查这类问题时容易漏掉的检查

1. 不只看 Java 变量的值，还要看数据库列类型和 JDBC 参数类型。
2. 不只看 SQL 文本，还要验证按字符串绑定和按数值绑定的结果差异。
3. 看到重复 Map key 时，不要马上加覆盖策略，先确认重复数据是否跨越了业务边界。
4. 多租户系统要区分“一个租户库内的错误查询”和“多个物理库结果合并”。
5. Java 服务调用 Python 之前，先确认请求对象是否已经成功构造；本次异常发生在 Python 边界之前。

这次故障最隐蔽的地方，是每个局部看起来都合理：ID 完整、SQL 只带一个参数、表里也确实有元素数据。只有把数据库类型、JDBC 绑定类型和 MySQL 比较规则放在同一条链路里看，才能解释为什么一个单物料查询会返回多个物料。

