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

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

SOFTWARE_NAME=${SOFTWARE_NAME:-wireless-tools}
HOSTAP_VERSION=${HOSTAP_VERSION:-2.12}
LIBNL_VERSION=${LIBNL_VERSION:-3.12.0}
DHCPCD_VERSION=${DHCPCD_VERSION:-10.5.0}
TARGET_TRIPLET=${TARGET_TRIPLET:?TARGET_TRIPLET is required}
TARGET_ARCH=${TARGET_ARCH:-$TARGET_TRIPLET}
LINKAGE=${LINKAGE:-static}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}

case "$LINKAGE" in
  static|dynamic) ;;
  *) die "LINKAGE must be static or dynamic, got: $LINKAGE" ;;
esac

ARCHIVE_DIR=${ARCHIVE_DIR:-"$REPO_ROOT/archive"}
BUILD_ROOT=${BUILD_ROOT:-"$REPO_ROOT/build/$SOFTWARE_NAME-$HOSTAP_VERSION-$TARGET_TRIPLET-$LINKAGE"}
SRC_ROOT="$BUILD_ROOT/src"
DEPS_PREFIX="$BUILD_ROOT/deps"
INSTALL_PREFIX="$BUILD_ROOT/install"

HOSTAPD_ARCHIVE="$ARCHIVE_DIR/hostapd-$HOSTAP_VERSION.tar.gz"
WPA_SUPPLICANT_ARCHIVE="$ARCHIVE_DIR/wpa_supplicant-$HOSTAP_VERSION.tar.gz"
LIBNL_ARCHIVE="$ARCHIVE_DIR/libnl-$LIBNL_VERSION.tar.gz"
DHCPCD_ARCHIVE="$ARCHIVE_DIR/dhcpcd-$DHCPCD_VERSION.tar.xz"

for source_file in \
  "$HOSTAPD_ARCHIVE" \
  "$WPA_SUPPLICANT_ARCHIVE" \
  "$LIBNL_ARCHIVE" \
  "$DHCPCD_ARCHIVE"; do
  [[ -f "$source_file" ]] || die "missing source input: $source_file"
done

if command -v sha256sum >/dev/null 2>&1 && [[ -f "$ARCHIVE_DIR/SHA256SUMS" ]]; then
  (cd "$REPO_ROOT" && sha256sum --ignore-missing -c archive/SHA256SUMS)
fi

CC=$(resolve_tool "${MUSL_CC:-$TARGET_TRIPLET-gcc}")
AR=$(resolve_tool "${MUSL_AR:-$TARGET_TRIPLET-ar}")
RANLIB=$(resolve_tool "${MUSL_RANLIB:-$TARGET_TRIPLET-ranlib}")
STRIP=$(resolve_tool "${MUSL_STRIP:-$TARGET_TRIPLET-strip}")
PKG_CONFIG=$(resolve_tool "${PKG_CONFIG:-pkg-config}")

rm -rf "$BUILD_ROOT"
mkdir -p "$SRC_ROOT" "$DEPS_PREFIX" \
  "$INSTALL_PREFIX/usr/bin" "$INSTALL_PREFIX/usr/sbin" "$INSTALL_PREFIX/usr/lib"

tar -xf "$HOSTAPD_ARCHIVE" -C "$SRC_ROOT"
tar -xf "$WPA_SUPPLICANT_ARCHIVE" -C "$SRC_ROOT"
tar -xf "$LIBNL_ARCHIVE" -C "$SRC_ROOT"
tar -xf "$DHCPCD_ARCHIVE" -C "$SRC_ROOT"

HOSTAPD_SRC="$SRC_ROOT/hostapd-$HOSTAP_VERSION"
WPA_SUPPLICANT_SRC="$SRC_ROOT/wpa_supplicant-$HOSTAP_VERSION"
LIBNL_SRC="$SRC_ROOT/libnl-$LIBNL_VERSION"
DHCPCD_SRC="$SRC_ROOT/dhcpcd-$DHCPCD_VERSION"

