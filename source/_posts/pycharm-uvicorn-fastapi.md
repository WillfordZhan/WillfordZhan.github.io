---
title: "PyCharm 调试 Uvicorn/FastAPI 与日志可见性排查"
date: 2026-02-27 15:39:56
tags:
  - "Python"
  - "FastAPI"
  - "Uvicorn"
  - "PyCharm"
  - "调试"
---

最近在调试一个 FastAPI + Uvicorn 的项目时，遇到两个高频问题：

1. PyCharm 里到底怎么正确配 `uvicorn main:app`？
2. 代码里明明写了 `LOGGER.info(...)`，控制台却看不到日志？

这篇只讲可直接落地的做法。

## 1) PyCharm 里如何用 Uvicorn 调试

新增一个 `Python` 类型 Run Configuration：

- `Run`: `Module name`
- `Module name`: `uvicorn`
- `Parameters`: `main:app --host 127.0.0.1 --port 8000`
- `Working directory`: 项目根目录
- `Python interpreter`: 安装过依赖的虚拟环境

建议调试时先不要加 `--reload`，热重载会拉起子进程，断点命中和日志输出都容易漂。

## 2) 为什么业务日志看不到

典型现象：

- Uvicorn 启动日志有
- 业务代码里的 `LOGGER.info(...)` 没有
- `warning/error` 偶尔有

根因通常是：Uvicorn 默认主要配置了 `uvicorn.*` logger，业务 logger（如 `app.*`）会冒泡到 root，而 root 默认阈值常是 `WARNING`，因此 `INFO` 被过滤。

## 3) 直接可用的修复方案

在启动入口（例如 `main.py`）里做一次应用日志初始化：

```python
import logging
import os

def configure_app_logging() -> None:
    log_level_name = os.getenv("APP_LOG_LEVEL", "INFO").upper()
    log_level = getattr(logging, log_level_name, logging.INFO)

    root_logger = logging.getLogger()
    root_logger.setLevel(log_level)

    if not root_logger.handlers:
        handler = logging.StreamHandler()
        handler.setFormatter(
            logging.Formatter("%(asctime)s %(levelname)s [%(name)s] %(message)s")
        )
        root_logger.addHandler(handler)

    logging.getLogger("app").setLevel(log_level)
```

需要更详细日志时：

```bash
APP_LOG_LEVEL=DEBUG
```

## 4) 最小验证方法

1. 启动后打一个断点。
2. 在断点附近写：

```python
LOGGER.info("debug_probe run_id=%s", run_id)
```

3. 看 PyCharm Debug Console 是否出现：

```text
2026-xx-xx xx:xx:xx,xxx INFO [app.orchestrator] debug_probe run_id=...
```

出现就说明链路打通了。

## 5) 三个容易踩坑的点

1. 直接 Run `main.py` 期待服务自动启动（多数项目不会，除非你写了 `if __name__ == "__main__"` 启动逻辑）。
2. 项目里有多个 venv，PyCharm 解释器选错。
3. 调试期默认开 `--reload`，导致你以为“断点或日志失效”。

如果你在做 FastAPI 的日常开发，这套配置建议固化成团队模板，能省掉不少无效排查时间。
