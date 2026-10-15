#!/usr/bin/env bash
# Tests for release/bootstrap.sh, the one-line installer of a release.
# The test makes release assets in a temporary directory and gives them to
# the bootstrap through DOTFILES_RELEASE_URL=file://..., so it needs no
# network. Each case has its own test home. The test never deletes files; it
# leaves its work directory in TMPDIR.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-test.XXXXXX")"
assets="$work/assets"
tag='v0.0.0-test'
failures=0
platform_vars=()

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}

sha256_of() {
  local out

  if command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum <"$1")"
  else
    out="$(shasum -a 256 <"$1")"
  fi
  printf '%s\n' "${out%% *}"
}

# The archive has the files of the working tree that Git does not ignore, so
# the test also covers changes that are not committed. A separate index file
# in the work directory holds them: the index, the refs, and the files of the
# repository do not change. A clean checkout gives the tree of HEAD.
build_archive() {
  local index="$work/archive.index" tree

  mkdir -p "$assets"
  GIT_INDEX_FILE="$index" git -C "$repo_root" add -A
  tree="$(GIT_INDEX_FILE="$index" git -C "$repo_root" write-tree)"
  git -C "$repo_root" archive --format=tar.gz --prefix="dotfiles-$tag/" \
    -o "$assets/dotfiles-$tag.tar.gz" "$tree"
  archive_sha="$(sha256_of "$assets/dotfiles-$tag.tar.gz")"
}

# render <output> <sha256>: the bootstrap as the release workflow makes it.
render() {
  sed -e "s/@DOTFILES_TAG@/$tag/g" -e "s/@DOTFILES_SHA256@/$2/g" \
    "$repo_root/release/bootstrap.sh" >"$1"
}

# A stub that records its arguments in the marker file and fails.
write_marker_stub() {
  local path="$1" marker="$2"

  # shellcheck disable=SC2016  # $0 and $* belong to the stub, not to this script.
  printf '#!/bin/sh\nprintf "%%s\\n" "$0 $*" >> "%s"\nexit 1\n' "$marker" >"$path"
  chmod +x "$path"
}

# A curl stub: file:// URLs go to the real curl (the bootstrap download), and
# the GitHub API calls of install.sh get canned answers.
write_curl_stub() {
  local path="$1" real_curl

  real_curl="$(command -v curl)"
  cat >"$path" <<EOF
#!/bin/sh
for arg in "\$@"; do url="\$arg"; done
case "\$url" in
  file://*) exec '$real_curl' "\$@" ;;
  https://api.github.com/repos/nvm-sh/nvm/releases/latest) printf '{"tag_name": "v0.40.8"}\n' ;;
  https://api.github.com/repos/rustdesk/rustdesk/releases/latest) printf '{"tag_name": "9.9.9"}\n' ;;
  *) exit 22 ;;
esac
EOF
  chmod +x "$path"
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
  case_dir="$work/$1"
  case_home="$case_dir/home"
  case_bin="$case_dir/bin"
  case_out="$case_dir/output.log"
  case_marker="$case_dir/changes.log"
  case_release="$case_home/.cache/dotfiles-install/release/dotfiles-$tag"
  mkdir -p "$case_home" "$case_bin"
}

# run_bootstrap <mode> <script> [VAR=value...] [args...]: run the script in a
# clean environment. The mode 'file' runs 'bash <script> args'; the mode
# 'pipe' runs 'bash -s -- args' with the script on stdin, as in curl | bash.
run_bootstrap() {
  local mode="$1" script="$2"
  local -a vars=()

  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      *=*)
        vars[${#vars[@]}]="$1"
        shift
        ;;
      *) break ;;
    esac
  done
  set +e
  if [ "$mode" = pipe ]; then
    env -i HOME="$case_home" PATH="$case_bin:/usr/bin:/bin" TERM=dumb \
      DOTFILES_RELEASE_URL="file://$assets/" ${vars[@]+"${vars[@]}"} \
      bash -s -- "$@" <"$script" >"$case_out" 2>&1
  else
    env -i HOME="$case_home" PATH="$case_bin:/usr/bin:/bin" TERM=dumb \
      DOTFILES_RELEASE_URL="file://$assets/" ${vars[@]+"${vars[@]}"} \
      bash "$script" "$@" </dev/null >"$case_out" 2>&1
  fi
  case_status=$?
  set -e
}

expect_status() {
  if [ "$case_status" != "$1" ]; then
    fail "$2: exit status $case_status, expected $1 (see $case_out)"
  fi
}

