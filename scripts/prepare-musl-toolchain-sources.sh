#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=musl-toolchain-common.sh
source "$SCRIPT_DIR/musl-toolchain-common.sh"

for command in cmp find sha1sum sha256sum tar zstd; do
  require_command "$command"
done

SOURCE_WORK_ROOT=${SOURCE_WORK_ROOT:-"$REPO_ROOT/build/musl-toolchain-sources"}
SOURCE_DIST_DIR=${SOURCE_DIST_DIR:-"$REPO_ROOT/dist/musl-toolchain-sources"}
MCM_ROOT="$SOURCE_WORK_ROOT/musl-cross-make"
ARCHIVE_DIR="$REPO_ROOT/archive"
CHECKSUM_FILE="$ARCHIVE_DIR/SHA256SUMS"

case "$SOURCE_WORK_ROOT" in
  "$REPO_ROOT"/build/*) ;;
  *) die "refusing to modify unexpected source work path: $SOURCE_WORK_ROOT" ;;
esac

verify_locked_file() {
  local path=$1
  local relative_path=${path#"$REPO_ROOT"/}
  local checksum_line
  checksum_line=$(grep "  $relative_path\$" "$CHECKSUM_FILE" || true)
  [[ -n "$checksum_line" ]] || die "SHA256 is not locked for $relative_path"
  (
    cd "$REPO_ROOT"
    printf '%s\n' "$checksum_line" | sha256sum -c -
  )
}

remove_verified_duplicate_musl_patches() {
  local patch_dir="$MCM_ROOT/patches/musl-$MUSL_VERSION"
  local duplicate_dir="$patch_dir/t"
  local patch_files
  local duplicate_files
  local patch_name

  [[ -d "$duplicate_dir" ]] || return

  patch_files=$(find "$patch_dir" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
  duplicate_files=$(find "$duplicate_dir" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
  [[ -n "$patch_files" && "$patch_files" == "$duplicate_files" ]] \
    || die "unexpected musl duplicate patch directory contents: $duplicate_dir"

  while IFS= read -r patch_name; do
    cmp -s "$patch_dir/$patch_name" "$duplicate_dir/$patch_name" \
      || die "musl duplicate patch differs from top-level patch: $patch_name"
  done <<< "$patch_files"

  rm -rf "$duplicate_dir"
  echo "removed verified duplicate musl patch directory: $duplicate_dir"
}

rm -rf "$SOURCE_WORK_ROOT"
mkdir -p "$MCM_ROOT" "$SOURCE_DIST_DIR"

(
  cd "$REPO_ROOT"
  sha256sum --ignore-missing -c "$CHECKSUM_FILE"
)

verify_locked_file "$ARCHIVE_DIR/$MUSL_CROSS_MAKE_ARCHIVE"
tar -xzf "$ARCHIVE_DIR/$MUSL_CROSS_MAKE_ARCHIVE" --strip-components=1 -C "$MCM_ROOT"
remove_verified_duplicate_musl_patches

LINUX_ARCHIVE="$SOURCE_WORK_ROOT/linux-$LINUX_VERSION.tar.xz"
cat "$ARCHIVE_DIR/linux-$LINUX_VERSION.tar.xz.part-"* > "$LINUX_ARCHIVE"
linux_checksum=$(grep "  archive/linux-$LINUX_VERSION.tar.xz\$" "$CHECKSUM_FILE" | awk '{print $1}')
[[ -n "$linux_checksum" ]] || die "SHA256 is not locked for reconstructed Linux source"
printf '%s  %s\n' "$linux_checksum" "$LINUX_ARCHIVE" | sha256sum -c -

mkdir -p "$MCM_ROOT/sources"
for archive in \
  "gcc-$GCC_VERSION.tar.xz" \
  "binutils-$BINUTILS_VERSION.tar.gz" \
  "musl-$MUSL_VERSION.tar.gz" \
  "gmp-$GMP_VERSION.tar.xz" \
  "mpc-$MPC_VERSION.tar.gz" \
  "mpfr-$MPFR_VERSION.tar.xz"
do
  verify_locked_file "$ARCHIVE_DIR/$archive"
  cp "$ARCHIVE_DIR/$archive" "$MCM_ROOT/sources/"
done
cp "$LINUX_ARCHIVE" "$MCM_ROOT/sources/"
cp "$TOOLCHAIN_CONFIG_DIR/config.mak" "$MCM_ROOT/config.mak"
cp "$TOOLCHAIN_CONFIG_DIR/versions.env" "$MCM_ROOT/SOURCE_VERSIONS.env"
cp "$CHECKSUM_FILE" "$MCM_ROOT/SOURCE_SHA256SUMS"

for archive in \
  "gcc-$GCC_VERSION.tar.xz" \
  "binutils-$BINUTILS_VERSION.tar.gz" \
  "musl-$MUSL_VERSION.tar.gz" \
  "linux-$LINUX_VERSION.tar.xz" \
  "gmp-$GMP_VERSION.tar.xz" \
  "mpc-$MPC_VERSION.tar.gz" \
  "mpfr-$MPFR_VERSION.tar.xz"
do
  hash_file=$(find "$MCM_ROOT/hashes" -maxdepth 1 -type f -name "$archive.sha1" -print -quit)
  [[ -n "$hash_file" ]] || die "musl-cross-make hash file not found for $archive"
  (
    cd "$MCM_ROOT/sources"
    sha1sum -c "$hash_file"
  )
done

SOURCE_BUNDLE="$SOURCE_DIST_DIR/musl-toolchain-sources-$TOOLCHAIN_RELEASE_ID.tar.zst"
rm -f "$SOURCE_BUNDLE"
tar -I 'zstd -3 -T0' -cf "$SOURCE_BUNDLE" -C "$SOURCE_WORK_ROOT" musl-cross-make
sha256sum "$SOURCE_BUNDLE" > "$SOURCE_BUNDLE.sha256"

write_output source_bundle "$SOURCE_BUNDLE"
write_output source_checksum "$SOURCE_BUNDLE.sha256"
echo "created $SOURCE_BUNDLE"
