#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=musl-toolchain-common.sh
source "$SCRIPT_DIR/musl-toolchain-common.sh"

TOOLCHAIN_ROOT=${1:?toolchain root argument is required}
PACKAGE_VARIANT=${2:?package variant argument is required}
TARGET_TRIPLET=${TARGET_TRIPLET:?TARGET_TRIPLET is required}
QEMU_RUNNER=${QEMU_RUNNER:-}

validate_target "$TARGET_TRIPLET"
[[ "$PACKAGE_VARIANT" == debug || "$PACKAGE_VARIANT" == nodebug ]] \
  || die "unsupported package variant: $PACKAGE_VARIANT"

for command in file readelf strings; do
  require_command "$command"
done
if [[ -n "$QEMU_RUNNER" ]]; then
  require_command "$QEMU_RUNNER"
fi

TOOLCHAIN_ROOT=$(realpath "$TOOLCHAIN_ROOT")
CC="$TOOLCHAIN_ROOT/bin/$TARGET_TRIPLET-gcc"
CXX="$TOOLCHAIN_ROOT/bin/$TARGET_TRIPLET-g++"
LD="$TOOLCHAIN_ROOT/bin/$TARGET_TRIPLET-ld"
[[ -x "$CC" ]] || die "compiler not found: $CC"
[[ -x "$CXX" ]] || die "C++ compiler not found: $CXX"
[[ -x "$LD" ]] || die "linker not found: $LD"