expect_failure() {
  if [ "$case_status" = 0 ]; then
    fail "$1: exit status 0, expected a failure (see $case_out)"
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

expect_unpacked() {
  if [ ! -f "$case_release/install.sh" ]; then
    fail "$1: the release is not unpacked in $case_release"
  fi
  if [ -e "$case_release/.git" ]; then
    fail "$1: the unpacked release has a .git entry"
  fi
}

expect_not_unpacked() {
  if [ -e "$case_release" ]; then
    fail "$1: the release is unpacked in $case_release"
  fi
}

# install.sh supports Ubuntu 26.04 or later and macOS. On another host, the
# run cases use the platform override, which works with --dry-run.
choose_platform() {
  new_case platform
  set +e
  env -i HOME="$case_home" PATH=/usr/bin:/bin TERM=dumb \
    bash "$repo_root/install.sh" --dry-run list </dev/null >"$case_out" 2>&1
  case_status=$?
  set -e
  if [ "$case_status" != 0 ]; then
    printf 'SKIP: native platform run (install.sh does not support this host); the run cases use DOTFILES_OS=macos DOTFILES_ARCH=arm64\n'
    platform_vars=(DOTFILES_OS=macos DOTFILES_ARCH=arm64)
  fi
}

test_file_form() {
  local name='bash install.sh --dry-run list'

  new_case file-form
  run_bootstrap file "$work/install.sh" ${platform_vars[@]+"${platform_vars[@]}"} --dry-run list
  expect_status 0 "$name"
  expect_output 'SHA-256 is correct' "$name"
  expect_output 'Platform:' "$name"
  expect_unpacked "$name"
}

test_pipe_form() {
  local name='bash -s -- --dry-run list'

  new_case pipe-form
  run_bootstrap pipe "$work/install.sh" ${platform_vars[@]+"${platform_vars[@]}"} --dry-run list
  expect_status 0 "$name"
  expect_output 'SHA-256 is correct' "$name"
  expect_output 'Platform:' "$name"
  expect_unpacked "$name"
}

# A full dry-run from the release archive on a mocked macOS. The archive has
# no .git, so the hooks step is not applicable and does not fail.
test_pipe_all_macos() {
  local name='bash -s -- --dry-run (mocked macOS)'

  new_case pipe-all-macos
  write_marker_stub "$case_bin/sudo" "$case_marker"
  write_marker_stub "$case_bin/apt-get" "$case_marker"
  write_curl_stub "$case_bin/curl"
  write_brew_stub "$case_bin/brew" "$case_marker"
  run_bootstrap pipe "$work/install.sh" DOTFILES_OS=macos DOTFILES_ARCH=arm64 --dry-run
  expect_status 0 "$name"
  expect_unpacked "$name"
  expect_output 'hooks (n/a)' "$name"
  expect_output '[dry-run] brew install gh' "$name"
  expect_no_output 'not a Git working tree' "$name"
  expect_no_output 'Failed' "$name"
  if [ -s "$case_marker" ]; then
    fail "$name: a dry-run called a changing command: $(head -n 1 "$case_marker")"
  fi
}

test_tampered_archive() {
  local name='wrong SHA-256'

  new_case tampered
  render "$work/install-tampered.sh" "$(printf '0%.0s' {1..64})"
  run_bootstrap file "$work/install-tampered.sh" ${platform_vars[@]+"${platform_vars[@]}"} --dry-run list
  expect_failure "$name"
  expect_output 'integrity check failed' "$name"
  expect_output 'Nothing was unpacked' "$name"
  expect_no_output 'Platform:' "$name"
  expect_not_unpacked "$name"
}

test_unrendered_template() {
  local name='unrendered template'

  new_case unrendered
  run_bootstrap file "$repo_root/release/bootstrap.sh" --dry-run list
  expect_failure "$name"
  expect_output 'this is the template release/bootstrap.sh' "$name"
  if [ -e "$case_home/.cache" ]; then
    fail "$name: the template wrote into the home directory $case_home"
  fi
}

test_bad_release_url() {
  local name='http:// release URL'

  new_case bad-url
  run_bootstrap file "$work/install.sh" "DOTFILES_RELEASE_URL=http://example.com/" --dry-run list
  expect_failure "$name"
  expect_output 'DOTFILES_RELEASE_URL must start with https://' "$name"
  expect_not_unpacked "$name"
}

build_archive
render "$work/install.sh" "$archive_sha"
choose_platform
test_file_form
test_pipe_form
test_pipe_all_macos
test_tampered_archive
test_unrendered_template
test_bad_release_url

printf 'Work directory (kept, not deleted): %s\n' "$work"
if [ "$failures" -ne 0 ]; then
  printf '%s bootstrap check(s) failed\n' "$failures" >&2
  exit 1
fi
printf 'bootstrap tests passed\n'
