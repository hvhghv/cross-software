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

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

SOFTWARE_NAME=${SOFTWARE_NAME:-dropbear}
DROPBEAR_VERSION=${DROPBEAR_VERSION:-2026.92}
TARGET_TRIPLET=${TARGET_TRIPLET:?TARGET_TRIPLET is required}
TARGET_ARCH=${TARGET_ARCH:-$TARGET_TRIPLET}
LINKAGE=${LINKAGE:-static}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}

case "$LINKAGE" in
  static|dynamic) ;;
  *) die "LINKAGE must be static or dynamic, got: $LINKAGE" ;;
esac

ARCHIVE_DIR=${ARCHIVE_DIR:-"$REPO_ROOT/archive"}
BUILD_ROOT=${BUILD_ROOT:-"$REPO_ROOT/build/$SOFTWARE_NAME-$DROPBEAR_VERSION-$TARGET_TRIPLET-$LINKAGE"}
SRC_ROOT="$BUILD_ROOT/src"
INSTALL_PREFIX="$BUILD_ROOT/install"

DROPBEAR_ARCHIVE="$ARCHIVE_DIR/dropbear-$DROPBEAR_VERSION.tar.bz2"
DROPBEAR_PROGRAMS=${DROPBEAR_PROGRAMS:-"dropbear dbclient dropbearkey dropbearconvert scp"}

[[ -f "$DROPBEAR_ARCHIVE" ]] || die "missing Dropbear archive: $DROPBEAR_ARCHIVE"

if command -v sha256sum >/dev/null 2>&1 && [[ -f "$ARCHIVE_DIR/SHA256SUMS" ]]; then
  (cd "$REPO_ROOT" && sha256sum --ignore-missing -c archive/SHA256SUMS)
fi

rm -rf "$BUILD_ROOT"
mkdir -p "$SRC_ROOT" "$INSTALL_PREFIX"

tar -xf "$DROPBEAR_ARCHIVE" -C "$SRC_ROOT"
DROPBEAR_SRC="$SRC_ROOT/dropbear-$DROPBEAR_VERSION"
[[ -d "$DROPBEAR_SRC" ]] || die "extracted Dropbear source not found: $DROPBEAR_SRC"

CC=$(resolve_tool "${MUSL_CC:-$TARGET_TRIPLET-gcc}")
AR=$(resolve_tool "${MUSL_AR:-$TARGET_TRIPLET-ar}")
RANLIB=$(resolve_tool "${MUSL_RANLIB:-$TARGET_TRIPLET-ranlib}")
STRIP=$(resolve_tool "${MUSL_STRIP:-$TARGET_TRIPLET-strip}")

export CC AR RANLIB
BUILD_TRIPLET=${BUILD_TRIPLET:-$(sh "$DROPBEAR_SRC/src/config.guess")}
COMMON_CFLAGS=${COMMON_CFLAGS:--Os -pipe}
DROPBEAR_CFLAGS=${DROPBEAR_CFLAGS:-$COMMON_CFLAGS}
DROPBEAR_LDFLAGS=${DROPBEAR_LDFLAGS:-}
CONFIGURE_STATIC_FLAG=()

if [[ "$LINKAGE" == static ]]; then
  CONFIGURE_STATIC_FLAG=(--enable-static)
fi

cat > "$DROPBEAR_SRC/localoptions.h" <<'EOF'
#ifndef LOCALOPTIONS_H
#define LOCALOPTIONS_H

#undef DROPBEAR_PATH_SSH_PROGRAM
#define DROPBEAR_PATH_SSH_PROGRAM "dbclient"

#endif
EOF

echo "software=$SOFTWARE_NAME"
echo "version=$DROPBEAR_VERSION"
echo "target=$TARGET_TRIPLET"
echo "arch=$TARGET_ARCH"
echo "linkage=$LINKAGE"
echo "build=$BUILD_TRIPLET"
echo "cc=$CC"
echo "jobs=$JOBS"
echo "programs=$DROPBEAR_PROGRAMS"

(
  cd "$DROPBEAR_SRC"
  CFLAGS="$DROPBEAR_CFLAGS" \
  LDFLAGS="$DROPBEAR_LDFLAGS" \
  ./configure \
    --build="$BUILD_TRIPLET" \
    --host="$TARGET_TRIPLET" \
    --prefix="$INSTALL_PREFIX" \
    --disable-zlib \
    "${CONFIGURE_STATIC_FLAG[@]}"

  make -j "$JOBS" PROGRAMS="$DROPBEAR_PROGRAMS" SCPPROGRESS=1
  make PROGRAMS="$DROPBEAR_PROGRAMS" SCPPROGRESS=1 install
)

DROPBEAR_BIN="$INSTALL_PREFIX/sbin/dropbear"
DBCLIENT_BIN="$INSTALL_PREFIX/bin/dbclient"
DROPBEARKEY_BIN="$INSTALL_PREFIX/bin/dropbearkey"
DROPBEARCONVERT_BIN="$INSTALL_PREFIX/bin/dropbearconvert"
SCP_BIN="$INSTALL_PREFIX/bin/scp"

[[ -x "$DROPBEAR_BIN" ]] || die "dropbear was not installed"
[[ -x "$DBCLIENT_BIN" ]] || die "dbclient was not installed"
[[ -x "$DROPBEARKEY_BIN" ]] || die "dropbearkey was not installed"
[[ -x "$DROPBEARCONVERT_BIN" ]] || die "dropbearconvert was not installed"
[[ -x "$SCP_BIN" ]] || die "scp was not installed"

if [[ "${STRIP_BINARIES:-1}" == "1" ]]; then
  "$STRIP" "$DROPBEAR_BIN" "$DBCLIENT_BIN" "$DROPBEARKEY_BIN" "$DROPBEARCONVERT_BIN" "$SCP_BIN" || true
fi

cat > "$INSTALL_PREFIX/BUILD_INFO.txt" <<EOF
software=$SOFTWARE_NAME
version=$DROPBEAR_VERSION
target=$TARGET_TRIPLET
arch=$TARGET_ARCH
linkage=$LINKAGE
build=$BUILD_TRIPLET
binaries=dropbear dbclient dropbearkey dropbearconvert scp
scp_ssh_program=dbclient
zlib=disabled
EOF

write_output install_prefix "$INSTALL_PREFIX"
write_output dropbear_bin "$DROPBEAR_BIN"
write_output dbclient_bin "$DBCLIENT_BIN"
write_output dropbearkey_bin "$DROPBEARKEY_BIN"
write_output dropbearconvert_bin "$DROPBEARCONVERT_BIN"
write_output scp_bin "$SCP_BIN"

echo "installed to $INSTALL_PREFIX"
