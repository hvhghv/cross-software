#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=musl-toolchain-common.sh
source "$SCRIPT_DIR/musl-toolchain-common.sh"

TARGET_TRIPLET=${TARGET_TRIPLET:?TARGET_TRIPLET is required}
INSTALL_PREFIX=${INSTALL_PREFIX:?INSTALL_PREFIX is required}
QEMU_RUNNER=${QEMU_RUNNER:-}
DIST_DIR=${DIST_DIR:-"$REPO_ROOT/dist/musl-toolchain"}

validate_target "$TARGET_TRIPLET"
for command in file find gzip readelf readlink sha256sum strip tar tree; do
  require_command "$command"
done

ARCH=$(target_asset_arch "$TARGET_TRIPLET")
TARGET_MACHINE=$(target_machine_pattern "$TARGET_TRIPLET")
MCM_ROOT=$(stage_mcm_root "$TARGET_TRIPLET")
PACKAGE_WORK_ROOT="$REPO_ROOT/build/musl-toolchain-packages/$TARGET_TRIPLET"
DEBUG_NAME="musl-toolchain-$ARCH-debug"
NODEBUG_NAME="musl-toolchain-$ARCH-nodebug"
DEBUG_ROOT="$PACKAGE_WORK_ROOT/$DEBUG_NAME"
NODEBUG_ROOT="$PACKAGE_WORK_ROOT/$NODEBUG_NAME"
TARGET_STRIP="$INSTALL_PREFIX/bin/$TARGET_TRIPLET-strip"

