#!/usr/bin/env bash
# Tests for the shell profile of install.sh. The shell command must write
# ~/.docks_profile (the shared profile with the OS part in place of the
# @os-profile@ line), back up an existing rc file, append one marked block,
# keep the original rc content, and change nothing on a second run. A changed
# ~/.docks_profile is replaced without a backup (the repository is its
# source). The profile must load in bash
# and in a POSIX sh, and must keep the PATH precedence
# bun > pnpm > ~/.local/bin. The test never deletes files; it leaves its work
# directory in TMPDIR.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/shell-profile.XXXXXX")"
marker='# >>> docks profile >>>'
failures=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

# Run the shell command of install.sh for one OS in a clean environment.
wire() {
  local home="$1" os="$2"

  env -i HOME="$home" PATH=/usr/bin:/bin TERM=dumb DOTFILES_OS="$os" \
    "$repo_root/install.sh" shell >"$home.log" 2>&1 ||
    fail "install.sh shell exited non-zero for $os (see $home.log)"
}

count_markers() {
  grep -cFx -- "$marker" "$1" || true
}

count_backups() {
  local count=0 file

  for file in "$1".backup.*; do
    [ -e "$file" ] && count=$((count + 1))
  done
  printf '%s\n' "$count"
}

# The generated profile holds the OS part and no splice marker.
check_profile_file() {
  local os="$1" profile="$2" os_line="$3"

  [ -f "$profile" ] || {
    fail "$os: ~/.docks_profile was not written"
    return 0
  }
  if grep -qFx '# @os-profile@' "$profile"; then
    fail "$os: ~/.docks_profile still holds the @os-profile@ marker"
  fi
  grep -qF -- "$os_line" "$profile" || fail "$os: ~/.docks_profile lacks the OS part ($os_line)"
}

test_ubuntu_wiring() {
  local home="$work/ubuntu" rc profile rc_snapshot profile_snapshot

  mkdir -p "$home"
  rc="$home/.bashrc"
  profile="$home/.docks_profile"
  printf '%s\n' '# original line' 'alias keep=true' >"$rc"
  wire "$home" ubuntu

  # shellcheck disable=SC2016  # The literal profile text contains $HOME.
  check_profile_file ubuntu "$profile" 'PNPM_HOME="$HOME/.local/share/pnpm"'
  [ "$(count_markers "$rc")" = 1 ] || fail 'ubuntu: the block is not in .bashrc exactly once'
  # shellcheck disable=SC2016  # The literal rc block contains $HOME.
  grep -qF '. "$HOME/.docks_profile"' "$rc" || fail 'ubuntu: the block does not source ~/.docks_profile'
  if grep -qF "$repo_root" "$rc"; then
    fail 'ubuntu: the rc block must not point at the repository'
  fi
  [ "$(head -n 2 "$rc")" = "$(printf '%s\n' '# original line' 'alias keep=true')" ] ||
    fail 'ubuntu: the original .bashrc content changed'
  [ "$(count_backups "$rc")" = 1 ] || fail 'ubuntu: expected exactly one backup of .bashrc'
  for backup in "$rc".backup.*; do
    [ "$(cat "$backup")" = "$(printf '%s\n' '# original line' 'alias keep=true')" ] ||
      fail 'ubuntu: the backup does not hold the original content'
  done
  [ ! -e "$home/.bash_profile" ] || fail 'ubuntu: .bash_profile must not be created (it hides .profile)'

  rc_snapshot="$work/ubuntu-bashrc.snapshot"
  profile_snapshot="$work/ubuntu-profile.snapshot"
  cp -p "$rc" "$rc_snapshot"
  cp -p "$profile" "$profile_snapshot"
  sleep 1
  wire "$home" ubuntu
  cmp -s "$rc" "$rc_snapshot" || fail 'ubuntu: a second run changed .bashrc'
  cmp -s "$profile" "$profile_snapshot" || fail 'ubuntu: a second run changed ~/.docks_profile'
  [ "$(count_backups "$rc")" = 1 ] || fail 'ubuntu: a second run made another backup of .bashrc'
  [ "$(count_backups "$profile")" = 0 ] || fail 'ubuntu: an unchanged ~/.docks_profile got a backup'

  # A hand edit is replaced by the repository profile. The profile is a
  # generated file, so the replacement makes no backup.
  printf '%s\n' 'export LOCAL_EDIT=1' >>"$profile"
  sleep 1
  wire "$home" ubuntu
  cmp -s "$profile" "$profile_snapshot" || fail 'ubuntu: a changed ~/.docks_profile was not replaced'
  [ "$(count_backups "$profile")" = 0 ] || fail 'ubuntu: the generated ~/.docks_profile got a backup'
}

