---
title: "MySQL 联合唯一索引遇到 NULL：公共记录为什么会重复"
date: 2026-08-27 15:27:52
categories:
  - "数据库"
tags:
  - "MySQL"
  - "SQL"
  - "唯一索引"
  - "多租户"
source_archive:
  id: 20260827-mysql-null-unique-index
  rel_path: source_materials/posts/20260827-mysql-null-unique-index
  conversation_file: conversation.jsonl
---

设计多租户配置表时，我想用 `tenant_id = NULL` 表示公共配置，再给 `(tenant_id, skill_name)` 加联合唯一索引。直觉上，公共配置和 Skill 名称应该只能有一行，实际插入两条相同的公共记录时，MySQL 并不会报重复键错误。

这个行为容易被误判成索引失效。索引工作正常，冲突判断遇到的是 SQL 对 `NULL` 的特殊语义。

## 一个最小例子

```sql
CREATE TABLE skill_current (
    tenant_id BIGINT NULL,
    skill_name VARCHAR(128) NOT NULL,
    snapshot_id BIGINT NOT NULL,
    UNIQUE KEY uk_tenant_skill (tenant_id, skill_name)
);

INSERT INTO skill_current (tenant_id, skill_name, snapshot_id)
VALUES (NULL, 'create_plan', 101);

INSERT INTO skill_current (tenant_id, skill_name, snapshot_id)
VALUES (NULL, 'create_plan', 102);
```

两条 `INSERT` 都可以成功，表里出现两条：

```text
tenant_id | skill_name  | snapshot_id
----------+-------------+------------
NULL      | create_plan | 101
NULL      | create_plan | 102
```

MySQL 的唯一索引允许多行包含 `NULL`。联合索引也遵循这条规则：参与唯一键的列存在 `NULL` 时，重复元组可以同时存在。

## `NULL` 不是普通的“空值”

SQL 使用三值逻辑处理 `NULL`。下面的表达式结果不是 `TRUE`：

```sql
SELECT NULL = NULL;
```

结果是 `UNKNOWN`。`NULL` 表示未知或缺失，数据库不会把两个未知值当成相等值。唯一约束据此允许多条带 `NULL` 的记录。

查询也有同样的边界：

```sql
-- 查不到 tenant_id 为 NULL 的行
WHERE tenant_id = NULL

-- 正确写法
WHERE tenant_id IS NULL
```

下面这种写法也不能代替 `IS NULL`：

```sql
WHERE tenant_id IN (:tenantId, NULL)
```

公共记录需要显式写成：

```sql
WHERE tenant_id = :tenantId
   OR tenant_id IS NULL
```

## 公共范围用 `NULL` 还是 `0`

`NULL` 的含义更自然：它表示这条记录没有绑定具体租户。保留这个设计也可以，只是唯一性不能完全交给普通的 `(tenant_id, skill_name)` 唯一索引，需要额外的生成列、表达式索引或应用层约束。

这次的 Skill 设计更倾向用 `tenant_id = 0` 表示公共范围：

```sql
CREATE TABLE skill_current (
    tenant_id BIGINT NOT NULL,
    skill_name VARCHAR(128) NOT NULL,
    snapshot_id BIGINT NOT NULL,
    UNIQUE KEY uk_tenant_skill (tenant_id, skill_name)
);
```

公共 Skill 使用 `0`：

```text
(0, create_plan)
```

同一个公共 Skill 再插入一条时，唯一索引会直接拒绝。租户覆盖查询也可以写成：

```sql
SELECT tenant_id, skill_name, snapshot_id
FROM skill_current
WHERE tenant_id IN (:tenantId, 0)
ORDER BY CASE WHEN tenant_id = :tenantId THEN 0 ELSE 1 END
LIMIT 1;
```

这条约定有一个前提：`0` 必须被系统保留，不能作为真实租户 ID。数据库约束和业务约定需要同时成立，单独依赖其中一层都不够。

## 放回 Skill 的表设计

Skill 历史和当前指针分开保存：

```text
skill_snapshot
  tenant_id
  skill_name
  skill_version
  content

skill_current
  tenant_id
  skill_name
  snapshot_id
```

`skill_snapshot` 追加保存每次修改，`skill_current` 只指向当前版本。公共 Snapshot 和公共 Current 使用 `tenant_id = 0` 时，`UNIQUE (tenant_id, skill_name)` 可以保证同一个范围内只有一个 Current，回滚也只需要切换指针。

## 留下的判断

`NULL` 适合表达“没有租户归属”，`0` 适合把公共范围当成一个可以参与索引比较的保留域。两种设计都能工作，差异落在唯一约束、查询写法和数据清理成本上。

在需要“每个范围、每个名称只能有一个当前版本”的表里，我会优先让公共范围使用非空保留值，并在数据库中加唯一约束。这样规则能在并发写入时继续生效，查询也少一个 `IS NULL` 分支。
