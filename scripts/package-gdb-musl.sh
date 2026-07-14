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

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

SOFTWARE_NAME=${SOFTWARE_NAME:-gdb}
GDB_VERSION=${GDB_VERSION:-15.1}
TARGET_TRIPLET=${TARGET_TRIPLET:?TARGET_TRIPLET is required}
LINKAGE=${LINKAGE:-static}
INSTALL_PREFIX=${INSTALL_PREFIX:?INSTALL_PREFIX is required}
DIST_DIR=${DIST_DIR:-"$REPO_ROOT/dist"}
PACKAGE_NAME=${PACKAGE_NAME:-"$SOFTWARE_NAME-$GDB_VERSION-$TARGET_TRIPLET-$LINKAGE"}

[[ -d "$INSTALL_PREFIX" ]] || die "install prefix not found: $INSTALL_PREFIX"
[[ -x "$INSTALL_PREFIX/bin/gdb" ]] || die "missing gdb binary: $INSTALL_PREFIX/bin/gdb"
[[ -x "$INSTALL_PREFIX/bin/gdbserver" ]] || die "missing gdbserver binary: $INSTALL_PREFIX/bin/gdbserver"

PACKAGE_ROOT="$DIST_DIR/$PACKAGE_NAME"
PACKAGE_FILE="$DIST_DIR/$PACKAGE_NAME.tar.gz"

rm -rf "$PACKAGE_ROOT" "$PACKAGE_FILE" "$PACKAGE_FILE.sha256"
mkdir -p "$DIST_DIR" "$PACKAGE_ROOT"

cp -a "$INSTALL_PREFIX/." "$PACKAGE_ROOT/"

cat >> "$PACKAGE_ROOT/BUILD_INFO.txt" <<EOF
package=$PACKAGE_NAME
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

tar -czf "$PACKAGE_FILE" -C "$DIST_DIR" "$PACKAGE_NAME"
(
  cd "$DIST_DIR"
  sha256sum "$(basename "$PACKAGE_FILE")" > "$(basename "$PACKAGE_FILE").sha256"
)
rm -rf "$PACKAGE_ROOT"

write_output package_file "$PACKAGE_FILE"
write_output checksum_file "$PACKAGE_FILE.sha256"

echo "package=$PACKAGE_FILE"
