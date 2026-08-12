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
  else
    command -v "$tool" || die "tool not found in PATH: $tool"
  fi
}

write_output() {
  local key=$1
  local value=$2
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

SOFTWARE_NAME=${SOFTWARE_NAME:-bash}
BASH_SOURCE_VERSION=${BASH_SOURCE_VERSION:-5.3}
BASH_PATCH_LEVEL=${BASH_PATCH_LEVEL:-15}
TARGET_TRIPLET=${TARGET_TRIPLET:?TARGET_TRIPLET is required}
TARGET_ARCH=${TARGET_ARCH:-$TARGET_TRIPLET}
LINKAGE=${LINKAGE:-static}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}
ARCHIVE_DIR=${ARCHIVE_DIR:-"$REPO_ROOT/archive"}
PATCH_DIR=${PATCH_DIR:-"$REPO_ROOT/patches/bash-$BASH_SOURCE_VERSION"}
BUILD_ROOT=${BUILD_ROOT:-"$REPO_ROOT/build/$SOFTWARE_NAME-$BASH_SOURCE_VERSION-$TARGET_TRIPLET-$LINKAGE"}
SRC_ROOT="$BUILD_ROOT/src"
INSTALL_PREFIX="$BUILD_ROOT/install"

case "$LINKAGE" in
  static|dynamic) ;;
  *) die "LINKAGE must be static or dynamic, got: $LINKAGE" ;;
esac

BASH_ARCHIVE="$ARCHIVE_DIR/bash-$BASH_SOURCE_VERSION.tar.gz"
[[ -f "$BASH_ARCHIVE" ]] || die "missing Bash archive: $BASH_ARCHIVE"
[[ -d "$PATCH_DIR" ]] || die "missing Bash patch directory: $PATCH_DIR"

patch_count=0
for patch_file in "$PATCH_DIR"/bash53-*; do
  [[ -f "$patch_file" ]] || continue
  patch_count=$((patch_count + 1))
done
[[ "$patch_count" == "$BASH_PATCH_LEVEL" ]] \
  || die "expected $BASH_PATCH_LEVEL Bash patches, found $patch_count"

if command -v sha256sum >/dev/null 2>&1 && [[ -f "$ARCHIVE_DIR/SHA256SUMS" ]]; then
  (cd "$REPO_ROOT" && sha256sum --ignore-missing -c archive/SHA256SUMS)
fi

CC=$(resolve_tool "${MUSL_CC:-$TARGET_TRIPLET-gcc}")
AR=$(resolve_tool "${MUSL_AR:-$TARGET_TRIPLET-ar}")
RANLIB=$(resolve_tool "${MUSL_RANLIB:-$TARGET_TRIPLET-ranlib}")
STRIP=$(resolve_tool "${MUSL_STRIP:-$TARGET_TRIPLET-strip}")

rm -rf "$BUILD_ROOT"
mkdir -p "$SRC_ROOT" "$INSTALL_PREFIX/bin"
tar -xf "$BASH_ARCHIVE" -C "$SRC_ROOT"
mv "$SRC_ROOT/bash-$BASH_SOURCE_VERSION" "$SRC_ROOT/bash-$BASH_SOURCE_VERSION-patched"
BASH_SRC="$SRC_ROOT/bash-$BASH_SOURCE_VERSION-patched"

for patch_file in "$PATCH_DIR"/bash53-*; do
  [[ -f "$patch_file" ]] || continue
  (
    cd "$BASH_SRC"
    patch -p0 < "$patch_file"
  )
done

BUILD_TRIPLET=${BUILD_TRIPLET:-$(sh "$BASH_SRC/support/config.guess")}
COMMON_CFLAGS=${COMMON_CFLAGS:--Os -pipe -ffunction-sections -fdata-sections}
FINAL_LDFLAGS=${FINAL_LDFLAGS:--Wl,--gc-sections}
CONFIGURE_FLAGS=(
  --build="$BUILD_TRIPLET"
  --host="$TARGET_TRIPLET"
  --prefix=/usr
  --bindir=/bin
  --disable-nls
  --enable-readline
  --enable-history
  --enable-directory-stack
  --enable-help-builtin
  --enable-net-redirections
  --enable-process-substitution
  --enable-progcomp
  --enable-job-control
  --enable-brace-expansion
  --enable-alias
  --enable-array-variables
  --enable-cond-command
  --enable-cond-regexp
  --enable-coprocesses
  --enable-extended-glob
  --enable-select
  --enable-prompt-string-decoding
  --enable-multibyte
  --enable-threads=posix
  --without-bash-malloc
  --without-gnu-malloc
)
if [[ "$LINKAGE" == static ]]; then
  CONFIGURE_FLAGS+=(--enable-static-link)
  FINAL_LDFLAGS="-static $FINAL_LDFLAGS"
fi

(
  cd "$BASH_SRC"
  CC="$CC" AR="$AR" RANLIB="$RANLIB" \
    CFLAGS="$COMMON_CFLAGS" LDFLAGS="$FINAL_LDFLAGS" \
    ./configure "${CONFIGURE_FLAGS[@]}"
  make -j "$JOBS"
)

cp "$BASH_SRC/bash" "$INSTALL_PREFIX/bin/bash"
[[ -x "$INSTALL_PREFIX/bin/bash" ]] || die "Bash was not installed"
"$STRIP" "$INSTALL_PREFIX/bin/bash" || true

cat > "$INSTALL_PREFIX/BUILD_INFO.txt" <<EOF
software=$SOFTWARE_NAME
version=$BASH_SOURCE_VERSION
patch_level=$BASH_PATCH_LEVEL
target=$TARGET_TRIPLET
arch=$TARGET_ARCH
linkage=$LINKAGE
readline=builtin
history=enabled
nls=disabled
directory_stack=enabled
process_substitution=enabled
net_redirections=enabled
programmable_completion=enabled
busybox_runtime_dependency=none
EOF

write_output bash_bin "$INSTALL_PREFIX/bin/bash"
write_output install_prefix "$INSTALL_PREFIX"

echo "installed Bash to $INSTALL_PREFIX"
