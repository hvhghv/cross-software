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

config_set() {
  local key=$1
  local value=$2

  case "$value" in
    y)
      if grep -qE "^(# )?$key(=| is not set)" .config; then
        sed -i -E "s|^# $key is not set|$key=y|; s|^$key=.*|$key=y|" .config
      else
        printf '%s=y\n' "$key" >> .config
      fi
      ;;
    n)
      if grep -qE "^(# )?$key(=| is not set)" .config; then
        sed -i -E "s|^$key=.*|# $key is not set|; s|^# $key is not set|# $key is not set|" .config
      else
        printf '# %s is not set\n' "$key" >> .config
      fi
      ;;
    *)
      die "unsupported config value for $key: $value"
      ;;
  esac
}

config_string() {
  local key=$1
  local value=$2
  local escaped
  escaped=$(printf '%s' "$value" | sed 's/[\/&]/\\&/g')

  if grep -qE "^$key=" .config; then
    sed -i -E "s/^$key=.*/$key=\"$escaped\"/" .config
  else
    printf '%s="%s"\n' "$key" "$value" >> .config
  fi
}

compiler_has_header() {
  local header=$1

  printf '#include <%s>\nint main(void) { return 0; }\n' "$header" \
    | "$CC_TOOL" -x c -c -o /dev/null - >/dev/null 2>&1
}

require_config_enabled() {
  local key=$1

  grep -qx "$key=y" .config || die "$key is not enabled in final BusyBox config"
}

verify_riscv64_restored_configs() {
  [[ "$TARGET_TRIPLET" == riscv64-linux-musl ]] || return 0

  echo "verifying restored riscv64 BusyBox config parity"
  local -a restored_configs=(
    CONFIG_BEEP
    CONFIG_CHATTR
    CONFIG_CONSPY
    CONFIG_EJECT
    CONFIG_FEATURE_EJECT_SCSI
    CONFIG_FEATURE_LOADFONT_PSF2
    CONFIG_FEATURE_LOADFONT_RAW
    CONFIG_FEATURE_MOUNT_LOOP
    CONFIG_FEATURE_MOUNT_LOOP_CREATE
    CONFIG_FEATURE_SETFONT_TEXTUAL_MAP
    CONFIG_FEATURE_SETPRIV_CAPABILITIES
    CONFIG_FEATURE_SETPRIV_CAPABILITY_NAMES
    CONFIG_INIT
    CONFIG_KBD_MODE
    CONFIG_LINUXRC
    CONFIG_LOADFONT
    CONFIG_LOSETUP
    CONFIG_LSATTR
    CONFIG_OPENVT
    CONFIG_RUN_INIT
    CONFIG_SETFONT
    CONFIG_SHOWKEY
    CONFIG_TUNE2FS
    CONFIG_VLOCK
  )

  local key
  for key in "${restored_configs[@]}"; do
    require_config_enabled "$key"
  done
}

