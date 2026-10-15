#!/usr/bin/env bash
# Dry-run tests for install.sh on Ubuntu and on a mocked macOS.
# A dry-run must not change anything: stubs for sudo, apt-get, and brew
# record each call that would change the system, and the test home must stay
# empty. The test never deletes files; it leaves its work directory in TMPDIR.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/install-dry-run.XXXXXX")"
failures=0

# The version check of the installer, so the skip below uses the same rule.
# shellcheck source=../lib/platform.sh
. "$repo_root/lib/platform.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

# A stub that records its arguments in the marker file and fails.
write_marker_stub() {
  local path="$1" marker="$2"

  # shellcheck disable=SC2016  # $0 and $* belong to the stub, not to this script.
  printf '#!/bin/sh\nprintf "%%s\\n" "$0 $*" >> "%s"\nexit 1\n' "$marker" >"$path"
  chmod +x "$path"
}

# A curl stub with canned GitHub API answers, so the test needs no network.
write_curl_stub() {
  cat >"$1" <<'EOF'
#!/bin/sh
for arg in "$@"; do url="$arg"; done
case "$url" in
  https://api.github.com/repos/nvm-sh/nvm/releases/latest) printf '{"tag_name": "v0.40.8"}\n' ;;
  https://api.github.com/repos/rustdesk/rustdesk/releases/latest) printf '{"tag_name": "9.9.9"}\n' ;;
  *) exit 22 ;;
esac
EOF
  chmod +x "$1"
}

# A brew stub: no formula or cask is installed, and every change is recorded.
write_brew_stub() {
  local path="$1" marker="$2"

  cat >"$path" <<EOF
#!/bin/sh
case "\$1" in
  list) exit 1 ;;
  shellenv) exit 0 ;;
  --prefix) printf '/opt/homebrew\n' ;;
  *) printf '%s\n' "brew \$*" >> "$marker"; exit 1 ;;
esac
EOF
  chmod +x "$path"
}

new_case() {
  local name="$1"

  case_dir="$work/$name"
  case_home="$case_dir/home"
  case_bin="$case_dir/bin"
  case_marker="$case_dir/changes.log"
  case_out="$case_dir/output.log"
  mkdir -p "$case_home" "$case_bin"
  write_marker_stub "$case_bin/sudo" "$case_marker"
  write_marker_stub "$case_bin/apt-get" "$case_marker"
  write_curl_stub "$case_bin/curl"
}

