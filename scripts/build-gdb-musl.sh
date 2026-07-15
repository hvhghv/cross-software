#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

resolve_tool() {
  local tool=$1
  if [[ "$tool" == */* ]]; then
    [[ -x "$tool" ]] || die "tool is not executable: $tool"
    printf '%s\n' "$tool"
    return
  fi

  command -v "$tool" || die "tool not found in PATH: $tool"
}

write_output() {
  local key=$1
  local value=$2
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

SOFTWARE_NAME=${SOFTWARE_NAME:-gdb}
GDB_VERSION=${GDB_VERSION:-15.1}
TARGET_TRIPLET=${TARGET_TRIPLET:?TARGET_TRIPLET is required}
TARGET_ARCH=${TARGET_ARCH:-$TARGET_TRIPLET}
LINKAGE=${LINKAGE:-static}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}

case "$LINKAGE" in
  static|dynamic) ;;
  *) die "LINKAGE must be static or dynamic, got: $LINKAGE" ;;
esac

ARCHIVE_DIR=${ARCHIVE_DIR:-"$REPO_ROOT/archive"}
BUILD_ROOT=${BUILD_ROOT:-"$REPO_ROOT/build/$SOFTWARE_NAME-$GDB_VERSION-$TARGET_TRIPLET-$LINKAGE"}
SRC_ROOT="$BUILD_ROOT/src"
BUILD_DIR="$BUILD_ROOT/build"
DEPS_PREFIX=${DEPS_PREFIX:-"$BUILD_ROOT/deps"}
INSTALL_PREFIX="$BUILD_ROOT/install"

GDB_ARCHIVE="$ARCHIVE_DIR/gdb-$GDB_VERSION.tar.gz"
GMP_ARCHIVE="$ARCHIVE_DIR/gmp-6.3.0.tar.xz"
MPFR_ARCHIVE="$ARCHIVE_DIR/mpfr-4.2.2.tar.xz"

[[ -f "$GDB_ARCHIVE" ]] || die "missing GDB archive: $GDB_ARCHIVE"
[[ -f "$GMP_ARCHIVE" ]] || die "missing GMP archive: $GMP_ARCHIVE"
[[ -f "$MPFR_ARCHIVE" ]] || die "missing MPFR archive: $MPFR_ARCHIVE"

if command -v sha256sum >/dev/null 2>&1 && [[ -f "$ARCHIVE_DIR/SHA256SUMS" ]]; then
  (cd "$REPO_ROOT" && sha256sum --ignore-missing -c archive/SHA256SUMS)
fi

rm -rf "$BUILD_ROOT"
mkdir -p "$SRC_ROOT" "$BUILD_DIR" "$DEPS_PREFIX" "$INSTALL_PREFIX"

tar -xf "$GDB_ARCHIVE" -C "$SRC_ROOT"
tar -xf "$GMP_ARCHIVE" -C "$SRC_ROOT"
tar -xf "$MPFR_ARCHIVE" -C "$SRC_ROOT"

GDB_SRC="$SRC_ROOT/gdb-$GDB_VERSION"
GMP_SRC="$SRC_ROOT/gmp-6.3.0"
MPFR_SRC="$SRC_ROOT/mpfr-4.2.2"

[[ -d "$GDB_SRC" ]] || die "extracted GDB source not found: $GDB_SRC"
[[ -d "$GMP_SRC" ]] || die "extracted GMP source not found: $GMP_SRC"
[[ -d "$MPFR_SRC" ]] || die "extracted MPFR source not found: $MPFR_SRC"

patch_aarch64_musl_ptrace_headers() {
  [[ "$TARGET_TRIPLET" == aarch64*-linux-musl* ]] || return 0

  local compat_header="$GDB_SRC/gdb/nat/aarch64-musl-ptrace.h"
  cat > "$compat_header" <<'EOF'
#ifndef NAT_AARCH64_MUSL_PTRACE_H
#define NAT_AARCH64_MUSL_PTRACE_H

#if defined(__linux__) && !defined(__GLIBC__)
# include <signal.h>
# ifndef _UAPI__ASM_SIGCONTEXT_H
#  define _UAPI__ASM_SIGCONTEXT_H 1
# endif
# ifndef __ASM_SIGCONTEXT_H
#  define __ASM_SIGCONTEXT_H 1
# endif
#endif

#include <asm/ptrace.h>

#endif /* NAT_AARCH64_MUSL_PTRACE_H */
EOF

  replace_ptrace_include() {
    local file=$1
    local replacement=$2
    [[ -f "$file" ]] || die "missing source file for aarch64 musl patch: $file"
    if ! grep -qF '#include <asm/ptrace.h>' "$file"; then
      die "expected ptrace include not found while patching: $file"
    fi
    sed -i "s|#include <asm/ptrace.h>|$replacement|" "$file"
  }

  replace_ptrace_include "$GDB_SRC/gdb/aarch64-linux-nat.c" '#include "nat/aarch64-musl-ptrace.h"'
  replace_ptrace_include "$GDB_SRC/gdb/nat/aarch64-linux.c" '#include "aarch64-musl-ptrace.h"'
  replace_ptrace_include "$GDB_SRC/gdb/nat/aarch64-linux-hw-point.c" '#include "aarch64-musl-ptrace.h"'
  replace_ptrace_include "$GDB_SRC/gdb/nat/aarch64-scalable-linux-ptrace.h" '#include "aarch64-musl-ptrace.h"'
  replace_ptrace_include "$GDB_SRC/gdbserver/linux-aarch64-low.cc" '#include "nat/aarch64-musl-ptrace.h"'

  echo "patched aarch64 musl ptrace headers"
}

patch_aarch64_musl_ptrace_headers

CC=$(resolve_tool "${MUSL_CC:-$TARGET_TRIPLET-gcc}")
CXX=$(resolve_tool "${MUSL_CXX:-$TARGET_TRIPLET-g++}")
AR=$(resolve_tool "${MUSL_AR:-$TARGET_TRIPLET-ar}")
RANLIB=$(resolve_tool "${MUSL_RANLIB:-$TARGET_TRIPLET-ranlib}")
STRIP=$(resolve_tool "${MUSL_STRIP:-$TARGET_TRIPLET-strip}")

export CC CXX AR RANLIB
export CC_FOR_BUILD=${CC_FOR_BUILD:-gcc}
export CXX_FOR_BUILD=${CXX_FOR_BUILD:-g++}

BUILD_TRIPLET=${BUILD_TRIPLET:-$(sh "$GDB_SRC/config.guess")}
COMMON_CFLAGS=${COMMON_CFLAGS:--Os -pipe}
COMMON_CXXFLAGS=${COMMON_CXXFLAGS:--Os -pipe}
GDB_CFLAGS=${GDB_CFLAGS:-$COMMON_CFLAGS}
GDB_CXXFLAGS=${GDB_CXXFLAGS:-$COMMON_CXXFLAGS}

case "$LINKAGE" in
  static)
    STATIC_LINK_FLAGS=${STATIC_LINK_FLAGS:--static -static-libstdc++ -static-libgcc}
    DEP_LDFLAGS=${DEP_LDFLAGS:--static}
    GDB_LDFLAGS=${GDB_LDFLAGS:-$STATIC_LINK_FLAGS -L"$DEPS_PREFIX/lib"}
    GDB_CXXFLAGS="$GDB_CXXFLAGS $STATIC_LINK_FLAGS"
    ;;
  dynamic)
    DEP_LDFLAGS=${DEP_LDFLAGS:-}
    GDB_LDFLAGS=${GDB_LDFLAGS:--L"$DEPS_PREFIX/lib"}
    ;;