SYSROOT=$($CC -print-sysroot)
SYSROOT=$(realpath "$SYSROOT")
case "$SYSROOT" in
  "$TOOLCHAIN_ROOT"/*) ;;
  *) die "compiler sysroot is not relocatable inside package: $SYSROOT" ;;
esac

[[ "$($CC -dumpfullversion)" == "$GCC_VERSION" ]] || die "unexpected GCC version"
CC_VERBOSE=$($CC -v 2>&1)
grep -F -- '--disable-lto' <<< "$CC_VERBOSE" >/dev/null \
  || die "GCC was not configured with --disable-lto"
$LD --version | head -n 1 | grep -q "$BINUTILS_VERSION" || die "unexpected binutils version"
grep -q '^#define LINUX_VERSION_CODE 329733$' "$SYSROOT/include/linux/version.h" \
  || die "Linux headers are not version 5.8.5"
strings "$SYSROOT/lib/libc.so" | grep -F "$MUSL_VERSION" >/dev/null \
  || die "unexpected musl version"

for header in \
  linux/capability.h \
  linux/fs.h \
  linux/kd.h \
  linux/netlink.h \
  linux/version.h \
  linux/vt.h \
  scsi/sg.h
do
  [[ -f "$SYSROOT/include/$header" ]] || die "missing target header: $header"
done

if find "$TOOLCHAIN_ROOT" -type f -name lto1 -print -quit | grep -q .
then
  die "LTO compiler front end found in LTO-disabled toolchain"
fi

TEST_ROOT="$REPO_ROOT/build/musl-toolchain-tests/$TARGET_TRIPLET-$PACKAGE_VARIANT"
rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT"

cat > "$TEST_ROOT/hello.c" <<'EOF'
#include <stdio.h>

int main(void) {
    puts("MUSL_TOOLCHAIN_C_OK");
    return 0;
}
EOF

cat > "$TEST_ROOT/hello.cpp" <<'EOF'
#include <iostream>

int main() {
    std::cout << "MUSL_TOOLCHAIN_CXX_OK" << std::endl;
    return 0;
}
EOF

cat > "$TEST_ROOT/headers.c" <<'EOF'
#include <linux/capability.h>
#include <linux/fs.h>
#include <linux/kd.h>
#include <linux/netlink.h>
#include <linux/version.h>
#include <linux/vt.h>
#include <scsi/sg.h>

int main(void) {
    return LINUX_VERSION_CODE == KERNEL_VERSION(5, 8, 5) ? 0 : 1;
}
EOF

if "$CC" -flto -c "$TEST_ROOT/hello.c" -o "$TEST_ROOT/lto.o" \
  >"$TEST_ROOT/lto.out" 2>"$TEST_ROOT/lto.err"
then
  die "compiler accepted -flto even though LTO must be disabled"
fi

"$CC" -O2 -fno-lto -c "$TEST_ROOT/headers.c" -o "$TEST_ROOT/headers.o"

read_interpreter() {
  readelf -l "$1" \
    | sed -n 's|.*program interpreter: \([^]]*\)\].*|\1|p'
}

run_target() {
  local linkage=$1
  local binary=$2
  local marker=$3
  local output

  if [[ -n "$QEMU_RUNNER" ]]; then
    if [[ "$linkage" == dynamic ]]; then
      output=$($QEMU_RUNNER -L "$SYSROOT" "$binary")
    else
      output=$($QEMU_RUNNER "$binary")
    fi
  elif [[ "$linkage" == dynamic ]]; then
    local interp
    interp=$(read_interpreter "$binary")
    [[ -n "$interp" && -x "$SYSROOT$interp" ]] || die "dynamic loader not found for $binary"
    output=$("$SYSROOT$interp" \
      --library-path "$SYSROOT/lib:$SYSROOT/usr/lib" \
      "$binary")
  else
    output=$("$binary")
  fi

  grep -Fq "$marker" <<< "$output" || die "runtime marker missing for $binary"
}

for linkage in dynamic static; do
  link_flags=()
  if [[ "$linkage" == static ]]; then
    link_flags=(-static)
  fi

  c_binary="$TEST_ROOT/hello-c-$linkage"
  cxx_binary="$TEST_ROOT/hello-cxx-$linkage"
  "$CC" -O2 -fno-lto "${link_flags[@]}" "$TEST_ROOT/hello.c" -o "$c_binary"
  "$CXX" -O2 -fno-lto "${link_flags[@]}" "$TEST_ROOT/hello.cpp" -o "$cxx_binary"

  if [[ "$linkage" == static ]]; then
    [[ -z "$(read_interpreter "$c_binary")" ]] || die "static C binary has an interpreter"
    [[ -z "$(read_interpreter "$cxx_binary")" ]] || die "static C++ binary has an interpreter"
  else
    [[ -n "$(read_interpreter "$c_binary")" ]] || die "dynamic C binary has no interpreter"
    [[ -n "$(read_interpreter "$cxx_binary")" ]] || die "dynamic C++ binary has no interpreter"
  fi

  run_target "$linkage" "$c_binary" MUSL_TOOLCHAIN_C_OK
  run_target "$linkage" "$cxx_binary" MUSL_TOOLCHAIN_CXX_OK
done

has_debug_sections() {
  readelf -S "$1" 2>/dev/null | grep '\.debug_' >/dev/null
}

if [[ "$PACKAGE_VARIANT" == debug ]]; then
  debug_found=0
  for candidate in \
    "$CC" \
    "$(find "$TOOLCHAIN_ROOT/libexec" -type f -name cc1 -print -quit 2>/dev/null || true)" \
    "$SYSROOT/lib/libc.so"
  do
    [[ -n "$candidate" && -f "$candidate" ]] || continue
    if has_debug_sections "$candidate"; then
      debug_found=1
      break
    fi
  done
  [[ "$debug_found" == 1 ]] || die "debug package does not contain debug sections"
else
  while IFS= read -r candidate; do
    if file -b "$candidate" | grep ELF >/dev/null && has_debug_sections "$candidate"; then
      die "nodebug package still contains debug sections: $candidate"
    fi
    case "$candidate" in
      *.a|*.o)
        if has_debug_sections "$candidate"; then
          die "nodebug archive/object still contains debug sections: $candidate"
        fi
        ;;
    esac
  done < <(find "$TOOLCHAIN_ROOT" -type f -print)
fi

echo "validated $TARGET_TRIPLET $PACKAGE_VARIANT toolchain"
