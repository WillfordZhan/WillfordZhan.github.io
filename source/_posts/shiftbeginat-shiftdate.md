---
title: "成本管理踩坑记录：shiftBeginAt 时间数组与 shiftDate 反序列化问题"
date: 2026-03-04 17:21:55
tags:
  - "成本管理"
  - "Jackson"
  - "踩坑记录"
  - "iot-framework"
---

这次排障集中在同一条链路上，表面上是两个错误，实质上都和 JSON 序列化/反序列化契约漂移有关。

关联提交（按你本地排障记录）：
- `8ba6d3c5914c23f29cd52f5326c79af4a0e8eced`
- `49957ccc62e80014546bf5a62685e9c73f0d8000`

## 现象

### 1) `shiftBeginAt` 返回成数组

接口返回里的 `shiftBeginAt` 形态是：

```json
"shiftBeginAt": [2026, 3, 2, 11, 14, 39]
```

前端期望通常是字符串时间（如 `2026-03-02 11:14:39`）或时间戳。数组格式会直接造成展示层/解析层兼容问题。

### 2) 请求体传 `shiftDate` 报 Jackson 反序列化异常

请求体（脱敏后）大致是：

```json
{"furnaceCode":"9","shiftDate":"2026-03-04"}
```

接口抛错为：`Unrecognized field "shiftDate" ... not marked as ignorable`，并且日志提示 DTO 已知字段只有 `furnaceCode`。

## 排查链路

### 事实

- `8ba6d3c...` 在 `AiAutoConfiguration` 里移除了自建 `ObjectMapper` Bean（`@ConditionalOnMissingBean` 的兜底 Bean 被删）。
- `49957ccc...` 又改成在配置类中手动 `new ObjectMapper().findAndRegisterModules()`，并改为不再通过 Spring 注入传递 `ObjectMapper`。

### 推断

同一个应用内出现了多个 `ObjectMapper` 来源：
- Spring Boot 自动配置出来的全局 `ObjectMapper`（通常带统一模块和全局特性）
- 配置类私有手动 `new` 的 `ObjectMapper`

这会导致“同一份 DTO/时间字段，在不同路径上被不同规则处理”。

### 已确认的根因

根因不是“Jackson 随机异常”，而是**序列化/反序列化配置失去统一入口**：
- 时间类型是否写成数组、字符串，取决于启用的特性和模块。
- 字段是否可识别，取决于当前反序列化器绑定的目标 DTO 结构与配置。

当调用链路混用了多个 `ObjectMapper`，行为就会出现非预期分叉。

## 修复思路

### 1) `ObjectMapper` 只保留一个应用级共享实例

在 Spring Boot 应用中，优先使用容器内的单例 Bean，不要在业务配置类里 `new ObjectMapper()`。

### 2) 所有 JSON 入口/出口统一走注入实例

包括工具分发、入口服务、HTTP 序列化响应，不要混用“注入 mapper + 私有 mapper”。

### 3) 局部定制用 `ObjectWriter/ObjectReader` 或 `copy()`

如果某个场景要临时格式化（例如特殊日期格式），不要改全局 mapper。

## 延伸问答：`ObjectMapper` 很重吗？要不要共享？

结论：**很重，且应共享。**

- `new ObjectMapper()` 的成本不低，包含模块注册、注解元数据处理、序列化器/反序列化器缓存建立等。
- 运行期复用单例，可以持续命中缓存，吞吐通常明显高于每次临时 new（常见基准能到数量级差距）。
- `ObjectMapper` 在“先完成配置、后并发使用”的前提下是线程安全的。

实践建议：
- Spring 项目：定义并复用一个全局 `ObjectMapper` Bean。
- 禁止在热路径中反复 `new ObjectMapper()`。
- 不在运行中动态改全局 mapper 配置；临时需求用 `ObjectWriter`/`ObjectReader` 或 `copy()`。

## 复盘结论

这次坑位本质是“配置入口分裂”问题，不是单点字段 bug。

可执行的长期约束：
- 统一 `ObjectMapper` 来源。
- 在 Code Review 中把“手动 new ObjectMapper”设为高风险项。
- 给关键接口补一层契约测试（日期字段格式、DTO 字段白名单/兼容行为），避免类似回归。
