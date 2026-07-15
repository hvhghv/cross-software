# cross-software

本仓库通过github action,交叉编译出各类常用的软件，默认静态链接musl库，同时会也产出动态链接的编译产物。

使用的交叉编译器[musl-gcc](https://github.com/hvhghv/musl-gcc/releases/tag/musl-gcc)

编译源代码放置在 `archive/` 里：

- `busybox-1.38.0.tar.bz2`
- `dropbear-2026.92.tar.bz2`
- `gdb-15.1.tar.gz`
- `gmp-6.3.0.tar.xz`
- `mpfr-4.2.2.tar.xz`

源码包校验值见 `archive/SHA256SUMS`。

## GitHub Actions 发布规则

每个软件使用独立 workflow 和独立 tag 后缀发布，tag 格式为：

```text
v<版本号>-<软件名>
```

示例：

- `v15.1-gdb`：只触发 GDB workflow，并只发布本次 GDB 新构建的产物。
- `v2026.92-dropbear`：只触发 Dropbear workflow，并只发布本次 Dropbear 新构建的产物。
- `v1.38.0-busybox`：只触发 BusyBox workflow，并只发布本次 BusyBox 新构建的产物。

GDB workflow 也可以通过 `workflow_dispatch` 手动触发构建；只有 `*-gdb` tag 会创建 GitHub Release。

GDB 发布包命名为 `gdb-gdbserver-<版本号>-<目标平台>-<dynamic|static>.tar.gz`，每个包内同时包含：

- `bin/gdb`
- `bin/gdbserver`

Dropbear workflow 也可以通过 `workflow_dispatch` 手动触发构建；只有 `*-dropbear` tag 会创建 GitHub Release。

Dropbear 发布包命名为 `dropbear-<版本号>-<目标平台>-<dynamic|static>.tar.gz`，每个包内包含：

- `sbin/dropbear`
- `bin/dbclient`
- `bin/dropbearkey`
- `bin/dropbearconvert`
- `bin/scp`

BusyBox workflow 也可以通过 `workflow_dispatch` 手动触发构建；只有 `*-busybox` tag 会创建 GitHub Release。

BusyBox 产物分为两类：

- static：`busybox-<版本号>-<目标平台>-static`，只发布一个静态链接 BusyBox 二进制文件。
- dynamic：`busybox-rootfs-<版本号>-<目标平台>-dynamic.tar.gz`，发布一个根文件系统目录，包含 `lib/` 里的 musl libc/loader、`bin/busybox`、`usr/bin/busybox`、`usr/sbin/busybox` 以及 BusyBox applet 软链接。
