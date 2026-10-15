#!/usr/bin/env bash
# One-line installer for the DocksDocks dotfiles. Each release has this file
# as its install.sh asset:
#
#   curl -fsSL https://github.com/DocksDocks/dotfiles/releases/latest/download/install.sh | bash
#
# Arguments go to the install.sh of the release:
#
#   curl -fsSL https://github.com/DocksDocks/dotfiles/releases/latest/download/install.sh | bash -s -- --dry-run
#
# This file is a template. The release workflow puts the release tag and the
# SHA-256 of the release archive in place of the two placeholders below. The
# script downloads the archive of that release into
# ~/.cache/dotfiles-install/release/, stops when the SHA-256 is different,
# unpacks the archive, and runs its install.sh. It never installs a branch.
#
# All of the work is in functions. The last line calls main, so a partial
# download of this script cannot run a partial script.

set -euo pipefail

BOOT_NAME='dotfiles-install'
BOOT_REPO_URL='https://github.com/DocksDocks/dotfiles'
BOOT_HOME=''
BOOT_DOWNLOAD_TOOL=''
BOOT_SHA_TOOL=''

say() {
  printf '%s: %s\n' "$BOOT_NAME" "$*" >&2
}

fail() {
  printf '%s: error: %s\n' "$BOOT_NAME" "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

# The workflow replaces each placeholder. A value that still contains '@' is
# a placeholder, so this file is the template and not a release asset.
check_release() {
  local tag="$1" sha="$2"

  case "$tag$sha" in
    *@*)
      fail "this is the template release/bootstrap.sh, not a release asset; use the install.sh asset of a release: $BOOT_REPO_URL/releases"
      ;;
  esac
  case "$tag" in
    v[0-9]*) ;;
    *) fail "the release tag is not valid: '$tag'" ;;
  esac
  case "$tag" in
    *[!A-Za-z0-9._-]*) fail "the release tag is not valid: '$tag'" ;;
  esac
  if [ "${#sha}" -ne 64 ]; then
    fail "the SHA-256 in this script is not valid: '$sha'"
  fi
  case "$sha" in
    *[!0-9a-f]*) fail "the SHA-256 in this script is not valid: '$sha'" ;;
  esac
}

# The installer uses sudo for each privileged step. A root run would make
# root-owned files in the home of the user.
refuse_root() {
  if [ "$(id -u)" = 0 ]; then
    fail 'do not run this installer as root; run it as your user (it uses sudo when necessary)'
  fi
}

# This is the only place that reads HOME. A bad HOME cannot send the
# download to an unexpected directory.
read_home() {
  local raw="${HOME:-}" home

  home="$raw"
  while :; do
    case "$home" in
      */) home="${home%/}" ;;
      *) break ;;
    esac
  done
  case "$home" in
    /?*) ;;
    *) fail "HOME must be an absolute path other than /; found '$raw'" ;;
  esac
  [ -d "$home" ] || fail "HOME is not a directory: $home"
  [ -O "$home" ] || fail "HOME is not owned by the current user: $home"
  BOOT_HOME="$home"
}

find_tools() {
  if have curl; then
    BOOT_DOWNLOAD_TOOL=curl
  elif have wget; then
    BOOT_DOWNLOAD_TOOL=wget
  else
    fail 'install curl or wget, then run this installer again'
  fi
  if have sha256sum; then
    BOOT_SHA_TOOL=sha256sum
  elif have shasum; then
    BOOT_SHA_TOOL=shasum
  else
    fail 'install sha256sum (coreutils) or shasum (perl), then run this installer again'
  fi
}

# release_base_url <tag>: the URL of the release assets, with a final '/'.
# DOTFILES_RELEASE_URL replaces it for tests (a file:// URL). The SHA-256
# check applies to all URLs.
release_base_url() {
  local tag="$1" url="${DOTFILES_RELEASE_URL:-}"

  if [ -z "$url" ]; then
    printf '%s/releases/download/%s/\n' "$BOOT_REPO_URL" "$tag"
    return 0
  fi
  case "$url" in
    https://?* | file:///*) ;;
    *) fail "DOTFILES_RELEASE_URL must start with https:// or file:///; found '$url'" ;;
  esac
  while :; do
    case "$url" in
      */) url="${url%/}" ;;
      *) break ;;
    esac
  done
  printf '%s/\n' "$url"
}

# download <url> <file>: write the URL to the file. HTTPS only, and an HTTP
# error is a failure. A file:// URL is for tests and needs curl.
download() {
  local url="$1" file="$2" proto='=https'

  case "$url" in
    file://*) proto='=file' ;;
  esac
  if [ "$BOOT_DOWNLOAD_TOOL" = curl ]; then
    curl --proto "$proto" --proto-redir '=https' --tlsv1.2 \
      --fail --silent --show-error --location --retry 3 \
      --output "$file" "$url" </dev/null
    return
  fi
  if [ "$proto" != '=https' ]; then
    fail "a file:// release URL needs curl: $url"
  fi
  wget --https-only --quiet --tries=3 --output-document="$file" "$url" </dev/null
}

# sha256_of <file>: print the SHA-256 of the file in lowercase hex.
sha256_of() {
  local out

  if [ "$BOOT_SHA_TOOL" = sha256sum ]; then
    out="$(sha256sum <"$1")"
  else
    out="$(shasum -a 256 <"$1")"
  fi
  printf '%s\n' "${out%% *}" | tr 'A-F' 'a-f'
}

main() {
  local tag='@DOTFILES_TAG@'
  local sha='@DOTFILES_SHA256@'
  local base dir archive name actual installer

  if [ -z "${BASH_VERSION:-}" ]; then
    printf '%s: error: run this installer with bash\n' "$BOOT_NAME" >&2
    exit 1
  fi
  check_release "$tag" "$sha"
  refuse_root
  read_home
  find_tools

  base="$(release_base_url "$tag")"
  if [ -n "${DOTFILES_RELEASE_URL:-}" ]; then
    say "DOTFILES_RELEASE_URL is set; the release comes from $base"
  fi
  name="dotfiles-$tag"
  dir="$BOOT_HOME/.cache/dotfiles-install/release"
  archive="$dir/$name.tar.gz"
  mkdir -p -- "$dir"

  say "Release $tag: download $base$name.tar.gz"
  if ! download "$base$name.tar.gz" "$archive"; then
    fail "the download failed: $base$name.tar.gz"
  fi

  actual="$(sha256_of "$archive")"
  if [ "$actual" != "$sha" ]; then
    fail "integrity check failed: the SHA-256 of $archive is $actual, but release $tag needs $sha. The file is damaged or changed. Nothing was unpacked."
  fi
  say "SHA-256 is correct: $sha"

  tar -x -z --no-same-owner -f "$archive" -C "$dir" </dev/null
  installer="$dir/$name/install.sh"
  [ -f "$installer" ] || fail "the archive has no $name/install.sh"
  say "Unpacked to $dir/$name"

  export HOME="$BOOT_HOME"
  # In 'curl ... | bash', stdin is the pipe. Prompts must read the keyboard.
  if [ ! -t 0 ] && (exec </dev/tty) 2>/dev/null; then
    exec bash "$installer" "$@" </dev/tty
  fi
  exec bash "$installer" "$@"
}

# The braces make a cut-off last line a syntax error, so a partial download
# cannot call main with fewer arguments.
{ main "$@"; }
