# cross-software

本仓库通过github action,交叉编译出各类常用的软件，默认静态链接musl库，同时会也产出动态链接的编译产物。

现有软件 workflow 暂时使用外部 [musl-gcc](https://github.com/hvhghv/musl-gcc/releases/tag/musl-gcc)。本仓库已经提供自建 musl 交叉工具链的分阶段 workflow；自建工具链 Release 验证完成后，再将现有软件切换到本仓库的固定 Release。

编译源代码放置在 `archive/` 里：

- `busybox-1.38.0.tar.bz2`
- `dropbear-2026.92.tar.bz2`
- `gdb-15.1.tar.gz`
- `gmp-6.3.0.tar.xz`
- `mpc-1.3.1.tar.gz`
- `mpfr-4.2.2.tar.xz`
- `gcc-15.1.0.tar.xz`
- `binutils-2.44.tar.gz`
- `musl-1.2.6.tar.gz`
- `musl-cross-make-227df8b99103f9c59f6570babf892978e293082f.tar.gz`
- `linux-5.8.5.tar.xz.part-*`：Linux 5.8.5 源码包按 50 MiB 分片，Actions 中重组并校验完整源码 SHA256。

源码包校验值见 `archive/SHA256SUMS`。

## musl 交叉工具链

工具链固定使用以下版本：

- GCC 15.1.0
- Binutils 2.44
- musl 1.2.6
- Linux headers 5.8.5
- GMP 6.3.0
- MPC 1.3.1
- MPFR 4.2.2

支持 `x86_64-linux-musl`、`arm-linux-musleabi`、`aarch64-linux-musl` 和 `riscv64-linux-musl`。构建过程完全关闭 LTO，只启用 C/C++，并拆分为 bootstrap GCC/libgcc、musl、final GCC 三个 Actions 阶段。中间目录使用 `tar.zst` 保留权限、软链接和 Make marker，避免单个 GitHub Actions job 承担完整工具链构建时间。

普通分支 push 和 pull request 只验证离线源码、脚本与配置。通过 `workflow_dispatch` 可以构建一个目标或全部目标；tag `v15.1.0-musl1.2.6-linux5.8.5-nolto-r1-musl-gcc` 会构建四个目标并创建 Release。

每个目标发布两种工具链：

- `musl-toolchain-<架构>-debug.tar.gz`：保留调试段。
- `musl-toolchain-<架构>-nodebug.tar.gz`：移除调试段，作为后续软件构建的默认工具链。

每个工具链包包含 `BUILDINFO.txt`、`VERSIONS.txt`、`TREE.txt`、`FILELIST.txt` 和 `LICENSES/`。Release 同时发布源码 bundle、独立目录树/文件清单和总 `SHA256SUMS`。CI 会验证 C/C++ 的 dynamic/static 编译运行、QEMU 跨架构运行、Linux UAPI headers、工具链可迁移性、debug/nodebug 调试段以及 `-flto` 必须失败。

## GitHub Actions 发布规则

每个软件使用独立 workflow 和独立 tag 后缀发布，tag 格式为：

```text
v<版本号>-<软件名>
```

示例：

- `v15.1-gdb`：只触发 GDB workflow，并只发布本次 GDB 新构建的产物。
- `v2026.92-dropbear`：只触发 Dropbear workflow，并只发布本次 Dropbear 新构建的产物。
- `v1.38.0-busybox`：只触发 BusyBox workflow，并只发布本次 BusyBox 新构建的产物。
- `v15.1.0-musl1.2.6-linux5.8.5-nolto-r1-musl-gcc`：构建并发布本仓库的四架构 musl 交叉工具链。

普通分支 push 只监听各软件自己的 workflow、源码包和构建/打包脚本。`archive/SHA256SUMS` 是共享校验文件，不作为 workflow 触发条件，避免新增或修改某个软件的 checksum 时导致所有软件一起重编译；构建时仍会执行 checksum 校验。

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
- dynamic：`busybox-rootfs-<版本号>-<目标平台>-dynamic.tar.gz`，发布一个根文件系统目录，包含 `lib/` 里的 musl libc/loader、`bin/busybox` 以及指向它的 BusyBox applet 软链接。
