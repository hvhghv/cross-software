# cross-software

本仓库通过github action,交叉编译出各类常用的软件，默认静态链接musl库，同时会也产出动态链接的编译产物。

现有软件 workflow 默认使用本仓库 [v15.1.0-musl-gcc](https://github.com/hvhghv/cross-software/releases/tag/v15.1.0-musl-gcc) 中固定发布的 LTO nodebug 工具链，并按 Release `SHA256SUMS` 校验首次下载的压缩包。

编译源代码放置在 `archive/` 里：

- `bash-5.3.tar.gz`：Bash 5.3 源码；官方补丁保存在 `patches/bash-5.3/`。
- `busybox-1.38.0.tar.bz2`
- `dhcpcd-10.5.0.tar.xz`
- `dropbear-2026.92.tar.bz2`
- `gdb-15.1.tar.gz`
- `gmp-6.3.0.tar.xz`
- `hostapd-2.12.tar.gz`
- `libnl-3.12.0.tar.gz`
- `mpc-1.3.1.tar.gz`
- `mpfr-4.2.2.tar.xz`
- `wpa_supplicant-2.12.tar.gz`
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

支持 `x86_64-linux-musl`、`arm-linux-musleabi`、`aarch64-linux-musl` 和 `riscv64-linux-musl`。只启用 C/C++，并拆分为 bootstrap GCC/libgcc、musl、final GCC 三个 Actions 阶段。每个架构的 bootstrap、Linux headers 和 musl 只构建一次，final GCC 再分别构建 nolto 与 LTO 两种配置。中间目录使用 `tar.zst` 保留权限、软链接和 Make marker，避免单个 GitHub Actions job 承担完整工具链构建时间。

`main` 或 `master` 分支中与工具链相关的 workflow、源码、脚本或配置发生变化时，会自动构建全部四个架构；pull request 只执行离线源码、脚本与配置校验。通过 `workflow_dispatch` 可以构建一个目标或全部目标；tag `v15.1.0-musl-gcc` 会构建四个目标并创建 Release。

每个目标发布三种工具链，Actions 结果页分别提供独立 artifact：

- `musl-toolchain-<架构>-debug.tar.gz`：保留调试段。
- `musl-toolchain-<架构>-nodebug.tar.gz`：关闭 LTO 并移除调试段。
- `musl-toolchain-<架构>-lto-nodebug.tar.gz`：启用 LTO 并移除调试段。

每个工具链包包含 `BUILDINFO.txt`、`VERSIONS.txt`、完整的 `TREE.txt`、`FILELIST.txt` 和 `LICENSES/`。Release 页面正文直接展示每个包的三级目录树，不再发布独立 tree/filelist 附件；Release assets 只包含工具链包、源码 bundle 和总 `SHA256SUMS`。CI 会验证 C/C++ 的 dynamic/static 编译运行、QEMU 跨架构运行、Linux UAPI headers、工具链可迁移性、debug/nodebug 调试段、nolto 的 `-flto` 拒绝，以及 LTO 工具链使用 `-flto` 的编译、链接和运行。

## GitHub Actions 发布规则

每个软件使用独立 workflow 和独立 tag 后缀发布，tag 格式为：

```text
v<版本号>-<软件名>
```

示例：

- `v15.1-gdb`：只触发 GDB workflow，并只发布本次 GDB 新构建的产物。
- `v2026.92-dropbear`：只触发 Dropbear workflow，并只发布本次 Dropbear 新构建的产物。
- `v1.38.0-busybox`：只触发 BusyBox workflow，并只发布本次 BusyBox 新构建的产物。
- `v5.3-bash`：只触发 Bash workflow，并发布四架构的 dynamic/static 产物。
- `v2.12-wpa_supplicant`：只触发 wpa_supplicant workflow，并发布四架构的动态/静态产物。
- `v15.1.0-musl-gcc`：构建并发布本仓库的四架构 musl 交叉工具链。

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

Dropbear 的可选 `/etc` overlay 位于 `etc/dropbear/`，包含 `init.d/S95dropbear`、`init.d/K95dropbear` 和由启动脚本解析的 `ssh/sshd_config`。将该目录合并到目标机的 `/etc/` 后，首次执行 `/etc/init.d/S95dropbear start` 会在 `/etc/ssh/` 中自动生成配置缺失的 Ed25519、ECDSA 和 RSA host key。Dropbear 不原生读取 OpenSSH `sshd_config`，该模板只接受文件内列出的兼容指令，遇到不支持的指令会拒绝启动并报告行号。

wpa_supplicant workflow 可通过 `workflow_dispatch` 手动触发；只有 `v2.12-wpa_supplicant` tag 会创建 GitHub Release。每个目标同时生成 dynamic 和 static 两种 `wpa_supplicant-2.12-<目标平台>-<dynamic|static>.tar.gz`，包内包含：

- `/usr/sbin/hostapd`
- `/usr/bin/hostapd_cli`
- `/usr/sbin/wpa_supplicant`
- `/usr/bin/wpa_cli`
- `/usr/sbin/dhcpcd`
- `/etc/dhcpcd.conf`
- `/usr/libexec/dhcpcd-run-hooks`、`/usr/libexec/dhcpcd-hooks/` 和 `/usr/share/dhcpcd/hooks/`

这些程序全部由独立源码编译，`dhcpcd` 不是 BusyBox applet。dynamic 包额外携带 hostapd/wpa 所需的 libnl 运行库，目标 rootfs 仍须提供对应架构的 musl loader 和 libc；static 包中的五个 ELF 均无共享库依赖。

为控制体积，hostapd/wpa 使用源码内置 TLS/crypto 实现，dhcpcd 使用 `--without-openssl`，发布包不包含也不依赖 OpenSSL。当前保留 WPA/WPA2、WPS、PMF、nl80211、hostapd AP、wpa_supplicant AP/P2P 和常用 EAP 方法；依赖 hostap 内部 crypto 未提供的大数/ECDH 接口的 WPA3-Personal SAE、OWE 和 DPP 未启用。配置中的 `openssl_ciphers` 等字段名仍可能出现在程序字符串表中，但内部 TLS 会报告该选项不受支持，这不表示链接了 OpenSSL。

dhcpcd 保留 privilege separation。`etc/busybox/` 模板已加入锁定、不可登录的 `dhcpcd` 用户和同名组，固定 UID/GID 为 `23`，主目录为 `/var/empty`，shell 为 `/bin/false`；部署 wpa_supplicant 工具包到其他 rootfs 时也必须提供这条账户记录。wpa_supplicant 发布包不修改现有 BusyBox rootfs 的账户文件，也不会自动创建该账户。hostapd 和 wpa_supplicant 的站点配置不随包预置，部署时分别提供适合目标网卡和网络的配置文件。

BusyBox workflow 也可以通过 `workflow_dispatch` 手动触发构建；只有 `*-busybox` tag 会创建 GitHub Release。

BusyBox 产物分为两类：

- static：`busybox-<版本号>-<目标平台>-static`，只发布一个静态链接 BusyBox 二进制文件。
- dynamic：`busybox-rootfs-<版本号>-<目标平台>-dynamic.tar.gz`，发布一个完整根文件系统目录，包含 `bin/busybox`、BusyBox applet 软链接，以及工具链 `lib/`、`usr/lib/` 中的 `*.so`/`*.so.*` ELF 共享库和对应的有效相对软链接；静态库和启动对象不会进入 rootfs。musl loader 保持为 `ld-musl-<架构>.so.1 -> libc.so`，不会复制成第二份 libc。

动态 rootfs 中的 `/run` 是空的 tmpfs 挂载点。`S00mount` 挂载 `/run` 后创建 `/run/lock`，服务进程再按需写入 PID 和其他运行时文件；这些内容不会预置到发布包。

动态 rootfs 的 `/etc` 模板保存在 `etc/busybox/`。账户数据库包含常用嵌入式系统账户、设备访问组及锁定的 `sshd`、`dhcpcd` privilege-separation 账户，发布 tar 内的文件统一记录为 `root:root`。BusyBox init 启动时由 `rcS` 按 `S00` 到 `S99` 执行 `/etc/init.d` 脚本，关机时由 `rcK` 按 `K99` 到 `K00` 逆序停止服务并最后卸载文件系统。默认顺序为挂载虚拟文件系统、启动 mdev daemon、配置网络和启动 telnetd；`S90network` 使用 `ifup -a -i /etc/network/interface` 启动所有标记为 `auto` 的接口，并在停止时执行对应的 `ifdown -a`。配置格式遵循 BusyBox ifupdown：`iface eth0 inet dhcp` 使用 DHCP，`iface eth0 inet static` 配置静态 IPv4；两种模式都支持在接口段中通过 `dns-nameservers` 设置 DNS，DHCP 模式下该设置优先于服务端下发的 DNS。未设置 `dns-nameservers` 时，DHCP 退租不会清空现有 `/etc/resolv.conf`。没有加入 `auto` 的接口不会在启动阶段启用。修改 `etc/busybox/**` 会触发四架构 BusyBox workflow。

新增服务脚本应遵循 [BusyBox init.d 脚本编写规范](docs/busybox-init.d.md)。所有 `S[0-9][0-9]*` 脚本必须支持 `start`，且无参数时默认执行 `start`；`stop`、`restart` 和 `status` 为可选动作。

`S99telnetd` 默认在 TCP 23 端口使用 `/bin/login`。Telnet 不加密传输，且模板中的 root 密码当前为空；将 rootfs 部署到可访问网络前必须设置 root 密码或禁用该启动脚本。

TFTP init 脚本作为可选 `/etc` overlay 保存在 `etc/tftpd/init.d/`，不会复制到默认 BusyBox rootfs。将 `etc/tftpd/` 合并到目标机的 `/etc/` 后，服务将通过 `udpsvd` 监听 UDP 69，以 `nobody` 身份在 `/srv/tftp` chroot 中提供只读 TFTP。TFTP 不提供认证或传输加密，不应暴露到不可信网络。

## Bash 与 BusyBox shell

Bash workflow 使用 Bash 5.3 源码和官方 `bash53-001` 至 `bash53-015` 补丁，分别为四个 musl 目标构建 dynamic/static 二进制。Bash 安装为独立的 `/bin/bash`，启用多字节和内置 readline/history，不启用 NLS，也不引入 OpenSSL、ncurses 或其他外部 shell UI 运行库；它不会替换 BusyBox 的 `/bin/sh`。

BusyBox 使用完整 ash 作为 `/bin/sh` 和 `/bin/ash`，显式启用 Unicode、locale、宽字符、中文 UTF-8 行编辑、历史和补全；ash 同时启用别名、作业控制、bash 兼容、参数展开、内置 help/getopts/test 等功能。rootfs `/etc/profile` 默认设置 `LANG=C.UTF-8` 和 `LC_CTYPE=C.UTF-8`，调用者可以覆盖它们。hush 已关闭，BusyBox 不再提供 hush applet。由于 Bash 和 BusyBox 均关闭 NLS，shell 内置错误信息保持英文；这不影响中文输入、变量处理和终端显示。发布 tag 为 `v5.3-bash`。
