#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=musl-toolchain-common.sh
source "$SCRIPT_DIR/musl-toolchain-common.sh"

TARGET_TRIPLET=${TARGET_TRIPLET:?TARGET_TRIPLET is required}
TOOLCHAIN_STAGE=${TOOLCHAIN_STAGE:?TOOLCHAIN_STAGE is required}
JOBS=${JOBS:-2}

validate_target "$TARGET_TRIPLET"
for command in make tar zstd; do
  require_command "$command"
done

WORK_ROOT=$(stage_work_root "$TARGET_TRIPLET")
MCM_ROOT=$(stage_mcm_root "$TARGET_TRIPLET")
BUILD_ROOT=$(stage_build_root "$TARGET_TRIPLET")
guard_toolchain_work_root "$WORK_ROOT"

export CFLAGS="${CFLAGS:--O2 -g -fno-lto}"
export CXXFLAGS="${CXXFLAGS:--O2 -g -fno-lto}"
export CFLAGS_FOR_TARGET="${CFLAGS_FOR_TARGET:--O2 -g -fno-lto}"
export CXXFLAGS_FOR_TARGET="${CXXFLAGS_FOR_TARGET:--O2 -g -fno-lto}"
export BOOT_CFLAGS="${BOOT_CFLAGS:--O2 -g -fno-lto}"

case "$TOOLCHAIN_STAGE" in
  bootstrap)
    SOURCE_BUNDLE=${SOURCE_BUNDLE:?SOURCE_BUNDLE is required for bootstrap stage}
    [[ -f "$SOURCE_BUNDLE" ]] || die "source bundle not found: $SOURCE_BUNDLE"
    rm -rf "$WORK_ROOT"
    mkdir -p "$WORK_ROOT"
    tar -I zstd -xf "$SOURCE_BUNDLE" -C "$WORK_ROOT"
    cp "$TOOLCHAIN_CONFIG_DIR/config.mak" "$MCM_ROOT/config.mak"

    make -C "$MCM_ROOT" TARGET="$TARGET_TRIPLET" extract_all
    make -C "$MCM_ROOT" TARGET="$TARGET_TRIPLET" \
      "build/local/$TARGET_TRIPLET/Makefile" \
      "build/local/$TARGET_TRIPLET/config.mak"
    make -C "$BUILD_ROOT" -j "$JOBS" \
      "obj_gcc/$TARGET_TRIPLET/libgcc/libgcc.a" \
      obj_kernel_headers/.lc_built

    [[ -f "$BUILD_ROOT/obj_gcc/gcc/xgcc" ]] || die "bootstrap xgcc was not built"
    [[ -f "$BUILD_ROOT/obj_gcc/$TARGET_TRIPLET/libgcc/libgcc.a" ]] \
      || die "bootstrap libgcc was not built"
    [[ -f "$BUILD_ROOT/obj_sysroot/.lc_headers" ]] || die "musl headers were not installed"
    [[ -f "$BUILD_ROOT/obj_kernel_headers/.lc_built" ]] || die "Linux headers were not built"
    rm -rf "$MCM_ROOT/sources"
    create_stage_archive "$TARGET_TRIPLET" bootstrap
    ;;

  musl)
    INPUT_STAGE_ARCHIVE=${INPUT_STAGE_ARCHIVE:?INPUT_STAGE_ARCHIVE is required for musl stage}
    restore_stage_archive "$TARGET_TRIPLET" "$INPUT_STAGE_ARCHIVE"
    make -C "$BUILD_ROOT" -j "$JOBS" obj_sysroot/.lc_libs
    [[ -f "$BUILD_ROOT/obj_sysroot/lib/libc.so" ]] || die "musl libc.so was not installed"
    [[ -f "$BUILD_ROOT/obj_sysroot/lib/libc.a" ]] || die "musl libc.a was not installed"
    create_stage_archive "$TARGET_TRIPLET" musl
    ;;

  finish)
    INPUT_STAGE_ARCHIVE=${INPUT_STAGE_ARCHIVE:?INPUT_STAGE_ARCHIVE is required for finish stage}
    restore_stage_archive "$TARGET_TRIPLET" "$INPUT_STAGE_ARCHIVE"
    make -C "$BUILD_ROOT" -j "$JOBS" obj_gcc/.lc_built

    INSTALL_PREFIX="$MCM_ROOT/output"
    rm -rf "$INSTALL_PREFIX"
    make -C "$BUILD_ROOT" -j "$JOBS" OUTPUT="$INSTALL_PREFIX" install

    [[ -x "$INSTALL_PREFIX/bin/$TARGET_TRIPLET-gcc" ]] || die "final gcc was not installed"
    [[ -x "$INSTALL_PREFIX/bin/$TARGET_TRIPLET-g++" ]] || die "final g++ was not installed"
    [[ -x "$INSTALL_PREFIX/bin/$TARGET_TRIPLET-ld" ]] || die "final ld was not installed"
    [[ -d "$INSTALL_PREFIX/$TARGET_TRIPLET/include" ]] || die "final sysroot headers were not installed"

    write_output install_prefix "$INSTALL_PREFIX"
    echo "installed $TARGET_TRIPLET toolchain to $INSTALL_PREFIX"
    ;;

  *)
    die "unsupported toolchain stage: $TOOLCHAIN_STAGE"
    ;;
esac
