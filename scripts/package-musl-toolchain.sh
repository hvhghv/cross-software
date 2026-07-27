#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=musl-toolchain-common.sh
source "$SCRIPT_DIR/musl-toolchain-common.sh"

TARGET_TRIPLET=${TARGET_TRIPLET:?TARGET_TRIPLET is required}
INSTALL_PREFIX=${INSTALL_PREFIX:?INSTALL_PREFIX is required}
TOOLCHAIN_FLAVOR=${TOOLCHAIN_FLAVOR:-nolto}
QEMU_RUNNER=${QEMU_RUNNER:-}
DIST_DIR=${DIST_DIR:-"$REPO_ROOT/dist/musl-toolchain"}

validate_target "$TARGET_TRIPLET"
[[ "$TOOLCHAIN_FLAVOR" == nolto || "$TOOLCHAIN_FLAVOR" == lto ]] \
  || die "unsupported toolchain flavor: $TOOLCHAIN_FLAVOR"
for command in file find gzip readelf readlink sha256sum strip tar tree; do
  require_command "$command"
done

ARCH=$(target_asset_arch "$TARGET_TRIPLET")
TARGET_MACHINE=$(target_machine_pattern "$TARGET_TRIPLET")
MCM_ROOT=$(stage_mcm_root "$TARGET_TRIPLET")
PACKAGE_WORK_ROOT="$REPO_ROOT/build/musl-toolchain-packages/$TARGET_TRIPLET-$TOOLCHAIN_FLAVOR"
TARGET_STRIP="$INSTALL_PREFIX/bin/$TARGET_TRIPLET-strip"

[[ -d "$INSTALL_PREFIX" ]] || die "install prefix not found: $INSTALL_PREFIX"
[[ -x "$TARGET_STRIP" ]] || die "target strip not found: $TARGET_STRIP"
case "$PACKAGE_WORK_ROOT" in
  "$REPO_ROOT"/build/*) ;;
  *) die "refusing to modify unexpected package path: $PACKAGE_WORK_ROOT" ;;
esac

rm -rf "$PACKAGE_WORK_ROOT"
mkdir -p "$PACKAGE_WORK_ROOT" "$DIST_DIR"

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
  local lto_status
  local debug_flags
  local build_cflags

  if [[ "$TOOLCHAIN_FLAVOR" == lto ]]; then
    lto_status=enabled
    debug_flags=none
    build_cflags=-O2
  else
    lto_status=disabled
    debug_flags=-g
    build_cflags='-O2 -g -fno-lto'
  fi

  cat > "$root/BUILDINFO.txt" <<EOF
target=$TARGET_TRIPLET
variant=$variant
release_id=$TOOLCHAIN_RELEASE_ID
musl_cross_make_commit=$MUSL_CROSS_MAKE_COMMIT
optimization=-O2
debug_flags=$debug_flags
lto=$lto_status
build_cflags=$build_cflags
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
lto=$lto_status
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
  local tree_file="$PACKAGE_WORK_ROOT/.$name.tree.tmp"
  local list_file="$PACKAGE_WORK_ROOT/.$name.filelist.tmp"
  local release_tree="$DIST_DIR/$name.release-tree.md"

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
  rm -f "$tree_file" "$list_file"

  {
    printf '<details>\n<summary><code>%s</code></summary>\n\n' "$name"
    printf '```text\n'
    (
      cd "$PACKAGE_WORK_ROOT"
      tree -a -L 3 "$name"
    )
    printf '```\n\n</details>\n\n'
  } > "$release_tree"
}

package_toolchain() {
  local name=$1
  local variant=$2
  local strip_debug=$3
  local root="$PACKAGE_WORK_ROOT/$name"
  local package="$DIST_DIR/$name.tar.gz"

  mkdir -p "$root"
  cp -a "$INSTALL_PREFIX/." "$root/"
  make_musl_loader_relocatable "$root"
  copy_licenses "$root"
  if [[ "$strip_debug" == yes ]]; then
    strip_nodebug_tree "$root"
  fi
  write_metadata "$root" "$variant"

  TARGET_TRIPLET="$TARGET_TRIPLET" QEMU_RUNNER="$QEMU_RUNNER" \
    bash "$SCRIPT_DIR/test-musl-toolchain.sh" "$root" "$variant"

  finalize_file_lists "$root" "$name"
  rm -f "$package" "$package.sha256"
  tar -I 'gzip -1' -cf "$package" -C "$PACKAGE_WORK_ROOT" "$name"
  (
    cd "$DIST_DIR"
    sha256sum "$(basename "$package")"
  ) > "$package.sha256"

  PACKAGE_RESULT=$package
}

if [[ "$TOOLCHAIN_FLAVOR" == nolto ]]; then
  DEBUG_NAME="musl-toolchain-$ARCH-debug"
  NODEBUG_NAME="musl-toolchain-$ARCH-nodebug"
  package_toolchain "$DEBUG_NAME" debug no
  DEBUG_PACKAGE=$PACKAGE_RESULT
  package_toolchain "$NODEBUG_NAME" nodebug yes
  NODEBUG_PACKAGE=$PACKAGE_RESULT

  write_output debug_package "$DEBUG_PACKAGE"
  write_output nodebug_package "$NODEBUG_PACKAGE"
  write_output debug_tree "$DIST_DIR/$DEBUG_NAME.release-tree.md"
  write_output nodebug_tree "$DIST_DIR/$NODEBUG_NAME.release-tree.md"
  echo "packaged $TARGET_TRIPLET debug and nodebug toolchains"
else
  LTO_NODEBUG_NAME="musl-toolchain-$ARCH-lto-nodebug"
  package_toolchain "$LTO_NODEBUG_NAME" lto-nodebug yes
  LTO_NODEBUG_PACKAGE=$PACKAGE_RESULT

  write_output lto_nodebug_package "$LTO_NODEBUG_PACKAGE"
  write_output lto_nodebug_tree "$DIST_DIR/$LTO_NODEBUG_NAME.release-tree.md"
  echo "packaged $TARGET_TRIPLET LTO nodebug toolchain"
fi
