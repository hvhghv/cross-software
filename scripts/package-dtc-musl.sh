#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

write_output() {
  local key=$1
  local value=$2
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

TARGET=${TARGET:-x86_64-linux-musl}
LINK_TYPE=${LINK_TYPE:-static}
DTC_VERSION=${DTC_VERSION:-1.7.2}

BUILD_BASE="$REPO_ROOT/build/dtc-${DTC_VERSION}-${TARGET}-musl-${LINK_TYPE}"
INSTALL_DIR="$BUILD_BASE/install"
PACKAGE_DIR="$BUILD_BASE/package"

[[ -d "$INSTALL_DIR" ]] || die "install directory not found: $INSTALL_DIR"

echo "Creating package structure..."
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"

mkdir -p "$PACKAGE_DIR/usr/bin"
mkdir -p "$PACKAGE_DIR/usr/lib"
mkdir -p "$PACKAGE_DIR/usr/include"

echo "Copying binaries..."
cp -a "$INSTALL_DIR"/usr/bin/* "$PACKAGE_DIR/usr/bin/" 2>/dev/null || true

if [[ "$LINK_TYPE" == "dynamic" ]]; then
  echo "Copying dynamic libraries..."
  cp -a "$INSTALL_DIR"/usr/lib/libfdt*.so* "$PACKAGE_DIR/usr/lib/" 2>/dev/null || true
fi

echo "Copying static library and headers..."
cp -a "$INSTALL_DIR"/usr/lib/libfdt.a "$PACKAGE_DIR/usr/lib/" 2>/dev/null || true
cp -a "$INSTALL_DIR"/usr/include/libfdt*.h "$PACKAGE_DIR/usr/include/" 2>/dev/null || true
cp -a "$INSTALL_DIR"/usr/include/fdt.h "$PACKAGE_DIR/usr/include/" 2>/dev/null || true

echo "Generating build info..."
cat > "$PACKAGE_DIR/BUILD_INFO.txt" <<EOF
DTC Version: ${DTC_VERSION}
Target: ${TARGET}
Link Type: ${LINK_TYPE}
Build Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Toolchain: musl-gcc
EOF

cd "$PACKAGE_DIR"

echo "Generating file list..."
find . -type f -o -type l | sort > FILELIST.txt

echo "Generating directory tree..."
if command -v tree >/dev/null 2>&1; then
  tree -a -L 3 > TREE.txt
else
  find . -print | sed -e 's;[^/]*/;|____;g;s;____|; |;g' > TREE.txt
fi

ARCHIVE_NAME="dtc-${DTC_VERSION}-${TARGET}-${LINK_TYPE}.tar.gz"
ARCHIVE_PATH="$REPO_ROOT/$ARCHIVE_NAME"

echo "Creating archive: ${ARCHIVE_NAME}..."
tar czf "$ARCHIVE_PATH" -C "$PACKAGE_DIR" .

ARCHIVE_SIZE=$(du -h "$ARCHIVE_PATH" | cut -f1)
echo "Package created: ${ARCHIVE_NAME} (${ARCHIVE_SIZE})"

write_output "archive_name" "$ARCHIVE_NAME"
write_output "archive_path" "$ARCHIVE_PATH"
write_output "archive_size" "$ARCHIVE_SIZE"
