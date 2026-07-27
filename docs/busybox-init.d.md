# BusyBox init.d 脚本编写规范

## 命名与执行顺序

- 启动脚本使用 `SNNname`，其中 `NN` 为 `00` 到 `99`。`rcS` 按编号从小到大执行，并传入 `start`。
- 关机脚本使用 `KNNname`。`rcK` 按编号从大到小执行，并传入 `stop`。
- 脚本必须使用 `#!/bin/sh`，只使用 POSIX shell 与当前 rootfs 已启用的 BusyBox applet。
- 脚本必须可执行；非可执行脚本会被调度器跳过。

## S 脚本动作契约

每个 `S[0-9][0-9]*` 脚本必须：

1. 定义 `action=${1:-start}`，无参数时默认执行 `start`。
2. 明确实现 `start)` 分支。
3. 对不支持的动作输出用法到标准错误，并返回 `2`。
4. 保证重复执行 `start` 不会启动重复进程或破坏已完成的初始化。

脚本可选实现以下动作：

- `stop`：停止服务或撤销可安全撤销的状态；重复停止应成功返回。
- `restart`：等价于成功执行 `stop` 后再执行 `start`。
- `status`：服务运行时返回 `0`，未运行时返回 `3`。

推荐分派结构：

```sh
#!/bin/sh

start_service() {
  # Start idempotently.
}

stop_service() {
  # Stop idempotently.
}

status_service() {
  if service_is_running; then
    echo "service is running"
    return 0
  fi
  echo "service is stopped"
  return 3
}

action=${1:-start}
case "$action" in
  start)
    start_service
    ;;
  stop)
    stop_service
    ;;
  restart)
    stop_service && start_service
    ;;
  status)
    status_service
    ;;
  *)
    echo "Usage: $0 [start|stop|restart|status]" >&2
    exit 2
    ;;
esac
```

## K 脚本约定

服务已有 `SNNname stop` 时，`KNNname` 应只作为关机包装器，避免维护两套停止逻辑：

```sh
#!/bin/sh

action=${1:-stop}
case "$action" in
  stop)
    exec /etc/init.d/SNNname stop
    ;;
  *)
    echo "Usage: $0 [stop]" >&2
    exit 2
    ;;
esac
```

## 服务与进程管理

- 常驻服务应优先以前台模式启动，再由脚本放入后台，以便 `$!` 对应真实服务 PID。
- PID 文件放在 `/run/<service>.pid`；读取 PID 后必须通过 `/proc/<pid>/comm` 或 `cmdline` 验证进程身份。
- `stop` 应先发送 `TERM` 并等待退出，超时后才可发送 `KILL`。
- 服务日志放在 `/var/log/`，运行时文件放在 `/run/`，持久配置放在 `/etc/`。
- 配置文件缺失、参数无效或服务启动失败时必须返回非零状态，不能静默报告成功。

## 返回码

- `0`：动作成功，或目标状态已经满足。
- `1`：运行时失败，例如配置缺失、挂载失败或服务启动失败。
- `2`：动作参数不受支持。
- `3`：仅用于 `status`，表示服务未运行。

新增或修改脚本后，应通过宿主 `/bin/sh -n`、目标 BusyBox `sh -n`、无参数动作检查和 `rcS`/`rcK` 顺序测试。