verify_dynamic_rootfs_configs() {
  [[ "$LINKAGE" == dynamic ]] || return 0

  local -a required_configs=(
    CONFIG_CAT
    CONFIG_FIND
    CONFIG_FEATURE_MOUNT_FSTAB
    CONFIG_FEATURE_SHADOWPASSWDS
    CONFIG_FEATURE_SH_MATH
    CONFIG_FEATURE_TELNETD_STANDALONE
    CONFIG_FEATURE_TFTP_BLOCKSIZE
    CONFIG_FEATURE_TFTP_GET
    CONFIG_GREP
    CONFIG_HUSH
    CONFIG_HUSH_CASE
    CONFIG_HUSH_EXPORT
    CONFIG_HUSH_FUNCTIONS
    CONFIG_HUSH_IF
    CONFIG_HUSH_KILL
    CONFIG_HUSH_LOOPS
    CONFIG_HUSH_PRINTF
    CONFIG_HUSH_READ
    CONFIG_HUSH_TEST
    CONFIG_IFDOWN
    CONFIG_IFCONFIG
    CONFIG_IFUP
    CONFIG_FEATURE_IFUPDOWN_EXTERNAL_DHCP
    CONFIG_FEATURE_IFUPDOWN_IP
    CONFIG_FEATURE_IFUPDOWN_IPV4
    CONFIG_INIT
    CONFIG_IP
    CONFIG_KILLALL
    CONFIG_LN
    CONFIG_LOGIN
    CONFIG_MDEV
    CONFIG_FEATURE_MDEV_DAEMON
    CONFIG_MKDIR
    CONFIG_MOUNT
    CONFIG_PIDOF
    CONFIG_ROUTE
    CONFIG_RUN_PARTS
    CONFIG_SH_IS_HUSH
    CONFIG_SLEEP
    CONFIG_SORT
    CONFIG_SWAPOFF
    CONFIG_SYNC
    CONFIG_TELNETD
    CONFIG_TFTPD
    CONFIG_TR
    CONFIG_UDHCPC
    CONFIG_UDPSVD
    CONFIG_UMOUNT
  )
  local key

  for key in "${required_configs[@]}"; do
    require_config_enabled "$key"
  done
}

dump_busybox_failure_logs() {
  local log

  find . -maxdepth 3 -type f \
    \( -name 'busybox_unstripped.out' -o -name 'busybox_unstripped.err' -o -name '*.out' -o -name '*.err' \) \
    -print | sort | while IFS= read -r log; do
      echo "---- $log (error matches) ----" >&2
      grep -nEi 'undefined reference|relocation|cannot find|collect2|ld returned|ld:|fatal error|error:' "$log" \
        | tail -n 120 >&2 || true
      echo "---- $log (first 120 lines) ----" >&2
      sed -n '1,120p' "$log" >&2 || true
      echo "---- $log (last 240 lines) ----" >&2
      tail -n 240 "$log" >&2 || true
    done
}

rerun_busybox_link_for_diagnostics() {
  local link_log=./busybox_unstripped.out
  local rerun_log=./busybox_unstripped.rerun.out
  local cmd
  local rc

  [[ -f "$link_log" ]] || return 0
  cmd=$(awk 'found && /^==========$/ { exit } found { print } /^Output of:$/ { found=1 }' "$link_log" | tr '\n' ' ')
  [[ -n "${cmd//[[:space:]]/}" ]] || return 0

  echo "---- rerunning busybox final link directly ----" >&2
  rm -f busybox_unstripped "$rerun_log"
  set +e
  bash -lc "$cmd" >"$rerun_log" 2>&1
  rc=$?
  set -e

  echo "busybox final link rerun exit code: $rc" >&2
  echo "---- $rerun_log (first 240 lines) ----" >&2
  sed -n '1,240p' "$rerun_log" >&2 || true
  echo "---- $rerun_log (last 240 lines) ----" >&2
  tail -n 240 "$rerun_log" >&2 || true
}

read_elf_needed() {
  local elf=$1

  LC_ALL=C readelf -d "$elf" 2>/dev/null \
    | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p'
}

