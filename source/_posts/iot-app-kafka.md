---
title: "本地启动 iot-app 禁用 Kafka 配置实践"
date: 2026-03-03 17:20:27
categories:
  - "后端"
tags:
  - "Java"
  - "Spring Boot"
  - "Kafka"
  - "Nacos"
  - "本地开发"
---

本地联调 `iot-app` 时，常见诉求是继续读取 Nacos 里的大部分配置，但不要连接 Kafka。直接把 Nacos 配置删掉通常不现实，因为同一个应用还依赖数据库、Redis、业务开关等其他远程配置。

这次采用的做法是：保留 Nacos 配置加载，只在 `local` 环境禁用 Kafka 自动装配和消费者注册，同时提供一个 no-op `KafkaTemplate`，让依赖 `KafkaTemplate` 的业务 Bean 仍然可以正常注入。

## 问题背景

一个典型的现象是：

- 应用本地启动时会从 Nacos 拉到 Kafka 地址
- `@KafkaListener` 会尝试启动消费者
- `KafkaTemplate` 相关 Bean 会按生产者配置初始化
- 本地没有 Kafka 或不希望访问测试环境 Kafka 时，启动过程就容易卡住或报错

如果项目里只是简单依赖了 `spring-kafka`，只关掉一个配置项往往不够，因为业务代码里通常已经直接注入了 `KafkaTemplate`，甚至还有多个消息消费者。

## 目标

本地启动满足下面三个条件：

- 仍然读取 Nacos 中除 Kafka 之外的配置
- 不创建 Kafka 自动配置相关 Bean
- 业务代码里已有的 `KafkaTemplate` 注入不报错

## 实现思路

### 1. 增加应用级开关

先在公共配置里增加一个总开关，默认开启：

```yaml
iot-app:
  kafka:
    enabled: true
```

然后在 `application-local.yml` 中显式关闭：

```yaml
spring:
  autoconfigure:
    exclude:
      - org.springframework.boot.autoconfigure.kafka.KafkaAutoConfiguration
      - org.springframework.boot.autoconfigure.kafka.KafkaAnnotationDrivenConfiguration

iot-app:
  kafka:
    enabled: false
```

这里的关键点有两个：

- `exclude` 直接禁掉 Spring Boot 的 Kafka 自动配置
- 本地环境把 `iot-app.kafka.enabled` 设为 `false`，让自定义条件配置生效

### 2. 给 Kafka 消费者加条件开关

如果项目里已经有消费者类，可以直接按配置控制是否注册：

```java
@Component
@ConditionalOnProperty(
    prefix = "iot-app.kafka",
    name = "enabled",
    havingValue = "true",
    matchIfMissing = true
)
public class MsgQueueConsumer {
    @KafkaListener(topics = "demo-topic", groupId = "${spring.application.name}")
    public void onMessage(String payload) {
        // ...
    }
}
```

这样在本地环境下，消费者 Bean 不会创建，`@KafkaListener` 也不会启动。

### 3. 提供一个 no-op KafkaTemplate

只禁用自动配置还不够。如果业务代码里已经有下面这种依赖：

```java
private final KafkaTemplate<String, String> kafkaTemplate;
```

那么启动时仍然可能因为缺少 `KafkaTemplate` Bean 失败。一个更稳的做法是：在 `iot-app.kafka.enabled=false` 时，注册一个空实现。

示意代码如下：

```java
@Configuration
@ConditionalOnProperty(prefix = "iot-app.kafka", name = "enabled", havingValue = "false")
public class KafkaDisabledConfig {

    @Bean
    @Primary
    @ConditionalOnMissingBean(KafkaTemplate.class)
    public KafkaTemplate<String, String> kafkaTemplate() {
        return new NoOpKafkaTemplate();
    }
}
```

这个 no-op `KafkaTemplate` 只需要覆盖当前项目实际会调用到的 `send(topic, data)` 方法，在本地环境下直接吞掉消息并返回一个已完成的 Future 即可。

## 为什么不用直接改 Nacos

原因很简单：本地不连 Kafka，不等于本地不用 Nacos。

很多项目的本地运行仍然依赖远程配置中心里的：

- 数据源
- Redis
- 多租户或工厂配置
- 其他业务开关

如果为了禁用 Kafka 去改共享 Nacos 配置，影响面会比本地代码开关大得多，也更容易误伤其他环境。

## 一个更实用的经验

如果你只是为了本地调接口、调页面、调成本逻辑，通常不需要真正发送或消费 Kafka 消息。这时候：

- 消费者直接不注册
- 生产者发送直接 no-op

比“本地也搭一套 Kafka”更省时间，问题边界也更清晰。

当然，这种方案只适合本地开发和非 Kafka 联调场景。如果你要验证消息链路、重试、消费幂等、分区行为，还是应该连真实 Kafka 或独立测试环境。

## 脱敏说明

为了避免把内部信息带到公开文章中，本文所有示例都做了脱敏处理：

- 内网域名、IP、端口改成示例值或占位符
- 本地绝对路径改成通用模块路径
- 密钥、令牌、命名空间等敏感字段不展示真实值
- 代码片段只保留实现思路，不直接贴完整业务代码

如果你也在写团队外可见的技术博客，这一步建议作为固定动作，而不是临发布前临时检查。

## 小结

本地启动 `iot-app` 又不想使用 Nacos 下发的 Kafka 配置时，比较稳妥的一套组合是：

- `local` 环境排除 Kafka 自动配置
- 用业务开关控制消费者是否注册
- 提供 no-op `KafkaTemplate` 兜底注入

这样既保住了本地开发效率，也避免为了一个中间件把整套远程配置体系拆开。