esac

echo "software=$SOFTWARE_NAME"
echo "version=$GDB_VERSION"
echo "target=$TARGET_TRIPLET"
echo "arch=$TARGET_ARCH"
echo "linkage=$LINKAGE"
echo "build=$BUILD_TRIPLET"
echo "cc=$CC"
echo "cxx=$CXX"
echo "jobs=$JOBS"
echo "deps_prefix=$DEPS_PREFIX"
echo "gdb_cxxflags=$GDB_CXXFLAGS"
echo "gdb_ldflags=$GDB_LDFLAGS"

have_cached_gmp() {
  [[ -f "$DEPS_PREFIX/include/gmp.h" && -f "$DEPS_PREFIX/lib/libgmp.a" ]]
}

have_cached_mpfr() {
  [[ -f "$DEPS_PREFIX/include/mpfr.h" && -f "$DEPS_PREFIX/lib/libmpfr.a" ]]
}

patch_gdb_static_link_rule() {
  [[ "$LINKAGE" == static ]] || return 0

  local makefile="gdb/Makefile"
  [[ -f "$makefile" ]] || die "generated GDB Makefile not found: $makefile"
  if ! grep -q '^CC_LD = .*\$(LIBTOOL)' "$makefile"; then
    die "expected libtool CC_LD rule not found in $makefile"
  fi

  sed -i 's|^CC_LD = .*|CC_LD = $(LIBTOOL) $(SILENT_FLAG) --mode=link $(CXX) $(CXX_DIALECT) -all-static|' "$makefile"
  echo "patched GDB static link rule:"
  grep '^CC_LD =' "$makefile"
}

