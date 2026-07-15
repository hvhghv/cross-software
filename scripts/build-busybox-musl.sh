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

copy_musl_runtime() {
  local rootfs=$1
  local binary=$2
  local compiler=$3
  local interp=
  local libc_source=
  local libgcc_path=

  [[ -n "${MUSL_SYSROOT:-}" && -d "$MUSL_SYSROOT" ]] || die "MUSL_SYSROOT is required for dynamic rootfs packaging"

  mkdir -p "$rootfs/lib" "$rootfs/usr/lib"
  if [[ -d "$MUSL_SYSROOT/lib" ]]; then
    cp -a "$MUSL_SYSROOT/lib/." "$rootfs/lib/"
  fi
  if [[ -d "$MUSL_SYSROOT/usr/lib" ]]; then
    cp -a "$MUSL_SYSROOT/usr/lib/." "$rootfs/usr/lib/"
  fi

  interp=$(LC_ALL=C readelf -l "$binary" 2>/dev/null \
    | sed -n 's|.*program interpreter: \([^]]*\)\].*|\1|p' \
    | head -n 1 || true)
  if [[ -n "$interp" && ( ! -e "$rootfs$interp" || -L "$rootfs$interp" ) ]]; then
    libc_source=$(find "$MUSL_SYSROOT" -path '*/lib/libc.so' -print -quit)
    if [[ -z "$libc_source" ]]; then
      libc_source=$(find "$MUSL_SYSROOT" -name 'ld-musl-*.so.1' ! -type l -print -quit)
    fi
    [[ -n "$libc_source" ]] || die "musl libc/loader not found under MUSL_SYSROOT=$MUSL_SYSROOT"
    mkdir -p "$rootfs$(dirname "$interp")"
    rm -f "$rootfs$interp"
    cp -L "$libc_source" "$rootfs$interp"
  fi

  libgcc_path=$("$compiler" -print-file-name=libgcc_s.so.1 || true)
  if [[ -n "$libgcc_path" && "$libgcc_path" != libgcc_s.so.1 && -e "$libgcc_path" ]]; then
    cp -L "$libgcc_path" "$rootfs/lib/" || true
  fi
}

install_busybox_link() {
  local source=$1
  local dest=$2

  rm -f "$dest"
  ln "$source" "$dest" 2>/dev/null || cp -a "$source" "$dest"
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
  config_set CONFIG_WERROR n
  config_set CONFIG_DMALLOC n
  config_set CONFIG_EFENCE n
  config_set CONFIG_UNIT_TEST n
  config_set CONFIG_NOMMU n
  config_set CONFIG_BUILD_LIBBUSYBOX n
  config_set CONFIG_FEATURE_SHARED_BUSYBOX n
  config_set CONFIG_FEATURE_INDIVIDUAL n
  config_set CONFIG_FEATURE_USE_BSS_TAIL n
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
  fi
  if ! compiler_has_header linux/fs.h; then
    echo "target header linux/fs.h is missing; disabling dependent applets"
    config_set CONFIG_CHATTR n
    config_set CONFIG_LSATTR n
    config_set CONFIG_TUNE2FS n
  fi

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
    make "${MAKE_ARGS[@]}" CONFIG_PREFIX="$ROOTFS_DIR" install
    mkdir -p "$ROOTFS_DIR/usr/bin" "$ROOTFS_DIR/usr/sbin"
    install_busybox_link "$ROOTFS_DIR/bin/busybox" "$ROOTFS_DIR/usr/bin/busybox"
    install_busybox_link "$ROOTFS_DIR/bin/busybox" "$ROOTFS_DIR/usr/sbin/busybox"
    copy_musl_runtime "$ROOTFS_DIR" "$ROOTFS_DIR/bin/busybox" "$CC_TOOL"
    "$STRIP" "$ROOTFS_DIR/bin/busybox" "$ROOTFS_DIR/usr/bin/busybox" "$ROOTFS_DIR/usr/sbin/busybox" || true
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
  [[ -x "$ROOTFS_DIR/usr/bin/busybox" ]] || die "dynamic rootfs /usr/bin/busybox was not installed"
  [[ -e "$ROOTFS_DIR/usr/sbin/busybox" ]] || die "dynamic rootfs /usr/sbin/busybox was not installed"
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
