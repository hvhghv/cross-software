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

SOFTWARE_NAME=${SOFTWARE_NAME:-busybox}
BUSYBOX_VERSION=${BUSYBOX_VERSION:-1.38.0}
TARGET_TRIPLET=${TARGET_TRIPLET:?TARGET_TRIPLET is required}
LINKAGE=${LINKAGE:-static}
BUSYBOX_BIN=${BUSYBOX_BIN:?BUSYBOX_BIN is required}
ROOTFS_DIR=${ROOTFS_DIR:-}
CONFIG_FILE=${CONFIG_FILE:-}
DIST_DIR=${DIST_DIR:-"$REPO_ROOT/dist"}

case "$LINKAGE" in
  static|dynamic) ;;
  *) die "LINKAGE must be static or dynamic, got: $LINKAGE" ;;
esac

mkdir -p "$DIST_DIR"

if [[ "$LINKAGE" == static ]]; then
  [[ -x "$BUSYBOX_BIN" ]] || die "missing static busybox binary: $BUSYBOX_BIN"
  PACKAGE_FILE="$DIST_DIR/$SOFTWARE_NAME-$BUSYBOX_VERSION-$TARGET_TRIPLET-static"
  CHECKSUM_FILE="$PACKAGE_FILE.sha256"
  rm -f "$PACKAGE_FILE" "$CHECKSUM_FILE"
  cp -a "$BUSYBOX_BIN" "$PACKAGE_FILE"
  chmod 755 "$PACKAGE_FILE"
  (
    cd "$DIST_DIR"
    sha256sum "$(basename "$PACKAGE_FILE")" > "$(basename "$CHECKSUM_FILE")"
  )
else
  [[ -n "$ROOTFS_DIR" && -d "$ROOTFS_DIR" ]] || die "ROOTFS_DIR is required for dynamic packaging"
  [[ -x "$ROOTFS_DIR/bin/busybox" ]] || die "missing rootfs /bin/busybox: $ROOTFS_DIR/bin/busybox"
  [[ -x "$ROOTFS_DIR/usr/bin/busybox" ]] || die "missing rootfs /usr/bin/busybox: $ROOTFS_DIR/usr/bin/busybox"
  [[ -e "$ROOTFS_DIR/usr/sbin/busybox" ]] || die "missing rootfs /usr/sbin/busybox: $ROOTFS_DIR/usr/sbin/busybox"
  [[ -d "$ROOTFS_DIR/lib" ]] || die "missing rootfs lib directory: $ROOTFS_DIR/lib"
  if ! find "$ROOTFS_DIR/lib" -maxdepth 1 \( -name 'libc.so' -o -name 'ld-musl-*.so.1' \) -print -quit | grep -q .; then
    die "rootfs lib directory does not contain musl libc/loader"
  fi

  PACKAGE_NAME="$SOFTWARE_NAME-rootfs-$BUSYBOX_VERSION-$TARGET_TRIPLET-dynamic"
  PACKAGE_ROOT="$DIST_DIR/$PACKAGE_NAME"
  PACKAGE_FILE="$DIST_DIR/$PACKAGE_NAME.tar.gz"
  CHECKSUM_FILE="$PACKAGE_FILE.sha256"
  rm -rf "$PACKAGE_ROOT" "$PACKAGE_FILE" "$CHECKSUM_FILE"
  mkdir -p "$PACKAGE_ROOT"
  cp -a "$ROOTFS_DIR/." "$PACKAGE_ROOT/"
  if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
    cp -a "$CONFIG_FILE" "$PACKAGE_ROOT/busybox.config"
  fi
  tar -czf "$PACKAGE_FILE" -C "$DIST_DIR" "$PACKAGE_NAME"
  (
    cd "$DIST_DIR"
    sha256sum "$(basename "$PACKAGE_FILE")" > "$(basename "$CHECKSUM_FILE")"
  )
  rm -rf "$PACKAGE_ROOT"
fi

write_output package_file "$PACKAGE_FILE"
write_output checksum_file "$CHECKSUM_FILE"

echo "package=$PACKAGE_FILE"