if have_cached_gmp; then
  echo "using cached GMP from $DEPS_PREFIX"
else
  mkdir -p "$BUILD_DIR/gmp"
  (
    cd "$BUILD_DIR/gmp"
    CFLAGS="$COMMON_CFLAGS" \
    LDFLAGS="$DEP_LDFLAGS" \
    "$GMP_SRC/configure" \
      --build="$BUILD_TRIPLET" \
      --host="$TARGET_TRIPLET" \
      --prefix="$DEPS_PREFIX" \
      --disable-shared \
      --enable-static
    make -j "$JOBS"
    make install
  )
fi

if have_cached_mpfr; then
  echo "using cached MPFR from $DEPS_PREFIX"
else
  mkdir -p "$BUILD_DIR/mpfr"
  (
    cd "$BUILD_DIR/mpfr"
    CPPFLAGS="-I$DEPS_PREFIX/include" \
    CFLAGS="$COMMON_CFLAGS" \
    LDFLAGS="-L$DEPS_PREFIX/lib $DEP_LDFLAGS" \
    "$MPFR_SRC/configure" \
      --build="$BUILD_TRIPLET" \
      --host="$TARGET_TRIPLET" \
      --prefix="$DEPS_PREFIX" \
      --with-gmp="$DEPS_PREFIX" \
      --disable-shared \
      --enable-static
    make -j "$JOBS"
    make install
  )
fi

mkdir -p "$BUILD_DIR/gdb"
(
  cd "$BUILD_DIR/gdb"
  CPPFLAGS="-I$DEPS_PREFIX/include" \
  CFLAGS="$GDB_CFLAGS" \
  CXXFLAGS="$GDB_CXXFLAGS" \
  LDFLAGS="$GDB_LDFLAGS" \
  "$GDB_SRC/configure" \
    --build="$BUILD_TRIPLET" \
    --host="$TARGET_TRIPLET" \
    --target="$TARGET_TRIPLET" \
    --prefix="$INSTALL_PREFIX" \
    --with-gmp="$DEPS_PREFIX" \
    --with-mpfr="$DEPS_PREFIX" \
    --without-system-readline \
    --without-system-zlib \
    --without-python \
    --without-guile \
    --without-debuginfod \
    --without-lzma \
    --without-babeltrace \
    --without-curses \
    --without-expat \
    --disable-source-highlight \
    --disable-tui \
    --disable-gdbtk \
    --disable-nls \
    --disable-werror \
    --disable-sim \
    --disable-binutils \
    --disable-ld \
    --disable-gas \
    --disable-gprof \
    --enable-gdbserver \
    --disable-shared \
    --enable-static

  if [[ "$LINKAGE" == static ]]; then
    make configure-gdb
    patch_gdb_static_link_rule
  fi
  make -j "$JOBS" all-gdb all-gdbserver
  make install-gdb install-gdbserver
)

[[ -x "$INSTALL_PREFIX/bin/gdb" ]] || die "gdb was not installed"
[[ -x "$INSTALL_PREFIX/bin/gdbserver" ]] || die "gdbserver was not installed"

if [[ "${STRIP_BINARIES:-1}" == "1" ]]; then
  "$STRIP" "$INSTALL_PREFIX/bin/gdb" "$INSTALL_PREFIX/bin/gdbserver" || true
fi

cat > "$INSTALL_PREFIX/BUILD_INFO.txt" <<EOF
software=$SOFTWARE_NAME
version=$GDB_VERSION
target=$TARGET_TRIPLET
arch=$TARGET_ARCH
linkage=$LINKAGE
build=$BUILD_TRIPLET
gmp=6.3.0
mpfr=4.2.2
EOF

write_output install_prefix "$INSTALL_PREFIX"
write_output gdb_bin "$INSTALL_PREFIX/bin/gdb"
write_output gdbserver_bin "$INSTALL_PREFIX/bin/gdbserver"

echo "installed to $INSTALL_PREFIX"
