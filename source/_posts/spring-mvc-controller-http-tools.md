---
title: "把 Spring MVC Controller 接成 AI HTTP Tool：一套低侵入方案"
date: 2026-08-24 19:47:37
categories:
  - "AI"
tags:
  - "AI工作日志"
  - "AI Tool"
  - "Spring MVC"
  - "Swagger"
  - "MCP"
  - "Pi"
source_archive:
  id: 20260824-spring-mvc-http-tools
  rel_path: source_materials/posts/20260824-spring-mvc-http-tools
  conversation_file: conversation.jsonl
---

业务系统里已经有大量 Spring MVC Controller。如果为了接入 AI Tool，再为每个接口手写一层工具方法，会同时复制参数定义、响应结构和调用逻辑；接口变更时，两套代码还要同步维护。

更低侵入的做法是：保留现有 Controller，只在允许被 AI 调用的方法上增加 `@AiToolDef`。AI Runtime 从 Spring MVC 和 Swagger 元数据生成 Tool Schema，执行时再发起一次真实 HTTP 请求。这样，业务侧唯一必须做的改动就是显式标记哪些接口可以成为 Tool。

本文记录的是基于现有 Pi 与 Java Runtime 代码形成的设计方案，不是上线完成说明。当前代码已经具备本地反射 Tool、输入 Schema 和输出 Schema 的基础能力；HTTP Tool 是下一步扩展点。

## 两类 Tool 应该共存

现有 AI Tool Definition 适合调用同一 Java 进程内的方法。新增的 HTTP Tool 则负责复用已经存在的 Controller API。两者不需要互相替代：

```text
LOCAL Tool
  @AiToolComponent + @AiToolDef
  -> MCP tools/call
  -> Java 方法反射执行

HTTP Tool
  @Controller + @AiToolDef
  -> Pi 发起真实 HTTP 请求
  -> Filter -> Interceptor -> 参数绑定与校验 -> Controller
```

对模型来说，它们仍然都是普通 Tool：都有名称、描述、`inputSchema` 和 `outputSchema`。区别只存在于运行时的执行方式。

现有代码的边界也比较清楚：本地 Tool Registry 只扫描带 `@AiToolComponent` 的 Bean，并通过反射执行 `@AiToolDef` 方法；Java 侧 Tool 描述已经能携带 `outputSchema`，DTO 字段也已经支持从 `@ApiModelProperty` 补充说明。当前 Pi 适配层主要消费 `inputSchema`，Controller 扫描、HTTP 执行分流和 `outputSchema` 透传仍属于待实现部分。

最小的 Tool 描述可以增加一段不暴露给模型参数的执行元数据：

```json
{
  "name": "get_production_plan",
  "description": "查询生产计划详情",
  "inputSchema": {},
  "outputSchema": {},
  "execution": {
    "type": "http",
    "method": "GET",
    "path": "/api/plans/{planId}"
  }
}
```

`method` 和 `path` 必须来自服务端注册结果，不能让模型自由生成 URL。模型只负责填写经过 Schema 约束的业务参数。

## 一套 AI 注解，两套元数据来源

接入规则应该保持简单：

1. `@AiToolDef` 必须存在，它既是 Tool 定义，也是 Controller 接入 AI 的显式开关。
2. `@AiToolParam` 可选；存在时覆盖对应的 Swagger 参数说明。
3. DTO 字段上的 `@ToolField` 可选；存在时覆盖 `@ApiModelProperty`。
4. 没有 AI 专用注解时，复用 Swagger 的描述、必填和示例信息。

例如，一个已有接口只需要增加方法级 AI 注解：

```java
@GetMapping("/plans/{planId}")
@ApiOperation(value = "查询生产计划详情")
@AiToolDef(
    value = "根据计划 ID 查询生产计划详情",
    name = "get_production_plan",
    outputDescription = "返回生产计划详情"
)
public ApiResponse<PlanView> getPlan(
        @PathVariable("planId")
        @ApiParam(value = "生产计划 ID", required = true)
        Long planId) {
    return planService.getPlan(planId);
}
```

如果 Swagger 描述是面向普通接口调用者的，而模型需要更明确的约束，再增加 `@AiToolParam`：

```java
@AiToolParam(
    value = "生产计划的唯一 ID，必须来自计划查询结果",
    required = true
)
Long planId
```

DTO 字段采用同样的优先级：

```java
@ApiModelProperty(value = "物料编码", required = true, example = "M-001")
private String materialCode;

@ToolField(value = "模型可理解的字段说明")
@ApiModelProperty(value = "普通 API 文档说明")
private String specialField;
```

这里要把“结构事实”和“语义说明”分开：

```text
字段名称、类型、泛型、可见性
  -> Java 类型 + Jackson + Spring MVC

描述、标题、示例、必填语义
  -> AI 注解 > Swagger 注解 > 默认推导
```

不能让 Swagger 注解反过来改变真实 JSON 结构。`@JsonProperty`、`@JsonIgnore`、全局序列化配置和 Controller 参数绑定规则才是运行时事实。

## inputSchema 和 outputSchema 怎样生成

输入 Schema 来自 Controller 方法参数，并按 Spring MVC 绑定方式分组：

| MVC 参数 | HTTP 位置 | Schema 来源 |
| --- | --- | --- |
| `@PathVariable` | path | Java 类型 + AI/Swagger 描述 |
| `@RequestParam` | query | Java 类型 + 默认值 + required |
| `@RequestBody` | body | DTO 递归 Schema |
| `@ModelAttribute` 或普通查询对象 | query | DTO 字段展开 |

