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

install_git_hooks() {
  if ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'Cannot install hooks: %s is not a Git working tree\n' "$repo_root" >&2
    exit 1
  fi

  git -C "$repo_root" config --local core.hooksPath .githooks
  printf 'Enabled repository hooks from %s/.githooks\n' "$repo_root"
}

install_omp() {
  local config_source="$repo_root/omp/config.yml"
  local mcp_source="$repo_root/omp/mcp.json"
  local target_dir="$HOME/.omp/agent"
  local config_target="$target_dir/config.yml"
  local mcp_target="$target_dir/mcp.json"

  install -d -m 0700 "$target_dir"
  backup_if_changed "$config_source" "$config_target"
  backup_if_changed "$mcp_source" "$mcp_target"
  install -m 0600 "$config_source" "$config_target"
  install -m 0600 "$mcp_source" "$mcp_target"
  printf 'Installed OMP configuration at %s and %s\n' "$config_target" "$mcp_target"
}

usage() {
  printf 'Usage: %s [all|hooks|omp]\n' "${0##*/}"
}

case "${1:-all}" in
  all)
    install_git_hooks
    install_omp
    ;;
  hooks)
    install_git_hooks
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
