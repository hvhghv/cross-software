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

SOFTWARE_NAME=${SOFTWARE_NAME:-dropbear}
DROPBEAR_VERSION=${DROPBEAR_VERSION:-2026.92}
TARGET_TRIPLET=${TARGET_TRIPLET:?TARGET_TRIPLET is required}
LINKAGE=${LINKAGE:-static}
INSTALL_PREFIX=${INSTALL_PREFIX:?INSTALL_PREFIX is required}
DIST_DIR=${DIST_DIR:-"$REPO_ROOT/dist"}
PACKAGE_NAME=${PACKAGE_NAME:-"$SOFTWARE_NAME-$DROPBEAR_VERSION-$TARGET_TRIPLET-$LINKAGE"}

[[ -d "$INSTALL_PREFIX" ]] || die "install prefix not found: $INSTALL_PREFIX"
[[ -x "$INSTALL_PREFIX/sbin/dropbear" ]] || die "missing dropbear binary: $INSTALL_PREFIX/sbin/dropbear"
[[ -x "$INSTALL_PREFIX/bin/dbclient" ]] || die "missing dbclient binary: $INSTALL_PREFIX/bin/dbclient"
[[ -x "$INSTALL_PREFIX/bin/dropbearkey" ]] || die "missing dropbearkey binary: $INSTALL_PREFIX/bin/dropbearkey"
[[ -x "$INSTALL_PREFIX/bin/dropbearconvert" ]] || die "missing dropbearconvert binary: $INSTALL_PREFIX/bin/dropbearconvert"
[[ -x "$INSTALL_PREFIX/bin/scp" ]] || die "missing scp binary: $INSTALL_PREFIX/bin/scp"

PACKAGE_ROOT="$DIST_DIR/$PACKAGE_NAME"
PACKAGE_FILE="$DIST_DIR/$PACKAGE_NAME.tar.gz"

rm -rf "$PACKAGE_ROOT" "$PACKAGE_FILE" "$PACKAGE_FILE.sha256"
mkdir -p "$DIST_DIR" "$PACKAGE_ROOT"

cp -a "$INSTALL_PREFIX/." "$PACKAGE_ROOT/"

cat >> "$PACKAGE_ROOT/BUILD_INFO.txt" <<EOF
package=$PACKAGE_NAME
software=$SOFTWARE_NAME
binaries=dropbear dbclient dropbearkey dropbearconvert scp
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
