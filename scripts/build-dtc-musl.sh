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

validate_target() {
  case "$1" in
    x86_64-linux-musl|arm-linux-musleabi|aarch64-linux-musl|riscv64-linux-musl)
      ;;
    *)
      die "unsupported musl target: $1"
      ;;
  esac
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

TARGET=${TARGET:-x86_64-linux-musl}
LINK_TYPE=${LINK_TYPE:-static}
DTC_VERSION=${DTC_VERSION:-1.7.2}

validate_target "$TARGET"

case "$LINK_TYPE" in
  static|dynamic)
    ;;
  *)
    die "LINK_TYPE must be 'static' or 'dynamic', got: $LINK_TYPE"
    ;;
esac

TOOLCHAIN_ROOT="${TOOLCHAIN_ROOT:-/opt/musl-toolchain}"
[[ -d "$TOOLCHAIN_ROOT" ]] || die "toolchain not found at: $TOOLCHAIN_ROOT"

export PATH="$TOOLCHAIN_ROOT/bin:$PATH"
export CC="${TARGET}-gcc"
export AR="${TARGET}-ar"
export RANLIB="${TARGET}-ranlib"

CC=$(resolve_tool "$CC")
AR=$(resolve_tool "$AR")
RANLIB=$(resolve_tool "$RANLIB")

BUILD_BASE="$REPO_ROOT/build/dtc-${DTC_VERSION}-${TARGET}-musl-${LINK_TYPE}"
SRC_DIR="$BUILD_BASE/src/dtc-${DTC_VERSION}"
INSTALL_DIR="$BUILD_BASE/install"

mkdir -p "$BUILD_BASE" "$INSTALL_DIR"
mkdir -p "$BUILD_BASE/src"

cd "$BUILD_BASE"

DTC_ARCHIVE="$REPO_ROOT/archive/dtc-${DTC_VERSION}.tar.gz"
[[ -f "$DTC_ARCHIVE" ]] || die "source archive not found: $DTC_ARCHIVE"

if [[ ! -d "$SRC_DIR" ]]; then
  echo "Extracting dtc ${DTC_VERSION}..."
  tar xf "$DTC_ARCHIVE" -C "$BUILD_BASE/src"
fi

cd "$SRC_DIR"

if [[ "$LINK_TYPE" == "static" ]]; then
  export CFLAGS="-static -Os -ffunction-sections -fdata-sections"
  export LDFLAGS="-static -Wl,--gc-sections"
else
  export CFLAGS="-Os -ffunction-sections -fdata-sections"
  export LDFLAGS="-Wl,--gc-sections"
fi

echo "Building dtc ${DTC_VERSION} for ${TARGET} (${LINK_TYPE})..."

make clean || true

if [[ "$LINK_TYPE" == "static" ]]; then
  # For static builds: patch Makefile to only build static library
  echo "Patching Makefile for static-only build..."
  sed -i.bak \
    -e 's/^LIBFDT_lib =.*/LIBFDT_lib = libfdt\/libfdt.a/' \
    -e 's/SHAREDLIB_LINK_OPTIONS =.*/SHAREDLIB_LINK_OPTIONS =/' \
    -e 's/\.so\.$(LIBFDT_VERSION)/\.a/g' \
    libfdt/Makefile || true
fi

make -j"$(nproc)" \
  CC="$CC" \
  AR="$AR" \
  RANLIB="$RANLIB" \
  PREFIX=/usr \
  NO_PYTHON=1 \
  NO_YAML=1 \
  V=1

echo "Installing dtc to ${INSTALL_DIR}..."

make install \
  PREFIX=/usr \
  DESTDIR="$INSTALL_DIR" \
  NO_PYTHON=1 \
  V=1

echo "Stripping binaries..."
"${TARGET}-strip" "$INSTALL_DIR"/usr/bin/* 2>/dev/null || true

echo "DTC ${DTC_VERSION} built successfully for ${TARGET} (${LINK_TYPE})"
echo "Install directory: ${INSTALL_DIR}"

write_output "install_dir" "$INSTALL_DIR"
write_output "dtc_version" "$DTC_VERSION"
write_output "target" "$TARGET"
write_output "link_type" "$LINK_TYPE"