test_macos_wiring() {
  local home="$work/macos" rc

  mkdir -p "$home"
  wire "$home" macos
  # shellcheck disable=SC2016  # The literal profile text contains $HOME.
  check_profile_file macos "$home/.docks_profile" 'PNPM_HOME="$HOME/Library/pnpm"'
  for rc in "$home/.zshrc" "$home/.bash_profile"; do
    [ "$(count_markers "$rc")" = 1 ] || fail "macos: the block is not in ${rc##*/} exactly once"
    [ "$(count_backups "$rc")" = 0 ] || fail "macos: a new ${rc##*/} must not get a backup"
  done
  wire "$home" macos
  for rc in "$home/.zshrc" "$home/.bash_profile"; do
    [ "$(count_markers "$rc")" = 1 ] || fail "macos: a second run added another block to ${rc##*/}"
  done
}

# Load the wired rc file in a clean shell and print PATH.
profile_path() {
  local shell="$1" home="$2" rc="$3"

  # shellcheck disable=SC2016  # The child shell expands HOME, RC, and PATH.
  env -i HOME="$home" RC="$rc" PATH=/usr/bin:/bin TERM=dumb \
    "$shell" -c '. "$HOME/$RC" && printf "%s\n" "$PATH"'
}

# Print the position of a directory in PATH (1 = first), or 0 when absent.
path_position() {
  local path="$1" dir="$2" index=0 entry

  while IFS= read -r entry; do
    index=$((index + 1))
    if [ "$entry" = "$dir" ]; then
      printf '%s\n' "$index"
      return 0
    fi
  done < <(printf '%s\n' "$path" | tr ':' '\n')
  printf '0\n'
}

# The profile of the host OS must load from the home directory alone.
test_profile_loads() {
  local home rc shell path bun pnpm local_bin pnpm_home

  case "$(uname -s)" in
    Darwin)
      home="$work/macos"
      rc=.zshrc
      pnpm_home="$home/Library/pnpm"
      ;;
    *)
      home="$work/ubuntu"
      rc=.bashrc
      pnpm_home="$home/.local/share/pnpm"
      ;;
  esac
  mkdir -p "$home/.bun/bin" "$pnpm_home/bin" "$home/.local/bin"
  for shell in bash dash zsh; do
    if ! command -v "$shell" >/dev/null 2>&1; then
      printf 'SKIP: profile under %s (not installed)\n' "$shell"
      continue
    fi
    if ! path="$(profile_path "$shell" "$home" "$rc")"; then
      fail "profile: $shell exited non-zero while it loaded the profile"
      continue
    fi
    bun="$(path_position "$path" "$home/.bun/bin")"
    pnpm="$(path_position "$path" "$pnpm_home/bin")"
    local_bin="$(path_position "$path" "$home/.local/bin")"
    if [ "$bun" = 0 ] || [ "$pnpm" = 0 ] || [ "$local_bin" = 0 ]; then
      fail "profile: $shell PATH lacks a user bin directory: $path"
    elif [ "$bun" -ge "$pnpm" ] || [ "$pnpm" -ge "$local_bin" ]; then
      fail "profile: $shell PATH order is not bun > pnpm > ~/.local/bin: $path"
    fi
  done
}

test_ubuntu_wiring
test_macos_wiring
test_profile_loads

printf 'Work directory (kept, not deleted): %s\n' "$work"
if [ "$failures" -ne 0 ]; then
  printf '%s shell profile check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'shell profile tests passed\n'
