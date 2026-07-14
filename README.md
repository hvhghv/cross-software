# cross-software

本仓库通过github action,交叉编译出各类常用的软件，默认静态链接musl库，同时会也产出动态链接的编译产物。

使用的交叉编译器[musl-gcc](https://github.com/hvhghv/musl-gcc/releases/tag/musl-gcc)

编译源代码放置在 `archive/` 里：

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
- `v7.1.2-dropbear`：后续应由 Dropbear workflow 处理，不会触发 GDB 发布。

GDB workflow 也可以通过 `workflow_dispatch` 手动触发构建；只有 `*-gdb` tag 会创建 GitHub Release。