for source_dir in \
  "$HOSTAPD_SRC" \
  "$WPA_SUPPLICANT_SRC" \
  "$LIBNL_SRC" \
  "$DHCPCD_SRC"; do
  [[ -d "$source_dir" ]] || die "extracted source directory not found: $source_dir"
done

echo "software=$SOFTWARE_NAME"
echo "hostap_version=$HOSTAP_VERSION"
echo "libnl_version=$LIBNL_VERSION"
echo "dhcpcd_version=$DHCPCD_VERSION"
echo "target=$TARGET_TRIPLET"
echo "arch=$TARGET_ARCH"
echo "linkage=$LINKAGE"
echo "cc=$CC"
echo "jobs=$JOBS"

BUILD_TRIPLET=${BUILD_TRIPLET:-$(sh "$LIBNL_SRC/build-aux/config.guess")}
COMMON_CFLAGS=${COMMON_CFLAGS:--Os -pipe}

LIBNL_CONFIGURE_FLAGS=(
  --build="$BUILD_TRIPLET"
  --host="$TARGET_TRIPLET"
  --prefix="$DEPS_PREFIX/usr"
  --libdir="$DEPS_PREFIX/usr/lib"
  --disable-cli
  --disable-pthreads
)
if [[ "$LINKAGE" == static ]]; then
  LIBNL_CONFIGURE_FLAGS+=(--enable-static --disable-shared)
else
  LIBNL_CONFIGURE_FLAGS+=(--enable-shared --disable-static)
fi

(
  cd "$LIBNL_SRC"
  CC="$CC" AR="$AR" RANLIB="$RANLIB" \
    CFLAGS="$COMMON_CFLAGS" \
    ./configure "${LIBNL_CONFIGURE_FLAGS[@]}"
  make -j "$JOBS"
  make install
)

if [[ "$LINKAGE" == static ]]; then
  [[ -f "$DEPS_PREFIX/usr/lib/libnl-3.a" ]] || die "static libnl was not installed"
  [[ -f "$DEPS_PREFIX/usr/lib/libnl-genl-3.a" ]] || die "static libnl-genl was not installed"
else
  find "$DEPS_PREFIX/usr/lib" -maxdepth 1 -type f -name 'libnl-3.so.*' -print -quit | grep -q . \
    || die "shared libnl was not installed"
  find "$DEPS_PREFIX/usr/lib" -maxdepth 1 -type f -name 'libnl-genl-3.so.*' -print -quit | grep -q . \
    || die "shared libnl-genl was not installed"
fi

cat > "$HOSTAPD_SRC/hostapd/.config" <<'EOF'
CONFIG_DRIVER_NL80211=y
CONFIG_DRIVER_WIRED=y
CONFIG_LIBNL32=y
CONFIG_IEEE80211N=y
CONFIG_IEEE80211AC=y
CONFIG_IEEE80211AX=y
CONFIG_IEEE80211BE=y
CONFIG_IEEE80211W=y
CONFIG_WPS=y
CONFIG_ACS=y
CONFIG_TLS=internal
CONFIG_INTERNAL_LIBTOMMATH=y
CONFIG_INTERNAL_LIBTOMMATH_FAST=y
CONFIG_GETRANDOM=y
EOF

cat > "$WPA_SUPPLICANT_SRC/wpa_supplicant/.config" <<'EOF'
CONFIG_DRIVER_NL80211=y
CONFIG_DRIVER_WEXT=y
CONFIG_DRIVER_WIRED=y
CONFIG_LIBNL32=y
CONFIG_CTRL_IFACE=y
CONFIG_BACKEND=file
CONFIG_WPA_CLI_EDIT=y
CONFIG_IEEE80211W=y
CONFIG_WPS=y
CONFIG_AP=y
CONFIG_P2P=y
CONFIG_IBSS_RSN=y
CONFIG_SME=y
CONFIG_EAP_TLS=y
CONFIG_EAP_PEAP=y
CONFIG_EAP_TTLS=y
CONFIG_EAP_MSCHAPV2=y
CONFIG_EAP_GTC=y
CONFIG_EAP_OTP=y
CONFIG_EAP_MD5=y
CONFIG_TLS=internal
CONFIG_INTERNAL_LIBTOMMATH=y
CONFIG_INTERNAL_LIBTOMMATH_FAST=y
CONFIG_GETRANDOM=y
EOF

