#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

backup_if_changed() {
  local source_file="$1"
  local target_file="$2"

  if [[ ! -f "$target_file" ]] || cmp -s "$source_file" "$target_file"; then
    return
  fi

  local timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"
  cp -- "$target_file" "${target_file}.backup.${timestamp}"
  printf 'Backed up %s\n' "$target_file"
}

install_omp() {
  local source_file="$repo_root/omp/config.yml"
  local target_dir="$HOME/.omp/agent"
  local target_file="$target_dir/config.yml"

  install -d -m 0700 "$target_dir"
  backup_if_changed "$source_file" "$target_file"
  install -m 0600 "$source_file" "$target_file"
  printf 'Installed OMP configuration at %s\n' "$target_file"
}

usage() {
  printf 'Usage: %s [all|omp]\n' "${0##*/}"
}

case "${1:-all}" in
  all)
    install_omp
    ;;
  omp)
    install_omp
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
