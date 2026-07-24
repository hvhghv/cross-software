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

require_dynamic_rootfs_skeleton() {
  local rootfs=$1
  local -a dirs=(
    bin
    dev
    dev/pts
    dev/shm
    etc
    etc/init.d
    etc/network
    etc/profile.d
    home
    lib
    media
    mnt
    opt
    proc
    root
    run
    run/lock
    sbin
    srv
    sys
    tmp
    usr
    usr/bin
    usr/lib
    usr/local
    usr/local/bin
    usr/local/lib
    usr/local/sbin
    usr/local/share
    usr/sbin
    usr/share
    usr/share/udhcpc
    var
    var/cache
    var/empty
    var/lib
    var/log
    var/spool
    var/tmp
  )
  local dir

  for dir in "${dirs[@]}"; do
    [[ -d "$rootfs/$dir" ]] || die "missing rootfs directory: /$dir"
  done

  [[ -L "$rootfs/var/run" ]] || die "missing rootfs symlink: /var/run"
  [[ -L "$rootfs/var/lock" ]] || die "missing rootfs symlink: /var/lock"
  [[ -L "$rootfs/dev/fd" ]] || die "missing rootfs symlink: /dev/fd"
  [[ -L "$rootfs/dev/stdin" ]] || die "missing rootfs symlink: /dev/stdin"
  [[ -L "$rootfs/dev/stdout" ]] || die "missing rootfs symlink: /dev/stdout"
  [[ -L "$rootfs/dev/stderr" ]] || die "missing rootfs symlink: /dev/stderr"
  [[ -L "$rootfs/dev/ptmx" ]] || die "missing rootfs symlink: /dev/ptmx"
  [[ -f "$rootfs/etc/passwd" ]] || die "missing rootfs file: /etc/passwd"
  [[ -f "$rootfs/etc/group" ]] || die "missing rootfs file: /etc/group"
  [[ -f "$rootfs/etc/shadow" ]] || die "missing rootfs file: /etc/shadow"
  [[ -f "$rootfs/etc/gshadow" ]] || die "missing rootfs file: /etc/gshadow"
  [[ -f "$rootfs/etc/profile" ]] || die "missing rootfs file: /etc/profile"
  [[ -f "$rootfs/etc/fstab" ]] || die "missing rootfs file: /etc/fstab"
  [[ -L "$rootfs/etc/mtab" ]] || die "missing rootfs symlink: /etc/mtab"
  [[ -f "$rootfs/etc/hosts" ]] || die "missing rootfs file: /etc/hosts"
  [[ -f "$rootfs/etc/hostname" ]] || die "missing rootfs file: /etc/hostname"
  [[ -f "$rootfs/etc/resolv.conf" ]] || die "missing rootfs file: /etc/resolv.conf"
  [[ -L "$rootfs/etc/resolve" ]] || die "missing rootfs symlink: /etc/resolve"
  [[ -f "$rootfs/etc/nsswitch.conf" ]] || die "missing rootfs file: /etc/nsswitch.conf"
  [[ -f "$rootfs/etc/shells" ]] || die "missing rootfs file: /etc/shells"
  [[ -f "$rootfs/etc/securetty" ]] || die "missing rootfs file: /etc/securetty"
  [[ -f "$rootfs/etc/issue" ]] || die "missing rootfs file: /etc/issue"
  [[ -f "$rootfs/etc/motd" ]] || die "missing rootfs file: /etc/motd"
  [[ -f "$rootfs/etc/mdev.conf" ]] || die "missing rootfs file: /etc/mdev.conf"
  [[ -f "$rootfs/etc/inittab" ]] || die "missing rootfs file: /etc/inittab"
  [[ -x "$rootfs/etc/init.d/rcS" ]] || die "missing executable rootfs file: /etc/init.d/rcS"
  [[ -f "$rootfs/etc/network/interfaces" ]] || die "missing rootfs file: /etc/network/interfaces"
  [[ -x "$rootfs/usr/share/udhcpc/default.script" ]] || die "missing executable rootfs file: /usr/share/udhcpc/default.script"
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
  [[ -d "$ROOTFS_DIR/lib" ]] || die "missing rootfs lib directory: $ROOTFS_DIR/lib"
  require_dynamic_rootfs_skeleton "$ROOTFS_DIR"
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
