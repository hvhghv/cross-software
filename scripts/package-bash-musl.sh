#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
SOFTWARE_NAME=${SOFTWARE_NAME:-bash}
BASH_SOURCE_VERSION=${BASH_SOURCE_VERSION:-5.3}
TARGET_TRIPLET=${TARGET_TRIPLET:?TARGET_TRIPLET is required}
LINKAGE=${LINKAGE:-static}
INSTALL_PREFIX=${INSTALL_PREFIX:?INSTALL_PREFIX is required}
DIST_DIR=${DIST_DIR:-"$REPO_ROOT/dist"}
PACKAGE_NAME=${PACKAGE_NAME:-"$SOFTWARE_NAME-$BASH_SOURCE_VERSION-$TARGET_TRIPLET-$LINKAGE"}

[[ -x "$INSTALL_PREFIX/bin/bash" ]] || die "missing Bash binary"
[[ -f "$INSTALL_PREFIX/BUILD_INFO.txt" ]] || die "missing BUILD_INFO.txt"
grep -qxF 'readline=builtin' "$INSTALL_PREFIX/BUILD_INFO.txt" \
  || die "Bash readline is not recorded as builtin"
grep -qxF 'nls=disabled' "$INSTALL_PREFIX/BUILD_INFO.txt" \
  || die "Bash NLS is not disabled"
if [[ "$LINKAGE" == static ]]; then
  readelf -l "$INSTALL_PREFIX/bin/bash" | grep -q 'Requesting program interpreter' \
    && die "static Bash has an interpreter"
  ! readelf -d "$INSTALL_PREFIX/bin/bash" 2>/dev/null | grep -q '(NEEDED)' \
    || die "static Bash has shared dependencies"
else
  readelf -l "$INSTALL_PREFIX/bin/bash" | grep -q 'Requesting program interpreter' \
    || die "dynamic Bash has no interpreter"
  if readelf -d "$INSTALL_PREFIX/bin/bash" | grep -Eqi 'Shared library: \[(lib(readline|history|termcap|ncurses|tinfo|intl|gettext))'; then
    die "dynamic Bash unexpectedly depends on an external shell UI library"
  fi
fi
if find "$INSTALL_PREFIX" -iname '*busybox*' -o -iname 'libssl*' -o -iname 'libcrypto*' \
  | grep -q .; then
  die "Bash package contains an unrelated runtime dependency"
fi

PACKAGE_ROOT="$DIST_DIR/$PACKAGE_NAME"
PACKAGE_FILE="$DIST_DIR/$PACKAGE_NAME.tar.gz"
CHECKSUM_FILE="$PACKAGE_FILE.sha256"
rm -rf "$PACKAGE_ROOT" "$PACKAGE_FILE" "$CHECKSUM_FILE"
mkdir -p "$DIST_DIR" "$PACKAGE_ROOT"
cp -a "$INSTALL_PREFIX/." "$PACKAGE_ROOT/"
tar --numeric-owner --owner=0 --group=0 -czf "$PACKAGE_FILE" \
  -C "$DIST_DIR" "$PACKAGE_NAME"
(
  cd "$DIST_DIR"
  sha256sum "$(basename "$PACKAGE_FILE")" > "$(basename "$CHECKSUM_FILE")"
)
rm -rf "$PACKAGE_ROOT"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'package_file=%s\nchecksum_file=%s\n' "$PACKAGE_FILE" "$CHECKSUM_FILE" >> "$GITHUB_OUTPUT"
fi
echo "package=$PACKAGE_FILE"