PKG_CONFIG_PATH="$DEPS_PREFIX/usr/lib/pkgconfig"
export PKG_CONFIG_PATH
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
LIBNL_INC="$DEPS_PREFIX/usr/include/libnl3"
FINAL_LDFLAGS="-L$DEPS_PREFIX/usr/lib -Wl,--gc-sections"
PKG_CONFIG_COMMAND="$PKG_CONFIG"
if [[ "$LINKAGE" == static ]]; then
  FINAL_LDFLAGS="-static $FINAL_LDFLAGS"
  PKG_CONFIG_COMMAND="$PKG_CONFIG --static"
fi

HOSTAP_MAKE_ARGS=(
  "CC=$CC"
  "LIBNL_INC=$LIBNL_INC"
  "PKG_CONFIG=$PKG_CONFIG_COMMAND"
  "EXTRA_CFLAGS=$COMMON_CFLAGS -ffunction-sections -fdata-sections"
  "LDFLAGS=$FINAL_LDFLAGS"
)

make -C "$HOSTAPD_SRC/hostapd" -j "$JOBS" "${HOSTAP_MAKE_ARGS[@]}" hostapd hostapd_cli
make -C "$WPA_SUPPLICANT_SRC/wpa_supplicant" -j "$JOBS" \
  "${HOSTAP_MAKE_ARGS[@]}" wpa_supplicant wpa_cli

cp "$HOSTAPD_SRC/hostapd/hostapd" "$INSTALL_PREFIX/usr/sbin/hostapd"
cp "$HOSTAPD_SRC/hostapd/hostapd_cli" "$INSTALL_PREFIX/usr/bin/hostapd_cli"
cp "$WPA_SUPPLICANT_SRC/wpa_supplicant/wpa_supplicant" "$INSTALL_PREFIX/usr/sbin/wpa_supplicant"
cp "$WPA_SUPPLICANT_SRC/wpa_supplicant/wpa_cli" "$INSTALL_PREFIX/usr/bin/wpa_cli"

DHCPCD_CONFIGURE_FLAGS=(
  --build="$BUILD_TRIPLET"
  --host="$TARGET_TRIPLET"
  --target="$TARGET_TRIPLET"
  --prefix=/usr
  --sysconfdir=/etc
  --sbindir=/usr/sbin
  --libexecdir=/usr/libexec
  --dbdir=/var/lib/dhcpcd
  --rundir=/run/dhcpcd
  --privsepuser=dhcpcd
  --without-udev
  --without-openssl
  --with-hooks=
  --with-eghooks=
)
if [[ "$LINKAGE" == static ]]; then
  DHCPCD_CONFIGURE_FLAGS+=(--enable-static)
else
  DHCPCD_CONFIGURE_FLAGS+=(--disable-static)
fi

DHCPCD_STAGE="$BUILD_ROOT/dhcpcd-stage"
mkdir -p "$DHCPCD_STAGE"
(
  cd "$DHCPCD_SRC"
  CC="$CC" AR="$AR" RANLIB="$RANLIB" \
    CFLAGS="$COMMON_CFLAGS" \
    ./configure "${DHCPCD_CONFIGURE_FLAGS[@]}"
  make -j "$JOBS"
  make DESTDIR="$DHCPCD_STAGE" install
)

[[ -x "$DHCPCD_STAGE/usr/sbin/dhcpcd" ]] || die "dhcpcd was not installed"
[[ -x "$DHCPCD_STAGE/usr/libexec/dhcpcd-run-hooks" ]] \
  || die "dhcpcd-run-hooks was not installed"
