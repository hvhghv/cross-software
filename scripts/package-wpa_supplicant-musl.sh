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

require_linkage() {
  local binary=$1
  local interpreter

  interpreter=$(LC_ALL=C readelf -l "$binary" \
    | sed -n 's|.*program interpreter: \([^]]*\)\].*|\1|p' \
    | head -n 1)

  if [[ "$LINKAGE" == static ]]; then
    [[ -z "$interpreter" ]] || die "static binary has an interpreter: $binary"
    if LC_ALL=C readelf -d "$binary" 2>/dev/null | grep -q '(NEEDED)'; then
      die "static binary has a shared-library dependency: $binary"
    fi
  else
    [[ -n "$interpreter" ]] || die "dynamic binary has no interpreter: $binary"
  fi
}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

SOFTWARE_NAME=${SOFTWARE_NAME:-wpa_supplicant}
HOSTAP_VERSION=${HOSTAP_VERSION:-2.12}
TARGET_TRIPLET=${TARGET_TRIPLET:?TARGET_TRIPLET is required}
LINKAGE=${LINKAGE:-static}
INSTALL_PREFIX=${INSTALL_PREFIX:?INSTALL_PREFIX is required}
DIST_DIR=${DIST_DIR:-"$REPO_ROOT/dist"}
PACKAGE_NAME=${PACKAGE_NAME:-"$SOFTWARE_NAME-$HOSTAP_VERSION-$TARGET_TRIPLET-$LINKAGE"}

case "$LINKAGE" in
  static|dynamic) ;;
  *) die "LINKAGE must be static or dynamic, got: $LINKAGE" ;;
esac

BINARIES=(
  usr/sbin/hostapd
  usr/bin/hostapd_cli
  usr/sbin/wpa_supplicant
  usr/bin/wpa_cli
  usr/sbin/dhcpcd
)
for relative_path in "${BINARIES[@]}"; do
  binary="$INSTALL_PREFIX/$relative_path"
  [[ -x "$binary" ]] || die "missing binary: $binary"
  [[ ! -L "$binary" ]] || die "binary must not be a symlink: $binary"
  require_linkage "$binary"
done

[[ -f "$INSTALL_PREFIX/BUILD_INFO.txt" ]] || die "missing BUILD_INFO.txt"
grep -qxF 'dhcpcd_privsep=enabled' "$INSTALL_PREFIX/BUILD_INFO.txt" \
  || die "BUILD_INFO does not record dhcpcd privilege separation"
grep -qxF 'tls=internal' "$INSTALL_PREFIX/BUILD_INFO.txt" \
  || die "BUILD_INFO does not record the internal TLS backend"
grep -qxF 'dhcpcd_openssl=disabled' "$INSTALL_PREFIX/BUILD_INFO.txt" \
  || die "BUILD_INFO does not record disabled dhcpcd OpenSSL support"
grep -qxF 'openssl_runtime_dependency=none' "$INSTALL_PREFIX/BUILD_INFO.txt" \
  || die "BUILD_INFO does not reject an OpenSSL runtime dependency"
grep -qxF 'busybox_runtime_dependency=none' "$INSTALL_PREFIX/BUILD_INFO.txt" \
  || die "BUILD_INFO does not reject a BusyBox runtime dependency"

[[ -f "$INSTALL_PREFIX/etc/dhcpcd.conf" ]] || die "missing dhcpcd.conf"
[[ -x "$INSTALL_PREFIX/usr/libexec/dhcpcd-run-hooks" ]] \
  || die "missing dhcpcd-run-hooks"
[[ -d "$INSTALL_PREFIX/usr/libexec/dhcpcd-hooks" ]] \
  || die "missing dhcpcd-hooks directory"
sh -n "$INSTALL_PREFIX/usr/libexec/dhcpcd-run-hooks"
for hook in "$INSTALL_PREFIX/usr/libexec/dhcpcd-hooks/"*; do
  [[ -f "$hook" ]] || continue
  sh -n "$hook"
done

if find "$INSTALL_PREFIX" -iname '*busybox*' -print -quit | grep -q .; then
  die "install prefix contains a BusyBox file"
fi
if find "$INSTALL_PREFIX" \
  \( -iname 'libssl*' -o -iname 'libcrypto*' -o -iname '*openssl*' \) \
  -print -quit | grep -q .; then
  die "install prefix contains an OpenSSL runtime file"
fi
for relative_path in "${BINARIES[@]}"; do
  binary="$INSTALL_PREFIX/$relative_path"
  if LC_ALL=C readelf -d "$binary" 2>/dev/null \
    | grep -Eqi 'Shared library: \[lib(ssl|crypto)\.so'; then
    die "binary has an OpenSSL runtime dependency: $binary"
  fi
done

if [[ "$LINKAGE" == dynamic ]]; then
  find "$INSTALL_PREFIX/usr/lib" -maxdepth 1 -type f -name 'libnl-3.so.*' -print -quit | grep -q . \
    || die "dynamic package is missing libnl runtime"
  find "$INSTALL_PREFIX/usr/lib" -maxdepth 1 -type f -name 'libnl-genl-3.so.*' -print -quit | grep -q . \
    || die "dynamic package is missing libnl-genl runtime"
  LC_ALL=C readelf -d "$INSTALL_PREFIX/usr/sbin/hostapd" \
    | grep -q 'libnl-3.so' || die "hostapd does not depend on shared libnl"
  LC_ALL=C readelf -d "$INSTALL_PREFIX/usr/sbin/wpa_supplicant" \
    | grep -q 'libnl-3.so' || die "wpa_supplicant does not depend on shared libnl"
  while IFS= read -r -d '' library; do
    target=$(readlink "$library")
    case "$target" in
      /*) die "absolute runtime library symlink: $library -> $target" ;;
    esac
    [[ -f "$library" ]] || die "broken runtime library symlink: $library -> $target"
  done < <(find "$INSTALL_PREFIX/usr/lib" -maxdepth 1 -type l -print0)
else
  if find "$INSTALL_PREFIX/usr/lib" -mindepth 1 -print -quit | grep -q .; then
    die "static package unexpectedly contains runtime libraries"
  fi
fi

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
