# shellcheck shell=bash
# Platform detection. detect_platform sets PLATFORM_OS, PLATFORM_ARCH,
# PLATFORM_VERSION, and PLATFORM_CODENAME.

PLATFORM_OS_RELEASE_FILE=/etc/os-release
PLATFORM_MIN_UBUNTU_MAJOR=26
PLATFORM_MIN_UBUNTU_MINOR=4

PLATFORM_OS=''
PLATFORM_ARCH=''
PLATFORM_VERSION=''
PLATFORM_CODENAME=''

# Read one key from os-release without sourcing it, so that the file cannot
# run code or change variables of this script.
platform_os_release_value() {
  local key="$1" line value

  [ -r "$PLATFORM_OS_RELEASE_FILE" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*)
        value="${line#*=}"
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"
        printf '%s\n' "$value"
        return 0
        ;;
    esac
  done <"$PLATFORM_OS_RELEASE_FILE"
  return 1
}

# True when <version> (major.minor) is at least the minimum Ubuntu release.
# The base 10 prefix stops a leading zero ("04") from reading as octal.
platform_ubuntu_version_supported() {
  local version="$1" major minor

  major="${version%%.*}"
  minor=0
  if [ "$major" != "$version" ]; then
    minor="${version#*.}"
    minor="${minor%%.*}"
  fi
  case "$major" in '' | *[!0-9]*) return 1 ;; esac
  case "$minor" in '' | *[!0-9]*) return 1 ;; esac
  major=$((10#$major))
  minor=$((10#$minor))
  if [ "$major" -ne "$PLATFORM_MIN_UBUNTU_MAJOR" ]; then
    [ "$major" -gt "$PLATFORM_MIN_UBUNTU_MAJOR" ]
    return
  fi
  [ "$minor" -ge "$PLATFORM_MIN_UBUNTU_MINOR" ]
}

platform_detect_ubuntu() {
  local id version codename

  id="$(platform_os_release_value ID || true)"
  [ -n "$id" ] || die "cannot read the OS id from $PLATFORM_OS_RELEASE_FILE"
  [ "$id" = ubuntu ] || die "this installer supports Ubuntu 26.04 or later and macOS; found '$id'"
  version="$(platform_os_release_value VERSION_ID || true)"
  platform_ubuntu_version_supported "$version" ||
    die "this installer needs Ubuntu 26.04 or later; found Ubuntu '$version'"
  codename="$(platform_os_release_value VERSION_CODENAME || true)"
  if [ -z "$codename" ]; then
    codename="$(platform_os_release_value UBUNTU_CODENAME || true)"
  fi
  [ -n "$codename" ] || die "cannot read the Ubuntu codename from $PLATFORM_OS_RELEASE_FILE"
  PLATFORM_OS=ubuntu
  PLATFORM_VERSION="$version"
  PLATFORM_CODENAME="$codename"
}

platform_detect_macos() {
  local version

  version="$(sw_vers -productVersion 2>/dev/null || true)"
  [ -n "$version" ] || die 'cannot read the macOS version (sw_vers -productVersion)'
  PLATFORM_OS=macos
  PLATFORM_VERSION="$version"
  PLATFORM_CODENAME=''
}

platform_detect_os() {
  local kernel

  kernel="$(uname -s)"
  case "$kernel" in
    Linux) platform_detect_ubuntu ;;
    Darwin) platform_detect_macos ;;
    *) die "unsupported operating system: $kernel (use Ubuntu 26.04 or later, or macOS)" ;;
  esac
}

platform_detect_arch() {
  local machine

  machine="$(uname -m)"
  case "$machine" in
    x86_64 | amd64) PLATFORM_ARCH=amd64 ;;
    aarch64 | arm64) PLATFORM_ARCH=arm64 ;;
    *) die "unsupported CPU architecture: $machine (use amd64 or arm64)" ;;
  esac
}

platform_override_os() {
  case "$1" in
    ubuntu)
      PLATFORM_OS=ubuntu
      PLATFORM_CODENAME=resolute
      ;;
    macos)
      PLATFORM_OS=macos
      PLATFORM_CODENAME=''
      ;;
    *) die "DOTFILES_OS must be ubuntu or macos; found '$1'" ;;
  esac
  PLATFORM_VERSION=override
}

platform_override_arch() {
  case "$1" in
    amd64 | arm64) PLATFORM_ARCH="$1" ;;
    *) die "DOTFILES_ARCH must be amd64 or arm64; found '$1'" ;;
  esac
}

# The DOTFILES_OS and DOTFILES_ARCH overrides are a test seam. A real install
# with a false platform would install wrong packages, so the overrides work
# only in dry-run or for the shell command, which installs no package.
detect_platform() {
  local command="${1:-}" os_override="${DOTFILES_OS:-}" arch_override="${DOTFILES_ARCH:-}"

  if [ -n "$os_override" ] || [ -n "$arch_override" ]; then
    if [ "$DRY_RUN" != 1 ] && [ "$command" != shell ]; then
      die 'platform override requires --dry-run'
    fi
    warn "platform override is active: DOTFILES_OS='$os_override' DOTFILES_ARCH='$arch_override'"
  fi
  if [ -n "$os_override" ]; then
    platform_override_os "$os_override"
  else
    platform_detect_os
  fi
  if [ -n "$arch_override" ]; then
    platform_override_arch "$arch_override"
  else
    platform_detect_arch
  fi
}

# One line such as "ubuntu 26.04 (resolute) amd64".
platform_describe() {
  if [ -n "$PLATFORM_CODENAME" ]; then
    printf '%s %s (%s) %s\n' "$PLATFORM_OS" "$PLATFORM_VERSION" "$PLATFORM_CODENAME" "$PLATFORM_ARCH"
  else
    printf '%s %s %s\n' "$PLATFORM_OS" "$PLATFORM_VERSION" "$PLATFORM_ARCH"
  fi
}