# Run install.sh in a clean environment. Extra VAR=value words go before the
# first argument that does not contain '='. XDG_RUNTIME_DIR passes through,
# because the rootless Docker checks need the login session of the user.
run_installer() {
  local -a vars=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      *=*)
        vars[${#vars[@]}]="$1"
        shift
        ;;
      *) break ;;
    esac
  done
  if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    vars[${#vars[@]}]="XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
  fi
  set +e
  env -i HOME="$case_home" PATH="$case_bin:/usr/bin:/bin" TERM=dumb \
    ${vars[@]+"${vars[@]}"} "$repo_root/install.sh" "$@" >"$case_out" 2>&1
  case_status=$?
  set -e
}

expect_status() {
  if [ "$case_status" != "$1" ]; then
    fail "$2: exit status $case_status, expected $1 (see $case_out)"
  fi
}

expect_output() {
  if ! grep -Fq -- "$1" "$case_out"; then
    fail "$2: output lacks '$1' (see $case_out)"
  fi
}

expect_no_output() {
  if grep -Fq -- "$1" "$case_out"; then
    fail "$2: output contains '$1' (see $case_out)"
  fi
}

expect_no_output_regex() {
  if grep -Eq -- "$1" "$case_out"; then
    fail "$2: output matches /$1/ (see $case_out)"
  fi
}

expect_no_changes() {
  if [ -s "$case_marker" ]; then
    fail "$1: a dry-run called a changing command: $(head -n 1 "$case_marker")"
  fi
  if [ -n "$(find "$case_home" -mindepth 1 -print -quit)" ]; then
    fail "$1: a dry-run wrote into the home directory $case_home"
  fi
}

test_ubuntu_all() {
  local name='ubuntu dry-run' version

  if [ "$(uname -s)" != Linux ] || [ "$(platform_os_release_value ID || true)" != ubuntu ]; then
    printf 'SKIP: %s (needs an Ubuntu host)\n' "$name"
    return 0
  fi
  # GitHub-hosted runners use Ubuntu releases before 26.04, which install.sh
  # refuses.
  version="$(platform_os_release_value VERSION_ID || true)"
  if ! platform_ubuntu_version_supported "$version"; then
    printf "SKIP: %s (needs Ubuntu 26.04 or later; found Ubuntu '%s')\n" "$name" "$version"
    return 0
  fi
  if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    printf 'SKIP: %s (needs a login session; XDG_RUNTIME_DIR is not set)\n' "$name"
    return 0
  fi
  new_case ubuntu
  run_installer --dry-run
  expect_status 0 "$name"
  expect_no_changes "$name"
  expect_output 'UV_NO_MODIFY_PATH=1' "$name"
  expect_output 'PROFILE=/dev/null' "$name"
  expect_output 'SHELL=/bin/sh BUN_INSTALL=' "$name"
  expect_output "ENV=$case_home/.cache/dotfiles-install/pnpm-setup.rc" "$name"
  expect_output '[shell:.bashrc]' "$name"
  expect_output 'https://build.stencil.so/tern' "$name"
  expect_no_output 'brew install' "$name"
  # Git is present on every Ubuntu host that runs this test, so the summary
  # must show the present group as one count line, not as a list.
  expect_output 'Already present: ' "$name"
  expect_no_output_regex 'Already present \([0-9]' "$name"
  expect_output 'Routine syncs (run every time): 1' "$name"
}

test_macos_arm64() {
  local name='macOS arm64 dry-run'

  new_case macos-arm64
  write_brew_stub "$case_bin/brew" "$case_marker"
  run_installer DOTFILES_OS=macos DOTFILES_ARCH=arm64 --dry-run
  expect_status 0 "$name"
  expect_no_changes "$name"
  expect_output '[dry-run] brew install gh' "$name"
  expect_output '[dry-run] brew install php' "$name"
  expect_output '[dry-run] brew install --cask docker-desktop' "$name"
  expect_output '[dry-run] brew install --cask tailscale-app' "$name"
  expect_output '[dry-run] brew install --cask github' "$name"
  expect_output "PNPM_HOME=$case_home/Library/pnpm" "$name"
  expect_output 'Not applicable on this platform: 1' "$name"
  expect_output 'Routine syncs (run every time): 1' "$name"
  expect_output '[shell:.zshrc]' "$name"
  expect_output '[shell:.bash_profile]' "$name"
  expect_no_output 'apt-get' "$name"
  expect_no_output 'Failed' "$name"
}

test_macos_intel_without_brew() {
  local name='macOS Intel without Homebrew'

  new_case macos-intel
  run_installer DOTFILES_OS=macos DOTFILES_ARCH=amd64 --dry-run packages git chrome uv
  expect_status 0 "$name"
  expect_no_changes "$name"
  expect_output 'https://brew.sh/' "$name"
  expect_output 'Git [git] (amd64): https://git-scm.com/downloads' "$name"
  expect_output 'Google Chrome [chrome] (amd64): https://www.google.com/chrome/' "$name"
  expect_output 'uv [uv]' "$name"
  expect_no_output 'brew install' "$name"
}

test_guards() {
  new_case guards
  run_installer DOTFILES_OS=macos packages git
  expect_status 1 'override without --dry-run'
  expect_output 'platform override requires --dry-run' 'override without --dry-run'
  expect_no_changes 'override without --dry-run'

  run_installer --dry-run packages no-such-package
  expect_status 2 'unknown package id'

  run_installer --help
  expect_status 0 'help'
  expect_output 'docks-kit-sync' 'help'

  case_home=/
  run_installer --dry-run list
  expect_status 1 'HOME=/'
  expect_output 'HOME must be an absolute path other than /' 'HOME=/'
}

# The Tern link shows only while Tern is missing. The Ubuntu override lets
# the case run on every host, also on Ubuntu releases that install.sh refuses.
test_tern_hint() {
  local name='Tern hint'

  new_case tern
  run_installer DOTFILES_OS=ubuntu --dry-run hooks
  expect_status 0 "$name"
  expect_output 'https://build.stencil.so/tern' "$name (Tern missing)"

  printf '#!/bin/sh\nexit 0\n' >"$case_bin/tern"
  chmod +x "$case_bin/tern"
  run_installer DOTFILES_OS=ubuntu --dry-run hooks
  expect_status 0 "$name"
  expect_no_output 'stencil.so' "$name (Tern present)"
}

test_ubuntu_all
test_macos_arm64
test_macos_intel_without_brew
test_guards
test_tern_hint

printf 'Work directory (kept, not deleted): %s\n' "$work"
if [ "$failures" -ne 0 ]; then
  printf '%s dry-run check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'install.sh dry-run tests passed\n'