[[ -f "$DHCPCD_STAGE/etc/dhcpcd.conf" ]] || die "dhcpcd.conf was not installed"

cp "$DHCPCD_STAGE/usr/sbin/dhcpcd" "$INSTALL_PREFIX/usr/sbin/dhcpcd"
mkdir -p "$INSTALL_PREFIX/etc" "$INSTALL_PREFIX/usr/libexec"
cp "$DHCPCD_STAGE/etc/dhcpcd.conf" "$INSTALL_PREFIX/etc/dhcpcd.conf"
cp -a "$DHCPCD_STAGE/usr/libexec/dhcpcd-run-hooks" "$INSTALL_PREFIX/usr/libexec/"
cp -a "$DHCPCD_STAGE/usr/libexec/dhcpcd-hooks" "$INSTALL_PREFIX/usr/libexec/"
if [[ -d "$DHCPCD_STAGE/usr/share/dhcpcd" ]]; then
  mkdir -p "$INSTALL_PREFIX/usr/share"
  cp -a "$DHCPCD_STAGE/usr/share/dhcpcd" "$INSTALL_PREFIX/usr/share/"
fi

if [[ "$LINKAGE" == dynamic ]]; then
  while IFS= read -r -d '' library; do
    cp -a "$library" "$INSTALL_PREFIX/usr/lib/"
  done < <(
    find "$DEPS_PREFIX/usr/lib" -maxdepth 1 \
      \( -name 'libnl-3.so*' -o -name 'libnl-genl-3.so*' \) -print0
  )
fi

for binary in \
  "$INSTALL_PREFIX/usr/sbin/hostapd" \
  "$INSTALL_PREFIX/usr/bin/hostapd_cli" \
  "$INSTALL_PREFIX/usr/sbin/wpa_supplicant" \
  "$INSTALL_PREFIX/usr/bin/wpa_cli" \
  "$INSTALL_PREFIX/usr/sbin/dhcpcd"; do
  [[ -x "$binary" ]] || die "binary was not installed: $binary"
  [[ ! -L "$binary" ]] || die "binary must not be a symlink: $binary"
  "$STRIP" "$binary" || true
done

if find "$INSTALL_PREFIX" -iname '*busybox*' -print -quit | grep -q .; then
  die "wireless tools package unexpectedly contains a BusyBox file"
fi

cat > "$INSTALL_PREFIX/BUILD_INFO.txt" <<EOF
software=$SOFTWARE_NAME
hostap_version=$HOSTAP_VERSION
libnl_version=$LIBNL_VERSION
dhcpcd_version=$DHCPCD_VERSION
target=$TARGET_TRIPLET
arch=$TARGET_ARCH
linkage=$LINKAGE
binaries=hostapd hostapd_cli wpa_supplicant wpa_cli dhcpcd
wireless_driver=nl80211
tls=internal
wpa3_sae=disabled
owe=disabled
dpp=disabled
dhcpcd_privsep=enabled
dhcpcd_privsep_user=dhcpcd
dhcpcd_udev=disabled
dhcpcd_openssl=disabled
openssl_runtime_dependency=none
busybox_runtime_dependency=none
EOF

write_output install_prefix "$INSTALL_PREFIX"
write_output hostapd_bin "$INSTALL_PREFIX/usr/sbin/hostapd"
write_output hostapd_cli_bin "$INSTALL_PREFIX/usr/bin/hostapd_cli"
write_output wpa_supplicant_bin "$INSTALL_PREFIX/usr/sbin/wpa_supplicant"
write_output wpa_cli_bin "$INSTALL_PREFIX/usr/bin/wpa_cli"
write_output dhcpcd_bin "$INSTALL_PREFIX/usr/sbin/dhcpcd"
write_output runtime_lib_dir "$INSTALL_PREFIX/usr/lib"

echo "installed to $INSTALL_PREFIX"