输出 Schema 应直接从方法的泛型返回类型生成，而不是只读一个手写的响应描述。例如：

```java
ApiResponse<PageResult<PlanView>>
```

Schema 生成器必须保留 `ApiResponse`、`PageResult` 和 `PlanView` 的完整泛型关系，并使用 Jackson 实际采用的字段名和忽略规则。否则外层响应虽然正确，内层 `records` 很容易退化为无结构的 `object`。

Swagger 的 `@ApiModelProperty` 可以补充字段的 `description`、`required`、`example` 和允许值，但无法单独保证复杂泛型的准确性。类型结构仍应由 Java 反射类型与 Jackson 的类型系统解析。

还要保证 Schema 与真实序列化结果一致。例如 Java `Long` 如果通过全局 Jackson 配置输出为字符串，Tool Schema 也必须描述成 `string`；否则模型会按 `integer` 回传，跨 JavaScript 运行时后可能发生精度丢失。

## 为什么不能直接反射 Controller

反射当然能调用 Controller 方法，但它不会自动经过完整 Spring MVC 链路：

```text
反射调用
  -> Controller 方法

真实 HTTP 调用
  -> Servlet Filter
  -> Spring Security
  -> HandlerInterceptor
  -> ArgumentResolver
  -> Bean Validation
  -> Controller 方法
  -> ResponseBody 序列化
```

如果目标是复用接口已有的登录态、角色校验、租户上下文、参数校验和统一异常处理，就应该发起真实 HTTP 请求，而不是在 Tool Runtime 里模拟一套 MVC。

角色权限仍由业务接口负责。HTTP Tool 层只负责把已有接口安全地暴露成 Tool，不重新定义角色模型，也不替业务接口补权限规则。没有权限校验的接口，应由接口维护者补齐。

## token 只存在于当前请求内存

认证 token 不应成为 Tool 参数，更不能让模型看见。推荐链路是：

```text
用户请求的 Authorization
  -> Pi 当前请求上下文（仅内存）
  -> HTTP Tool 执行器注入 Authorization
  -> 业务 Controller
  -> 当前请求结束后丢弃
```

需要明确禁止 token 进入以下位置：

- Tool Schema 和模型上下文；
- 会话消息与持久化记录；
- Tool 调用参数和 Tool 返回结果；
- 业务上下文对象；
- 普通请求日志与异常正文。

在这条链路里，Pi 只是把当前用户已经持有的 token 传给同一业务系统，不需要再发明 `delegationId`。如果未来出现跨用户代理、离线任务或长期授权，再单独设计受限凭证；当前同步请求没有这个需求。

## 与 MCP 的兼容边界

`tools/list` 同时返回 LOCAL 和 HTTP Tool 没有概念冲突。但让 Pi 读取自定义 `execution.type` 并直接请求 Controller，属于内部协议扩展，不是任意 MCP Client 都能理解的标准行为。

因此有两条可选路径：

1. 内部 Pi 优先：Pi 根据 `execution.type` 分流，HTTP Tool 直接调用业务接口。链路短，token 注入也最清晰。
2. 标准 MCP 优先：所有客户端仍调用 `tools/call`，Java Tool Provider 在服务端内部转成真实 HTTP 请求。兼容性更好，但多一层转发。

如果系统的主要调用方就是受控的 Pi Runtime，第一种足够简单。若要把同一套 Tool 无差别开放给第三方 MCP Client，应选择第二种，或者同时保留标准执行入口。

## 多服务场景不能靠扫描包解决

Spring 的 `RequestMappingHandlerMapping` 只能发现当前 `ApplicationContext` 中实际注册的 Controller。若 Tool Provider 与业务 Controller 分属不同进程，仅扩大包扫描范围并不能获得远端路由。

更通用的方案是让每个业务服务发布自己的 Tool Catalog，再由 Gateway 或 Pi 聚合：

```text
业务服务 A -> Tool Catalog A
业务服务 B -> Tool Catalog B
业务服务 C -> Tool Catalog C
                 |
                 v
          Gateway / Pi 聚合
```

这样服务边界、发布节奏和权限责任仍留在各自应用内，也避免中央服务通过源码扫描猜测远端 API。

## 第一版只支持稳定的 JSON REST 子集

V1 建议只覆盖：

- `GET`、`POST`、`PUT`、`PATCH`、`DELETE`；
- path、query 和单个 JSON body；
- 普通 JSON 响应；
- 启动时校验 Tool 名称、HTTP 方法和路由是否冲突。

暂不接入 multipart 文件上传、下载流、SSE、任意自定义 Header 和模型可控 URL。这些能力的参数绑定、超时和安全边界不同，等出现真实需求再单独设计。

## 结论

Controller 转 HTTP Tool 的核心不是“把反射再包装一层”，而是复用三套已经存在的事实：

1. `@AiToolDef` 决定哪些接口允许进入 AI Tool Catalog；
2. Java、Jackson、Spring MVC 与 Swagger 共同生成准确的输入输出 Schema；
3. 真实 HTTP 调用复用接口原有的认证、拦截器、权限校验和响应序列化。

最终业务侵入可以收敛为一个必需的 `@AiToolDef`，以及少量可选的 `@AiToolParam`、`@ToolField` 覆盖。LOCAL Tool 与 HTTP Tool 共用一套定义模型，在执行层分流；token 只跟随当前请求，不进入模型，也不进入持久化会话。