find_runtime_library() {
  local name=$1
  local compiler=$2
  local candidate

  for candidate in \
    "$MUSL_SYSROOT/lib/$name" \
    "$MUSL_SYSROOT/usr/lib/$name"
  do
    if [[ -e "$candidate" || -L "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  candidate=$("$compiler" -print-file-name="$name" 2>/dev/null || true)
  if [[ -n "$candidate" && "$candidate" != "$name" && -e "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi

  return 1
}

copy_shared_object_entries() {
  local source_dir=$1
  local destination_dir=$2
  local entry

  [[ -d "$source_dir" ]] || return 0
  while IFS= read -r -d '' entry; do
    if [[ -L "$entry" ]]; then
      copy_runtime_library_chain \
        "$entry" "$destination_dir/$(basename "$entry")"
    elif LC_ALL=C readelf -h "$entry" 2>/dev/null \
      | grep -Eq 'Type:[[:space:]]+DYN'
    then
      cp -a "$entry" "$destination_dir/"
    fi
  done < <(
    find "$source_dir" -maxdepth 1 \
      \( -type f -o -type l \) \
      \( -name '*.so' -o -name '*.so.*' \) \
      -print0
  )
}

copy_runtime_library_chain() {
  local source=$1
  local destination=$2
  local target
  local target_name
  local next_source
  local -A seen=()

  while [[ -L "$source" ]]; do
    [[ -z "${seen[$source]:-}" ]] || die "runtime library symlink loop: $source"
    seen[$source]=1
    target=$(readlink "$source")
    target_name=${target##*/}
    case "$target_name" in
      *.so|*.so.*) ;;
      *) die "runtime library symlink has an invalid target: $source -> $target" ;;
    esac

    if [[ "$target" == /* ]]; then
      next_source="$MUSL_SYSROOT$target"
    else
      next_source="$(dirname "$source")/$target"
    fi
    [[ -e "$next_source" || -L "$next_source" ]] \
      || die "runtime library symlink target not found: $source -> $target"

    if [[ "$target_name" == "${destination##*/}" ]]; then
      source=$next_source
      continue
    fi

    if [[ -L "$destination" && $(readlink "$destination") == "$target_name" ]]; then
      :
    elif [[ -e "$destination" || -L "$destination" ]]; then
      die "runtime library destination collision: $destination"
    else
      ln -s "$target_name" "$destination"
    fi

    source=$next_source
    destination="$(dirname "$destination")/$target_name"
  done

  LC_ALL=C readelf -h "$source" 2>/dev/null \
    | grep -Eq 'Type:[[:space:]]+DYN' \
    || die "runtime dependency is not an ELF shared object: $source"
  if [[ ! -e "$destination" && ! -L "$destination" ]]; then
    cp -a "$source" "$destination"
  fi
}

copy_elf_needed_closure() {
  local rootfs=$1
  local binary=$2
  local compiler=$3
  local name
  local source
  local installed
  local dependency
  local -a pending=()
  local -A copied=()

  mapfile -t pending < <(read_elf_needed "$binary")
  while ((${#pending[@]})); do
    name=${pending[0]}
    pending=("${pending[@]:1}")
    [[ -z "${copied[$name]:-}" ]] || continue
    case "$name" in
      *.so|*.so.*) ;;
      *) die "runtime dependency is not a shared object name: $name" ;;
    esac

    if [[ -e "$rootfs/lib/$name" || -L "$rootfs/lib/$name" ]]; then
      installed="$rootfs/lib/$name"
    elif [[ -e "$rootfs/usr/lib/$name" || -L "$rootfs/usr/lib/$name" ]]; then
      installed="$rootfs/usr/lib/$name"
    else
      if ! source=$(find_runtime_library "$name" "$compiler"); then
        die "runtime dependency not found in musl toolchain: $name"
      fi
      copy_runtime_library_chain "$source" "$rootfs/lib/$name"
      installed="$rootfs/lib/$name"
    fi
    LC_ALL=C readelf -h "$installed" 2>/dev/null \
      | grep -Eq 'Type:[[:space:]]+DYN' \
      || die "installed runtime dependency is not an ELF shared object: $installed"

    copied[$name]=1
    while IFS= read -r dependency; do
      [[ -n "${copied[$dependency]:-}" ]] || pending+=("$dependency")
    done < <(read_elf_needed "$installed")
  done
}

require_shared_objects_only() {
  local rootfs=$1
  local unexpected
  local library
  local target
  local resolved
  local -a loaders=()

  unexpected=$(find "$rootfs/lib" "$rootfs/usr/lib" -maxdepth 1 \
    \( -type f -o -type l \) \
    ! \( -name '*.so' -o -name '*.so.*' \) \
    -print -quit)
  [[ -z "$unexpected" ]] || die "non-shared runtime file copied into rootfs: $unexpected"

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
      || die "non-shared ELF file copied into rootfs library directory: $library"
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

copy_musl_runtime() {
  local rootfs=$1
  local binary=$2
  local compiler=$3
  local interp=

  [[ -n "${MUSL_SYSROOT:-}" && -d "$MUSL_SYSROOT" ]] || die "MUSL_SYSROOT is required for dynamic rootfs packaging"

  mkdir -p "$rootfs/lib" "$rootfs/usr/lib"

  copy_shared_object_entries "$MUSL_SYSROOT/lib" "$rootfs/lib"
  copy_shared_object_entries "$MUSL_SYSROOT/usr/lib" "$rootfs/usr/lib"
  copy_elf_needed_closure "$rootfs" "$binary" "$compiler"

  interp=$(LC_ALL=C readelf -l "$binary" 2>/dev/null \
    | sed -n 's|.*program interpreter: \([^]]*\)\].*|\1|p' \
    | head -n 1 || true)
  if [[ -n "$interp" ]]; then
    [[ -L "$rootfs$interp" ]] \
      || die "musl interpreter was not preserved as a symlink: $interp"
    [[ $(readlink "$rootfs$interp") == libc.so ]] \
      || die "musl interpreter does not point to libc.so: $interp"
  fi
  require_shared_objects_only "$rootfs"
}

create_busybox_rootfs_skeleton() {
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
  local etc_source=${BUSYBOX_ETC_DIR:-$REPO_ROOT/etc/busybox}
  local file
  local -a required_etc_files=(
    fstab
    group
    gshadow
    hostname
    hosts
    inittab
    issue
    issue.net
    mdev.conf
    motd
    network/interface
    network/if-up.d/10-resolv
    nsswitch.conf
    passwd
    profile
    resolv.conf
    securetty
    shadow
    shells
    udhcpc.script
    init.d/rcS
    init.d/rcK
    init.d/S00mount
    init.d/S01mdev
    init.d/S90network
    init.d/S99telnetd
    init.d/K00mount
    init.d/K01mdev
    init.d/K90network
    init.d/K99telnetd
  )

  for dir in "${dirs[@]}"; do
    mkdir -p "$rootfs/$dir"
  done

  chmod 755 "$rootfs"
  chmod 700 "$rootfs/root"
  chmod 755 "$rootfs/var/empty"
  chmod 1777 "$rootfs/tmp" "$rootfs/var/tmp" "$rootfs/dev/shm"

  rm -rf "$rootfs/var/run" "$rootfs/var/lock"
  ln -s ../run "$rootfs/var/run"
  ln -s ../run/lock "$rootfs/var/lock"
  ln -sfn /proc/self/fd "$rootfs/dev/fd"
  ln -sfn /proc/self/fd/0 "$rootfs/dev/stdin"
  ln -sfn /proc/self/fd/1 "$rootfs/dev/stdout"
  ln -sfn /proc/self/fd/2 "$rootfs/dev/stderr"
  ln -sfn pts/ptmx "$rootfs/dev/ptmx"

  [[ -d "$etc_source" ]] || die "BusyBox etc template directory not found: $etc_source"
  for file in "${required_etc_files[@]}"; do
    [[ -f "$etc_source/$file" ]] || die "missing BusyBox etc template: $file"
  done

  cp -a "$etc_source/." "$rootfs/etc/"
  rm -f "$rootfs/etc/mtab" "$rootfs/etc/resolve"
  ln -sfn /proc/mounts "$rootfs/etc/mtab"
  ln -sfn resolv.conf "$rootfs/etc/resolve"
  ln -sfn ../../../etc/udhcpc.script "$rootfs/usr/share/udhcpc/default.script"

  find "$rootfs/etc" -type d -exec chmod 755 {} +
  find "$rootfs/etc" -type f -exec chmod 644 {} +
  find "$rootfs/etc/init.d" -maxdepth 1 -type f -exec chmod 755 {} +
  find "$rootfs/etc/network"/if-*.d -maxdepth 1 -type f -exec chmod 755 {} +
  chmod 755 "$rootfs/etc/udhcpc.script"
  chmod 600 "$rootfs/etc/shadow" "$rootfs/etc/gshadow"
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

SOFTWARE_NAME=${SOFTWARE_NAME:-busybox}
BUSYBOX_VERSION=${BUSYBOX_VERSION:-1.38.0}
TARGET_TRIPLET=${TARGET_TRIPLET:?TARGET_TRIPLET is required}
TARGET_ARCH=${TARGET_ARCH:-$TARGET_TRIPLET}
LINKAGE=${LINKAGE:-static}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}

case "$LINKAGE" in
  static|dynamic) ;;
  *) die "LINKAGE must be static or dynamic, got: $LINKAGE" ;;
esac

ARCHIVE_DIR=${ARCHIVE_DIR:-"$REPO_ROOT/archive"}
BUILD_ROOT=${BUILD_ROOT:-"$REPO_ROOT/build/$SOFTWARE_NAME-$BUSYBOX_VERSION-$TARGET_TRIPLET-$LINKAGE"}
SRC_ROOT="$BUILD_ROOT/src"
INSTALL_PREFIX="$BUILD_ROOT/install"
ROOTFS_DIR="$BUILD_ROOT/rootfs"

BUSYBOX_ARCHIVE="$ARCHIVE_DIR/busybox-$BUSYBOX_VERSION.tar.bz2"
[[ -f "$BUSYBOX_ARCHIVE" ]] || die "missing BusyBox archive: $BUSYBOX_ARCHIVE"

if command -v sha256sum >/dev/null 2>&1 && [[ -f "$ARCHIVE_DIR/SHA256SUMS" ]]; then
  (cd "$REPO_ROOT" && sha256sum --ignore-missing -c archive/SHA256SUMS)
fi

rm -rf "$BUILD_ROOT"
mkdir -p "$SRC_ROOT" "$INSTALL_PREFIX"

tar -xf "$BUSYBOX_ARCHIVE" -C "$SRC_ROOT"
BUSYBOX_SRC="$SRC_ROOT/busybox-$BUSYBOX_VERSION"
[[ -d "$BUSYBOX_SRC" ]] || die "extracted BusyBox source not found: $BUSYBOX_SRC"

CC_TOOL=$(resolve_tool "${MUSL_CC:-$TARGET_TRIPLET-gcc}")
AR=$(resolve_tool "${MUSL_AR:-$TARGET_TRIPLET-ar}")
RANLIB=$(resolve_tool "${MUSL_RANLIB:-$TARGET_TRIPLET-ranlib}")
STRIP=$(resolve_tool "${MUSL_STRIP:-$TARGET_TRIPLET-strip}")
CC_FOR_MAKE=$CC_TOOL

if [[ "${USE_CCACHE:-0}" == 1 ]]; then
  CCACHE_BIN=$(resolve_tool "${CCACHE:-ccache}")
  if [[ -n "${CCACHE_DIR:-}" ]]; then
    mkdir -p "$CCACHE_DIR"
  fi
  CC_FOR_MAKE="$CCACHE_BIN $CC_TOOL"
fi

MAKE_ARGS=(
  "CC=$CC_FOR_MAKE"
  "AR=$AR"
  "RANLIB=$RANLIB"
  "STRIP=$STRIP"
  "HOSTCC=${HOSTCC:-gcc}"
)

echo "software=$SOFTWARE_NAME"
echo "version=$BUSYBOX_VERSION"
echo "target=$TARGET_TRIPLET"
echo "arch=$TARGET_ARCH"
echo "linkage=$LINKAGE"
echo "cc=$CC_TOOL"
if [[ "${USE_CCACHE:-0}" == 1 ]]; then
  echo "ccache=$CCACHE_BIN"
fi
echo "jobs=$JOBS"

(
  cd "$BUSYBOX_SRC"
  # Keep CI final links lean; these options only produce diagnostics/map files.
  sed -i \
    -e 's/^WARN_COMMON="-Wl,--warn-common"/WARN_COMMON=""/' \
    -e 's/^MAP_OPT="-Wl,-Map,\$EXE\.map"/MAP_OPT=""/' \
    -e 's/^VERBOSE_OPT="-Wl,--verbose"/VERBOSE_OPT=""/' \
    scripts/trylink

  make "${MAKE_ARGS[@]}" allyesconfig

  config_set CONFIG_STATIC "$([[ "$LINKAGE" == static ]] && echo y || echo n)"
  config_set CONFIG_PIE n
  config_set CONFIG_PAM n
  config_set CONFIG_SELINUX n
  config_set CONFIG_SELINUXENABLED n
  config_set CONFIG_FEATURE_TAR_SELINUX n
  config_set CONFIG_FEATURE_INETD_RPC n
  config_set CONFIG_FEATURE_MOUNT_NFS n
  config_set CONFIG_EXTRA_COMPAT n
  config_set CONFIG_FEATURE_VI_REGEX_SEARCH n
  config_set CONFIG_DEBUG n
  config_set CONFIG_DEBUG_PESSIMIZE n
  config_set CONFIG_DEBUG_SANITIZE n
  config_set CONFIG_TFTP_DEBUG n
  config_set CONFIG_WERROR n
  config_set CONFIG_DMALLOC n
  config_set CONFIG_EFENCE n
  config_set CONFIG_UNIT_TEST n
  config_set CONFIG_NOMMU n
  config_set CONFIG_BUILD_LIBBUSYBOX n
  config_set CONFIG_FEATURE_SHARED_BUSYBOX n
  config_set CONFIG_FEATURE_INDIVIDUAL n
  config_set CONFIG_FEATURE_USE_BSS_TAIL n
  config_set CONFIG_MDEV y
  config_set CONFIG_FEATURE_MDEV_DAEMON y
  config_set CONFIG_INSTALL_APPLET_SYMLINKS y
  config_set CONFIG_INSTALL_APPLET_HARDLINKS n
  config_set CONFIG_INSTALL_APPLET_SCRIPT_WRAPPERS n
  config_set CONFIG_INSTALL_APPLET_DONT n
  config_set CONFIG_INSTALL_NO_USR n
  config_set CONFIG_FEATURE_SH_STANDALONE y
  config_set CONFIG_FEATURE_PREFER_APPLETS y
  config_string CONFIG_PREFIX ./_install
  config_string CONFIG_EXTRA_LDLIBS "crypt m resolv rt"

  if ! compiler_has_header linux/kd.h; then
    echo "target header linux/kd.h is missing; disabling dependent applets"
    config_set CONFIG_LOADFONT n
    config_set CONFIG_SETFONT n
    config_set CONFIG_FEATURE_SETFONT_TEXTUAL_MAP n
    config_set CONFIG_FEATURE_LOADFONT_PSF2 n
    config_set CONFIG_FEATURE_LOADFONT_RAW n
    config_set CONFIG_KBD_MODE n
    config_set CONFIG_SHOWKEY n
    config_set CONFIG_BEEP n
  fi
  if ! compiler_has_header linux/vt.h; then
    echo "target header linux/vt.h is missing; disabling dependent applets"
    config_set CONFIG_INIT n
    config_set CONFIG_LINUXRC n
    config_set CONFIG_OPENVT n
    config_set CONFIG_VLOCK n
  fi
  if ! compiler_has_header linux/version.h; then
    echo "target header linux/version.h is missing; disabling loopback-dependent applets"
    config_set CONFIG_LOSETUP n
    config_set CONFIG_FEATURE_MOUNT_LOOP n
    config_set CONFIG_FEATURE_MOUNT_LOOP_CREATE n
  fi
  if ! compiler_has_header linux/fs.h; then
    echo "target header linux/fs.h is missing; disabling dependent applets"
    config_set CONFIG_CHATTR n
    config_set CONFIG_LSATTR n
    config_set CONFIG_TUNE2FS n
  fi
  if ! compiler_has_header linux/capability.h; then
    echo "target header linux/capability.h is missing; disabling dependent applets"
    config_set CONFIG_FEATURE_SETPRIV_CAPABILITIES n
    config_set CONFIG_FEATURE_SETPRIV_CAPABILITY_NAMES n
    config_set CONFIG_RUN_INIT n
  fi

  make "${MAKE_ARGS[@]}" silentoldconfig
  verify_riscv64_restored_configs
  verify_dynamic_rootfs_configs

  cp .config "$BUILD_ROOT/busybox-$LINKAGE.config"
  if ! make "${MAKE_ARGS[@]}" -j "$JOBS"; then
    rerun_busybox_link_for_diagnostics
    dump_busybox_failure_logs
    exit 1
  fi

  if [[ "$LINKAGE" == static ]]; then
    mkdir -p "$INSTALL_PREFIX"
    cp -a busybox "$INSTALL_PREFIX/busybox"
    "$STRIP" "$INSTALL_PREFIX/busybox" || true
  else
    rm -rf "$ROOTFS_DIR"
    create_busybox_rootfs_skeleton "$ROOTFS_DIR"
    make "${MAKE_ARGS[@]}" CONFIG_PREFIX="$ROOTFS_DIR" install
    copy_musl_runtime "$ROOTFS_DIR" "$ROOTFS_DIR/bin/busybox" "$CC_TOOL"
    "$STRIP" "$ROOTFS_DIR/bin/busybox" || true
  fi
)

if [[ "$LINKAGE" == static ]]; then
  BUSYBOX_BIN="$INSTALL_PREFIX/busybox"
  [[ -x "$BUSYBOX_BIN" ]] || die "static busybox was not installed"
  cat > "$INSTALL_PREFIX/BUILD_INFO.txt" <<EOF
software=$SOFTWARE_NAME
version=$BUSYBOX_VERSION
target=$TARGET_TRIPLET
arch=$TARGET_ARCH
linkage=$LINKAGE
config=allyesconfig-with-musl-release-adjustments
artifact=single-binary
EOF
  write_output busybox_bin "$BUSYBOX_BIN"
else
  BUSYBOX_BIN="$ROOTFS_DIR/bin/busybox"
  [[ -x "$BUSYBOX_BIN" ]] || die "dynamic rootfs busybox was not installed"
  [[ -d "$ROOTFS_DIR/lib" ]] || die "dynamic rootfs lib directory was not created"
  cat > "$ROOTFS_DIR/BUILD_INFO.txt" <<EOF
software=$SOFTWARE_NAME
version=$BUSYBOX_VERSION
target=$TARGET_TRIPLET
arch=$TARGET_ARCH
linkage=$LINKAGE
config=allyesconfig-with-musl-release-adjustments
artifact=rootfs
musl_sysroot=${MUSL_SYSROOT:-}
EOF
  cp "$BUILD_ROOT/busybox-$LINKAGE.config" "$ROOTFS_DIR/busybox.config"
  write_output busybox_bin "$BUSYBOX_BIN"
  write_output rootfs_dir "$ROOTFS_DIR"
fi

write_output install_prefix "$INSTALL_PREFIX"
write_output config_file "$BUILD_ROOT/busybox-$LINKAGE.config"

echo "installed busybox to $([[ "$LINKAGE" == static ]] && echo "$INSTALL_PREFIX" || echo "$ROOTFS_DIR")"
