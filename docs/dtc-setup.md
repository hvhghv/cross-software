# DTC 源码准备指南

本文档说明如何下载和校验 DTC (Device Tree Compiler) 源码。

## 下载源码

DTC 1.7.2 可以从以下来源下载：

### 方法 1：从 kernel.org 下载（推荐）

```bash
cd archive/
wget https://git.kernel.org/pub/scm/utils/dtc/dtc.git/snapshot/dtc-1.7.2.tar.gz
```

### 方法 2：从 GitHub 镜像下载

```bash
cd archive/
wget https://github.com/dgibson/dtc/archive/refs/tags/v1.7.2.tar.gz -O dtc-1.7.2.tar.gz
```

**注意**：两个来源的压缩包内容相同，但 tar.gz 归档本身的 SHA256 可能不同（取决于压缩参数和打包时间戳）。

## 验证源码

下载后计算 SHA256：

```bash
cd archive/
sha256sum dtc-1.7.2.tar.gz
```

将输出的哈希值更新到 `archive/SHA256SUMS`，替换占位符行：

```
# 替换这一行:
# dtc-1.7.2.tar.gz checksum placeholder - update after downloading source

# 为实际的 SHA256（示例格式）:
a1b2c3d4e5f6...  archive/dtc-1.7.2.tar.gz
```

## 本地测试编译

在提交到 GitHub Actions 前，建议本地测试编译：

```bash
# 解压源码
mkdir -p /tmp/dtc-test
tar xf archive/dtc-1.7.2.tar.gz -C /tmp/dtc-test

cd /tmp/dtc-test/dtc-1.7.2

# 本地编译（需要 gcc/make/bison/flex）
make -j$(nproc) NO_PYTHON=1 NO_YAML=1

# 测试 dtc
echo '/dts-v1/; / { compatible = "test"; };' > test.dts
./dtc -I dts -O dtb -o test.dtb test.dts
./fdtdump test.dtb
```

如果本地编译成功，说明源码包正常。

## 源码版本说明

### DTC 1.7.2

- **发布日期**：2024 年
- **上游仓库**：https://git.kernel.org/pub/scm/utils/dtc/dtc.git
- **功能特性**：
  - 完整的 DTS ↔ DTB 编译和反编译
  - 支持 `/include/` 和 C 风格预处理器
  - FDT 属性读写工具
  - 设备树覆盖层合并
  - libfdt 库（C 语言 API）

### 编译依赖

DTC 核心仅需：
- **必需**：C 编译器、make、bison、flex
- **可选（已禁用）**：Python（用于 pylibfdt）、libyaml（用于 YAML 支持）

本项目编译时设置 `NO_PYTHON=1` 和 `NO_YAML=1`，保持最小依赖。

## 提交源码到仓库

DTC 源码包较小（约 200 KB），可以直接提交到 `archive/` 目录：

```bash
git add archive/dtc-1.7.2.tar.gz
git add archive/SHA256SUMS
git commit -m "Add dtc-1.7.2 source archive"
```

或者只提交 SHA256SUMS，通过 CI 从 kernel.org 下载（需要修改 workflow 添加下载步骤）。

## 触发构建

源码准备完成后：

1. **手动触发**：在 GitHub Actions 页面，运行 "Build DTC" workflow
2. **标签发布**：推送 `v1.7.2-dtc` 标签会触发构建并创建 Release

```bash
git tag v1.7.2-dtc
git push origin v1.7.2-dtc
```

## 预期产物

每个架构（x86_64, ARM, AArch64, RISC-V 64）会生成 2 个包：

- `dtc-1.7.2-<arch>-static.tar.gz`：静态链接版本（约 400-600 KB）
- `dtc-1.7.2-<arch>-dynamic.tar.gz`：动态链接版本（约 300-400 KB + 库文件）

总共 8 个包 + 1 个 SHA256SUMS 文件。