[[ -d "$INSTALL_PREFIX" ]] || die "install prefix not found: $INSTALL_PREFIX"
[[ -x "$TARGET_STRIP" ]] || die "target strip not found: $TARGET_STRIP"
case "$PACKAGE_WORK_ROOT" in
  "$REPO_ROOT"/build/*) ;;
  *) die "refusing to modify unexpected package path: $PACKAGE_WORK_ROOT" ;;
esac

rm -rf "$PACKAGE_WORK_ROOT"
mkdir -p "$DEBUG_ROOT" "$NODEBUG_ROOT" "$DIST_DIR"
cp -a "$INSTALL_PREFIX/." "$DEBUG_ROOT/"
cp -a "$INSTALL_PREFIX/." "$NODEBUG_ROOT/"

make_musl_loader_relocatable() {
  local root=$1
  local loader
  local loader_count=0
  local loader_target

  while IFS= read -r loader; do
    loader_target=$(readlink "$loader")
    [[ "$loader_target" == /lib/libc.so || "$loader_target" == libc.so ]] \
      || die "unexpected musl loader target: $loader -> $loader_target"
    ln -sfn libc.so "$loader"
    loader_count=$((loader_count + 1))
  done < <(find "$root/$TARGET_TRIPLET/lib" -maxdepth 1 -type l \
    -name 'ld-musl-*.so.1' -print)

  [[ "$loader_count" == 1 ]] || die "expected exactly one musl loader in $root"
}

copy_licenses() {
  local root=$1
  local license_dir="$root/LICENSES"
  mkdir -p "$license_dir"

  cp "$MCM_ROOT/LICENSE" "$license_dir/musl-cross-make-LICENSE"
  cp "$MCM_ROOT/COPYRIGHT" "$license_dir/musl-cross-make-COPYRIGHT"
  cp "$MCM_ROOT/gcc-$GCC_VERSION/COPYING" "$license_dir/gcc-COPYING"
  cp "$MCM_ROOT/gcc-$GCC_VERSION/COPYING3" "$license_dir/gcc-COPYING3"
  cp "$MCM_ROOT/gcc-$GCC_VERSION/COPYING.RUNTIME" "$license_dir/gcc-COPYING.RUNTIME"
  cp "$MCM_ROOT/binutils-$BINUTILS_VERSION/COPYING" "$license_dir/binutils-COPYING"
  cp "$MCM_ROOT/binutils-$BINUTILS_VERSION/COPYING3" "$license_dir/binutils-COPYING3"
  cp "$MCM_ROOT/musl-$MUSL_VERSION/COPYRIGHT" "$license_dir/musl-COPYRIGHT"
  cp "$MCM_ROOT/gmp-$GMP_VERSION/COPYING" "$license_dir/gmp-COPYING"
  cp "$MCM_ROOT/mpc-$MPC_VERSION/COPYING.LESSER" "$license_dir/mpc-COPYING.LESSER"
  cp "$MCM_ROOT/mpfr-$MPFR_VERSION/COPYING" "$license_dir/mpfr-COPYING"
  cp "$MCM_ROOT/linux-$LINUX_VERSION/COPYING" "$license_dir/linux-COPYING"
}

write_metadata() {
  local root=$1
  local variant=$2

  cat > "$root/BUILDINFO.txt" <<EOF
target=$TARGET_TRIPLET
variant=$variant
release_id=$TOOLCHAIN_RELEASE_ID
musl_cross_make_commit=$MUSL_CROSS_MAKE_COMMIT
optimization=-O2
debug_flags=-g
lto=disabled
build_cflags=-O2 -g -fno-lto
github_repository=${GITHUB_REPOSITORY:-local}
github_sha=${GITHUB_SHA:-local}
github_run_id=${GITHUB_RUN_ID:-local}
build_time_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

  cat > "$root/VERSIONS.txt" <<EOF
gcc=$GCC_VERSION
binutils=$BINUTILS_VERSION
musl=$MUSL_VERSION
linux_headers=$LINUX_VERSION
gmp=$GMP_VERSION
mpc=$MPC_VERSION
mpfr=$MPFR_VERSION
musl_cross_make=$MUSL_CROSS_MAKE_COMMIT
lto=disabled
EOF
}

strip_nodebug_tree() {
  local root=$1
  local candidate
  local info

  while IFS= read -r candidate; do
    case "$candidate" in
      *.a|*.o)
        case "$candidate" in
          "$root/$TARGET_TRIPLET"/*|"$root/lib/gcc/$TARGET_TRIPLET"/*)
            "$TARGET_STRIP" --strip-debug "$candidate"
            ;;
        esac
        continue
        ;;
    esac

    info=$(file -b "$candidate")
    [[ "$info" == *ELF* ]] || continue
    if readelf -h "$candidate" 2>/dev/null | grep -Fq "$TARGET_MACHINE"; then
      "$TARGET_STRIP" --strip-debug "$candidate"
    else
      strip --strip-debug "$candidate"
    fi
  done < <(find "$root" -type f -print)
}

finalize_file_lists() {
  local root=$1
  local name=$2
  local tree_file="$DIST_DIR/$name.tree.txt"
  local list_file="$DIST_DIR/$name.filelist.txt"

  (
    cd "$root"
    tree -a -I 'TREE.txt|FILELIST.txt' .
  ) > "$tree_file"
  cp "$tree_file" "$root/TREE.txt"

  (
    cd "$root"
    find . -printf '%M %12s %p -> %l\n' | LC_ALL=C sort
  ) > "$list_file"
  cp "$list_file" "$root/FILELIST.txt"
}

make_musl_loader_relocatable "$DEBUG_ROOT"
make_musl_loader_relocatable "$NODEBUG_ROOT"
copy_licenses "$DEBUG_ROOT"
copy_licenses "$NODEBUG_ROOT"
write_metadata "$DEBUG_ROOT" debug
strip_nodebug_tree "$NODEBUG_ROOT"
write_metadata "$NODEBUG_ROOT" nodebug

TARGET_TRIPLET="$TARGET_TRIPLET" QEMU_RUNNER="$QEMU_RUNNER" \
  bash "$SCRIPT_DIR/test-musl-toolchain.sh" "$DEBUG_ROOT" debug
TARGET_TRIPLET="$TARGET_TRIPLET" QEMU_RUNNER="$QEMU_RUNNER" \
  bash "$SCRIPT_DIR/test-musl-toolchain.sh" "$NODEBUG_ROOT" nodebug

finalize_file_lists "$DEBUG_ROOT" "$DEBUG_NAME"
finalize_file_lists "$NODEBUG_ROOT" "$NODEBUG_NAME"

DEBUG_PACKAGE="$DIST_DIR/$DEBUG_NAME.tar.gz"
NODEBUG_PACKAGE="$DIST_DIR/$NODEBUG_NAME.tar.gz"
rm -f "$DEBUG_PACKAGE" "$NODEBUG_PACKAGE"
tar -I 'gzip -1' -cf "$DEBUG_PACKAGE" -C "$PACKAGE_WORK_ROOT" "$DEBUG_NAME"
tar -I 'gzip -1' -cf "$NODEBUG_PACKAGE" -C "$PACKAGE_WORK_ROOT" "$NODEBUG_NAME"
sha256sum "$DEBUG_PACKAGE" > "$DEBUG_PACKAGE.sha256"
sha256sum "$NODEBUG_PACKAGE" > "$NODEBUG_PACKAGE.sha256"

write_output debug_package "$DEBUG_PACKAGE"
write_output nodebug_package "$NODEBUG_PACKAGE"
write_output debug_tree "$DIST_DIR/$DEBUG_NAME.tree.txt"
write_output nodebug_tree "$DIST_DIR/$NODEBUG_NAME.tree.txt"
write_output debug_filelist "$DIST_DIR/$DEBUG_NAME.filelist.txt"
write_output nodebug_filelist "$DIST_DIR/$NODEBUG_NAME.filelist.txt"

echo "packaged $TARGET_TRIPLET debug and nodebug toolchains"
