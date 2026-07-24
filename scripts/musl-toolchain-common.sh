#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
TOOLCHAIN_CONFIG_DIR="$REPO_ROOT/toolchains/musl-gcc"

# shellcheck source=../toolchains/musl-gcc/versions.env
source "$TOOLCHAIN_CONFIG_DIR/versions.env"

die() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

write_output() {
  local name=$1
  local value=$2
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
  fi
}

validate_target() {
  case "$1" in
    x86_64-linux-musl|arm-linux-musleabi|aarch64-linux-musl|riscv64-linux-musl)
      ;;
    *)
      die "unsupported musl target: $1"
      ;;
  esac
}

target_asset_arch() {
  case "$1" in
    x86_64-linux-musl) echo x86_64 ;;
    arm-linux-musleabi) echo arm ;;
    aarch64-linux-musl) echo aarch64 ;;
    riscv64-linux-musl) echo riscv64 ;;
    *) die "unsupported musl target: $1" ;;
  esac
}

target_machine_pattern() {
  case "$1" in
    x86_64-linux-musl) echo 'Advanced Micro Devices X86-64' ;;
    arm-linux-musleabi) echo 'ARM' ;;
    aarch64-linux-musl) echo 'AArch64' ;;
    riscv64-linux-musl) echo 'RISC-V' ;;
    *) die "unsupported musl target: $1" ;;
  esac
}

guard_toolchain_work_root() {
  local path=$1
  case "$path" in
    "$REPO_ROOT"/build/musl-toolchain/*) ;;
    *) die "refusing to modify unexpected toolchain work path: $path" ;;
  esac
}

stage_work_root() {
  local target=$1
  echo "$REPO_ROOT/build/musl-toolchain/$target"
}

stage_mcm_root() {
  local target=$1
  echo "$(stage_work_root "$target")/musl-cross-make"
}

stage_build_root() {
  local target=$1
  echo "$(stage_mcm_root "$target")/build/local/$target"
}

restore_stage_archive() {
  local target=$1
  local archive=$2
  local work_root
  work_root=$(stage_work_root "$target")
  guard_toolchain_work_root "$work_root"
  [[ -f "$archive" ]] || die "stage archive not found: $archive"
  rm -rf "$work_root"
  tar -I zstd -xf "$archive" -C "$REPO_ROOT"
  [[ -d "$(stage_build_root "$target")" ]] || die "restored stage is missing build directory"
}

create_stage_archive() {
  local target=$1
  local stage=$2
  local work_root
  local archive
  work_root=$(stage_work_root "$target")
  archive="$REPO_ROOT/dist/musl-toolchain-stages/$stage-$target.tar.zst"
  [[ -d "$work_root" ]] || die "stage work directory not found: $work_root"
  mkdir -p "$(dirname "$archive")"
  rm -f "$archive"
  tar -I 'zstd -1 -T0' -cf "$archive" -C "$REPO_ROOT" "build/musl-toolchain/$target"
  write_output stage_archive "$archive"
  echo "created $archive"
}
