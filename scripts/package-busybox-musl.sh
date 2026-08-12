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

require_account_database() {
  local rootfs=$1
  local passwd=$rootfs/etc/passwd
  local shadow=$rootfs/etc/shadow
  local group=$rootfs/etc/group
  local gshadow=$rootfs/etc/gshadow

  grep -qxF 'sshd:x:22:22:SSH privilege separation:/var/empty:/bin/false' "$passwd" \
    || die "rootfs passwd does not contain the sshd privilege-separation account"
  grep -qxF 'sshd:*:0:0:99999:7:::' "$shadow" \
    || die "rootfs shadow does not contain a locked sshd account"
  grep -qxF 'sshd:x:22:' "$group" \
    || die "rootfs group does not contain the sshd group"
  grep -qxF 'sshd:*::' "$gshadow" \
    || die "rootfs gshadow does not contain the sshd group"
  grep -qxF 'dhcpcd:x:23:23:dhcpcd privilege separation:/var/empty:/bin/false' "$passwd" \
    || die "rootfs passwd does not contain the dhcpcd privilege-separation account"
  grep -qxF 'dhcpcd:*:0:0:99999:7:::' "$shadow" \
    || die "rootfs shadow does not contain a locked dhcpcd account"
  grep -qxF 'dhcpcd:x:23:' "$group" \
    || die "rootfs group does not contain the dhcpcd group"
  grep -qxF 'dhcpcd:*::' "$gshadow" \
    || die "rootfs gshadow does not contain the dhcpcd group"

  awk -F: 'NF != 7 || $1 == "" || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ { exit 1 }' "$passwd" \
    || die "invalid rootfs passwd entry"
  awk -F: 'NF != 9 || $1 == "" { exit 1 }' "$shadow" \
    || die "invalid rootfs shadow entry"
  awk -F: 'NF != 4 || $1 == "" || $3 !~ /^[0-9]+$/ { exit 1 }' "$group" \
    || die "invalid rootfs group entry"
  awk -F: 'NF != 4 || $1 == "" { exit 1 }' "$gshadow" \
    || die "invalid rootfs gshadow entry"

  awk -F: 'seen_name[$1]++ || seen_id[$3]++ { exit 1 }' "$passwd" \
    || die "duplicate rootfs passwd name or UID"
  awk -F: 'seen_name[$1]++ || seen_id[$3]++ { exit 1 }' "$group" \
    || die "duplicate rootfs group name or GID"
  awk -F: 'NR == FNR { names[$1]=1; next } !($1 in names) { exit 1 }' "$shadow" "$passwd" \
    || die "rootfs passwd contains an account missing from shadow"
  awk -F: 'NR == FNR { names[$1]=1; next } !($1 in names) { exit 1 }' "$passwd" "$shadow" \
    || die "rootfs shadow contains an account missing from passwd"
  awk -F: 'NR == FNR { names[$1]=1; next } !($1 in names) { exit 1 }' "$gshadow" "$group" \
    || die "rootfs group contains an entry missing from gshadow"
  awk -F: 'NR == FNR { names[$1]=1; next } !($1 in names) { exit 1 }' "$group" "$gshadow" \
    || die "rootfs gshadow contains an entry missing from group"
  awk -F: 'NR == FNR { gids[$3]=1; next } !($4 in gids) { exit 1 }' "$group" "$passwd" \
    || die "rootfs passwd contains an account with an unknown primary GID"
  awk -F: '
    NR == FNR { users[$1]=1; next }
    {
      count=split($4, members, ",")
      for (i=1; i<=count; i++) {
        if (members[i] != "" && !(members[i] in users)) exit 1
      }
    }
  ' "$passwd" "$group" || die "rootfs group contains an unknown member"
}

require_init_script_contract() {
  local rootfs=$1
  local script
  local status

  for script in "$rootfs/etc/init.d/"S[0-9][0-9]*; do
    [[ -f "$script" && -x "$script" ]] \
      || die "invalid startup script: $script"
    [[ $(head -n 1 "$script") == '#!/bin/sh' ]] \
      || die "startup script does not use /bin/sh: $script"
    grep -qxF 'action=${1:-start}' "$script" \
      || die "startup script does not default to start: $script"
    grep -Eq '^[[:space:]]*start\)' "$script" \
      || die "startup script does not implement start: $script"
    if sh "$script" __unsupported_action__ >/dev/null 2>&1; then
      status=0
    else
      status=$?
    fi
    [[ "$status" -eq 2 ]] \
      || die "startup script does not reject unsupported actions with status 2: $script"
  done

  for script in "$rootfs/etc/init.d/"K[0-9][0-9]*; do
    [[ -f "$script" && -x "$script" ]] \
      || die "invalid shutdown script: $script"
    [[ $(head -n 1 "$script") == '#!/bin/sh' ]] \
      || die "shutdown script does not use /bin/sh: $script"
    grep -qxF 'action=${1:-stop}' "$script" \
      || die "shutdown script does not default to stop: $script"
    grep -Eq '^[[:space:]]*stop\)' "$script" \
      || die "shutdown script does not implement stop: $script"
    if sh "$script" __unsupported_action__ >/dev/null 2>&1; then
      status=0
    else
      status=$?
    fi
    [[ "$status" -eq 2 ]] \
      || die "shutdown script does not reject unsupported actions with status 2: $script"
  done
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
    etc/network/if-down.d
    etc/network/if-post-down.d
    etc/network/if-pre-up.d
    etc/network/if-up.d
    etc/profile.d
    home
    lib
    media
    mnt
    opt
    proc
    root
    run
    sbin
    srv
    srv/ftp
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
    var/spool/mail
    var/tmp
    var/www
  )
  local dir
  local library
  local target
  local resolved
  local script
  local unexpected
  local -a loaders=()

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
  [[ -L "$rootfs/bin/sh" ]] || die "missing BusyBox shell symlink: /bin/sh"
  unexpected=$(find "$rootfs/run" -mindepth 1 -print -quit)
  [[ -z "$unexpected" ]] || die "rootfs /run must be empty before tmpfs is mounted: $unexpected"
  [[ -f "$rootfs/etc/passwd" ]] || die "missing rootfs file: /etc/passwd"
  [[ -f "$rootfs/etc/group" ]] || die "missing rootfs file: /etc/group"
  [[ -f "$rootfs/etc/shadow" ]] || die "missing rootfs file: /etc/shadow"
  [[ -f "$rootfs/etc/gshadow" ]] || die "missing rootfs file: /etc/gshadow"
  require_account_database "$rootfs"
  [[ -f "$rootfs/etc/profile" ]] || die "missing rootfs file: /etc/profile"
  [[ -f "$rootfs/etc/fstab" ]] || die "missing rootfs file: /etc/fstab"
  [[ -L "$rootfs/etc/mtab" ]] || die "missing rootfs symlink: /etc/mtab"
  [[ -f "$rootfs/etc/hostname" ]] || die "missing rootfs file: /etc/hostname"
  [[ -f "$rootfs/etc/hosts" ]] || die "missing rootfs file: /etc/hosts"
  [[ -f "$rootfs/etc/resolv.conf" ]] || die "missing rootfs file: /etc/resolv.conf"
  [[ -L "$rootfs/etc/resolve" ]] || die "missing rootfs symlink: /etc/resolve"
  [[ -f "$rootfs/etc/nsswitch.conf" ]] || die "missing rootfs file: /etc/nsswitch.conf"
  [[ -f "$rootfs/etc/shells" ]] || die "missing rootfs file: /etc/shells"
  [[ -f "$rootfs/etc/securetty" ]] || die "missing rootfs file: /etc/securetty"
  [[ -f "$rootfs/etc/issue" ]] || die "missing rootfs file: /etc/issue"
  [[ -f "$rootfs/etc/issue.net" ]] || die "missing rootfs file: /etc/issue.net"
  [[ -f "$rootfs/etc/motd" ]] || die "missing rootfs file: /etc/motd"
  [[ -f "$rootfs/etc/mdev.conf" ]] || die "missing rootfs file: /etc/mdev.conf"
  [[ -f "$rootfs/etc/inittab" ]] || die "missing rootfs file: /etc/inittab"
  grep -qxF '::sysinit:/etc/init.d/rcS' "$rootfs/etc/inittab" \
    || die "rootfs inittab does not start /etc/init.d/rcS"
  grep -qxF '::shutdown:/etc/init.d/rcK' "$rootfs/etc/inittab" \
    || die "rootfs inittab does not stop through /etc/init.d/rcK"
  [[ -f "$rootfs/etc/network/interface" ]] || die "missing rootfs file: /etc/network/interface"
  [[ -x "$rootfs/etc/network/if-up.d/10-resolv" ]] \
    || die "missing executable rootfs file: /etc/network/if-up.d/10-resolv"
  [[ -x "$rootfs/etc/udhcpc.script" ]] || die "missing executable rootfs file: /etc/udhcpc.script"
  [[ -L "$rootfs/usr/share/udhcpc/default.script" ]] \
    || die "missing rootfs symlink: /usr/share/udhcpc/default.script"
  [[ $(readlink "$rootfs/usr/share/udhcpc/default.script") == '../../../etc/udhcpc.script' ]] \
    || die "invalid rootfs symlink: /usr/share/udhcpc/default.script"
  [[ -x "$rootfs/etc/init.d/rcS" ]] || die "missing executable rootfs file: /etc/init.d/rcS"
  [[ -x "$rootfs/etc/init.d/rcK" ]] || die "missing executable rootfs file: /etc/init.d/rcK"
  for script in S00mount S01mdev S90network S99telnetd K99telnetd K90network K01mdev K00mount; do
    [[ -x "$rootfs/etc/init.d/$script" ]] \
      || die "missing executable rootfs file: /etc/init.d/$script"
  done
  require_init_script_contract "$rootfs"

  for script in \
    "$rootfs/etc/udhcpc.script" \
    "$rootfs/etc/init.d/"* \
    "$rootfs/etc/network"/if-*.d/*
  do
    [[ -f "$script" ]] || continue
    sh -n "$script" || die "invalid rootfs shell script: $script"
  done

  for dir in /proc /sys /dev /dev/pts /dev/shm /run /tmp; do
    awk -v target="$dir" '$2 == target { found=1 } END { exit !found }' "$rootfs/etc/fstab" \
      || die "missing rootfs fstab mount point: $dir"
  done

  unexpected=$(find "$rootfs/lib" "$rootfs/usr/lib" -maxdepth 1 \
    \( -type f -o -type l \) \
    ! \( -name '*.so' -o -name '*.so.*' \) \
    -print -quit)
  [[ -z "$unexpected" ]] || die "non-shared runtime file in rootfs: $unexpected"

  while IFS= read -r -d '' library; do
    target=$(readlink "$library")
    [[ "$target" != /* ]] || die "absolute runtime library symlink: $library -> $target"
    [[ -f "$library" ]] || die "broken runtime library symlink: $library -> $target"
    resolved=$(readlink -f "$library")
    case "$resolved" in
      "$rootfs/lib/"*|"$rootfs/usr/lib/"*) ;;
      *) die "runtime library symlink escapes rootfs library directories: $library -> $target" ;;
    esac
  done < <(
    find "$rootfs/lib" "$rootfs/usr/lib" -maxdepth 1 -type l -print0
  )

  while IFS= read -r -d '' library; do
    LC_ALL=C readelf -h "$library" 2>/dev/null \
      | grep -Eq 'Type:[[:space:]]+DYN' \
      || die "non-shared ELF file in rootfs library directory: $library"
  done < <(
    find "$rootfs/lib" "$rootfs/usr/lib" -maxdepth 1 \
      -type f -print0
  )

  mapfile -t loaders < <(
    find "$rootfs/lib" -maxdepth 1 -type l -name 'ld-musl-*.so.1' -print
  )
  ((${#loaders[@]} == 1)) \
    || die "rootfs must contain exactly one musl loader symlink"
  [[ $(readlink "${loaders[0]}") == libc.so ]] \
    || die "musl loader must be a relative symlink to libc.so: ${loaders[0]}"
  [[ -f "$rootfs/lib/libc.so" ]] || die "rootfs is missing musl libc: /lib/libc.so"
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
  tar --numeric-owner --owner=0 --group=0 \
    -czf "$PACKAGE_FILE" -C "$DIST_DIR" "$PACKAGE_NAME"
  (
    cd "$DIST_DIR"
    sha256sum "$(basename "$PACKAGE_FILE")" > "$(basename "$CHECKSUM_FILE")"
  )
  rm -rf "$PACKAGE_ROOT"
fi

write_output package_file "$PACKAGE_FILE"
write_output checksum_file "$CHECKSUM_FILE"

echo "package=$PACKAGE_FILE"
