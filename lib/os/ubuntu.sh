# shellcheck shell=bash
# Ubuntu adapter: base apt packages and the apt, apt_repo and deb methods.
# Sourced by install.sh after lib/core.sh. Uses the core API and the globals
# REPO_ROOT, DRY_RUN, USER_HOME, CACHE_DIR, PLATFORM_ARCH, PLATFORM_CODENAME
# and RC_UNSUPPORTED.

# shellcheck source=lib/os/ubuntu_docker.sh
. "$REPO_ROOT/lib/os/ubuntu_docker.sh"

APT_SOURCES_DIR='/etc/apt/sources.list.d'
APT_KEYRINGS_DIR='/etc/apt/keyrings'

# apt-get update runs one time per run, and again after a change to an apt
# source or key (the dirty flag).
APT_UPDATED=0
APT_SOURCES_DIRTY=0

# Adapter interface -----------------------------------------------------------

os_prepare() {
  method_apt_present ca-certificates curl unzip && return 0
  method_apt_install ca-certificates curl unzip
}

os_rc_files() {
  printf '%s\n' "$USER_HOME/.bashrc"
}

os_has_command() {
  have "$1"
}

# Shared helpers --------------------------------------------------------------

# Returns 0 when PLATFORM_ARCH is in the space-separated list <archs>.
ubuntu_arch_supported() {
  case " $1 " in
    *" $PLATFORM_ARCH "*) return 0 ;;
    *) return 1 ;;
  esac
}

# Returns 0 when dpkg reports <pkg> as fully installed. Quiet.
apt_pkg_installed() {
  local status

  # shellcheck disable=SC2016  # ${Status} is a dpkg-query field, not a shell expansion.
  status="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" || return 1
  [ "$status" = 'install ok installed' ]
}

apt_mark_sources_changed() {
  APT_SOURCES_DIRTY=1
}

apt_update_once() {
  if [ "$APT_UPDATED" = 1 ] && [ "$APT_SOURCES_DIRTY" = 0 ]; then
    return 0
  fi
  run_sudo apt-get update || return 1
  APT_UPDATED=1
  APT_SOURCES_DIRTY=0
}

# Installs the file <src> as <dest>, owned by root with mode 0644. Creates the
# parent directory when it is missing and backs up an existing <dest> first.
# Marks the apt sources as changed.
apt_install_root_file() {
  local src="$1" dest="$2"
  local dir="${dest%/*}"

  if [ ! -d "$dir" ]; then
    run_sudo install -d -m 0755 "$dir" || return 1
  fi
  backup_file_sudo "$dest" || return 1
  run_sudo install -m 0644 "$src" "$dest" || return 1
  apt_mark_sources_changed
}

# Method: apt <pkg>... --------------------------------------------------------

method_apt_present() {
  local pkg

  [ "$#" -gt 0 ] || return 1
  for pkg in "$@"; do
    apt_pkg_installed "$pkg" || return 1
  done
}

method_apt_install() {
  if [ "$#" -eq 0 ]; then
    warn 'apt: no packages given'
    return 1
  fi
  apt_update_once || return 1
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" || return 1
}

# Method: apt_repo <repo_id> <pkg>... -----------------------------------------

# Sets the repo_* locals of the caller (Bash dynamic scope) for <repo_id>.
# Returns 1 for an unknown id, or when the repo needs a codename and
# PLATFORM_CODENAME is empty. Quiet.
apt_repo_spec() {
  case "$1" in
    github-cli)
      repo_uri='https://cli.github.com/packages'
      repo_suite='stable'
      repo_component='main'
      repo_key_url='https://cli.github.com/packages/githubcli-archive-keyring.gpg'
      repo_key_path="$APT_KEYRINGS_DIR/githubcli-archive-keyring.gpg"
      repo_file='github-cli.sources'
      repo_archs='amd64 arm64'
      # Old machines have a stale key that cannot verify the current
      # InRelease file, so compare the key with the vendor copy each time.
      repo_key_refresh=1
      ;;
    docker)
      [ -n "${PLATFORM_CODENAME:-}" ] || return 1
      repo_uri='https://download.docker.com/linux/ubuntu'
      repo_suite="$PLATFORM_CODENAME"
      repo_component='stable'
      repo_key_url='https://download.docker.com/linux/ubuntu/gpg'
      repo_key_path="$APT_KEYRINGS_DIR/docker.asc"
      repo_file='docker.sources'
      repo_archs='amd64 arm64'
      repo_key_refresh=0
      ;;
    tailscale)
      [ -n "${PLATFORM_CODENAME:-}" ] || return 1
      repo_uri='https://pkgs.tailscale.com/stable/ubuntu'
      repo_suite="$PLATFORM_CODENAME"
      repo_component='main'
      repo_key_url="https://pkgs.tailscale.com/stable/ubuntu/$PLATFORM_CODENAME.noarmor.gpg"
      # Vendor path: the tailscale-archive-keyring package owns this file.
      repo_key_path='/usr/share/keyrings/tailscale-archive-keyring.gpg'
      repo_file='tailscale.sources'
      repo_archs='amd64 arm64'
      repo_key_refresh=0
      ;;
    *)
      return 1
      ;;
  esac
}

# Returns 0 when <line> contains <uri> (given without a trailing slash). The
# match must end at the end of the line, at a slash, or at a blank.
apt_line_has_uri() {
  [[ "$1" == *"$2" || "$1" == *"$2"[/[:space:]]* ]]
}

# Returns 0 when a line of the one-line format <file> that is not a comment
# contains <uri>.
apt_list_file_has_uri() {
  local file="$1" uri="${2%/}" line

  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      '#'*) continue ;;
    esac
    if apt_line_has_uri "$line" "$uri"; then
      return 0
    fi
  done <"$file"
  return 1
}

# Returns 0 when apt reads <value> as the boolean false: no, false, off,
# without, disable or 0, in any letter case.
apt_bool_false() {
  case "$1" in
    0 | [Nn][Oo] | [Ff][Aa][Ll][Ss][Ee] | [Oo][Ff][Ff] | [Ww][Ii][Tt][Hh][Oo][Uu][Tt] | [Dd][Ii][Ss][Aa][Bb][Ll][Ee]) return 0 ;;
    *) return 1 ;;
  esac
}

# Returns 0 when an enabled stanza of the deb822 <file> contains <uri>.
# Blank lines separate stanzas. "Enabled: no" disables a stanza
# (sources.list(5)); the field name and the value ignore letter case.
apt_deb822_file_has_uri() {
  local file="$1" uri="${2%/}" line text value has_uri=0 disabled=0

  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    text="${line#"${line%%[![:space:]]*}"}"
    if [ -z "$text" ]; then
      if [ "$has_uri" = 1 ] && [ "$disabled" = 0 ]; then
        return 0
      fi
      has_uri=0
      disabled=0
      continue
    fi
    case "$text" in
      '#'*) continue ;;
    esac
    case "$line" in
      [Ee][Nn][Aa][Bb][Ll][Ee][Dd]:*)
        value="${line#*:}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if apt_bool_false "$value"; then
          disabled=1
        else
          disabled=0
        fi
        ;;
    esac
    if apt_line_has_uri "$text" "$uri"; then
      has_uri=1
    fi
  done <"$file"
  [ "$has_uri" = 1 ] && [ "$disabled" = 0 ]
}

# Returns 0 when the apt source <file> has an enabled source for <uri>.
apt_source_file_has_uri() {
  case "$1" in
    *.sources) apt_deb822_file_has_uri "$1" "$2" ;;
    *) apt_list_file_has_uri "$1" "$2" ;;
  esac
}

# Prints each file that has an enabled apt source for <uri>, one per line:
# sources.list, and the .list and .sources files in sources.list.d.
# Quiet and read-only.
apt_source_files() {
  local file

  for file in /etc/apt/sources.list "$APT_SOURCES_DIR"/*.list "$APT_SOURCES_DIR"/*.sources; do
    [ -f "$file" ] || continue
    if apt_source_file_has_uri "$file" "$1"; then
      printf '%s\n' "$file"
    fi
  done
  return 0
}

# Returns 0 when an enabled apt source for <uri> exists. Quiet and read-only.
apt_source_exists() {
  local files

  files="$(apt_source_files "$1")"
  [ -n "$files" ]
}

# Returns 0 when a file with an enabled apt source for <uri> names the key
# <path>. Quiet and read-only.
apt_source_uses_key() {
  local uri="$1" key="$2" file

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if grep -qF -- "$key" "$file"; then
      return 0
    fi
  done < <(apt_source_files "$uri")
  return 1
}

# Returns 0 when all users can read <path>. apt reads keys as the _apt user.
apt_key_world_readable() {
  local mode

  mode="$(stat -L -c %a "$1" 2>/dev/null)" || return 1
  case "${mode#"${mode%?}"}" in
    [4567]) return 0 ;;
    *) return 1 ;;
  esac
}

# Returns 1 when an enabled source for <uri> names the key <path> and the key
# is missing or not readable for all users. Quiet and read-only.
apt_repo_key_usable() {
  apt_source_uses_key "$1" "$2" || return 0
  [ -e "$2" ] && apt_key_world_readable "$2"
}

# Gives an existing key at <path> mode 0644 when other users cannot read it.
apt_key_fix_mode() {
  [ -e "$1" ] || return 0
  apt_key_world_readable "$1" && return 0
  log "Make the apt key $1 readable for all users (mode 0644)."
  run_sudo chmod 0644 "$1" || return 1
  apt_mark_sources_changed
}

# Puts the key from <url> at <path>. Keeps an existing key, except when
# <refresh> is 1: then a key that differs from the vendor copy is replaced.
# The key is stored as downloaded.
apt_repo_ensure_key() {
  local url="$1" path="$2" refresh="$3" tmp

  if [ -e "$path" ] && [ "$refresh" != 1 ]; then
    return 0
  fi
  tmp="$(cache_file "${path##*/}")"
  download "$url" "$tmp" || return 1
  if [ "$DRY_RUN" != 1 ]; then
    if [ ! -s "$tmp" ]; then
      warn "the key download from $url is empty"
      return 1
    fi
    if [ -e "$path" ] && cmp -s "$tmp" "$path"; then
      return 0
    fi
  fi
  if [ -e "$path" ] && [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] replace $path only when it differs from the download"
  elif [ -e "$path" ]; then
    log "Replace the outdated apt key $path."
  fi
  apt_install_root_file "$tmp" "$path"
}

# Makes the key at <path> ready for a source that uses it: installs a missing
# key, fixes the mode of an unreadable key, and refreshes the key when
# <refresh> is 1.
apt_repo_prepare_key() {
  local url="$1" path="$2" refresh="$3"

  apt_key_fix_mode "$path" || return 1
  apt_repo_ensure_key "$url" "$path" "$refresh"
}

# An enabled source for <uri> exists. Prepares the key at <path> when that
# source names it. Else a key with <refresh> 1 is only refreshed.
apt_repo_reconcile_key() {
  local uri="$1" url="$2" path="$3" refresh="$4"

  if apt_source_uses_key "$uri" "$path"; then
    apt_repo_prepare_key "$url" "$path" "$refresh"
  elif [ "$refresh" = 1 ] && [ -e "$path" ]; then
    apt_repo_ensure_key "$url" "$path" 1
  fi
}

# Prints a deb822 source stanza.
apt_repo_render_source() {
  local uri="$1" suite="$2" component="$3" key_path="$4"

  printf 'Types: deb\n'
  printf 'URIs: %s\n' "$uri"
  printf 'Suites: %s\n' "$suite"
  printf 'Components: %s\n' "$component"
  printf 'Architectures: %s\n' "$PLATFORM_ARCH"
  printf 'Signed-By: %s\n' "$key_path"
}

# Writes the deb822 source <file> into sources.list.d through a cache file.
apt_repo_write_source() {
  local file="$1" uri="$2" suite="$3" component="$4" key_path="$5"
  local tmp dest="$APT_SOURCES_DIR/$1"

  tmp="$(cache_file "$file")"
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] content of $dest:"
    apt_repo_render_source "$uri" "$suite" "$component" "$key_path"
  else
    mkdir -p "${tmp%/*}" || return 1
    apt_repo_render_source "$uri" "$suite" "$component" "$key_path" >"$tmp" || return 1
  fi
  apt_install_root_file "$tmp" "$dest"
}

method_apt_repo_present() {
  local repo_id="${1:-}"
  local repo_uri='' repo_suite='' repo_component='' repo_key_url=''
  local repo_key_path='' repo_file='' repo_archs='' repo_key_refresh=0

  [ "$#" -ge 2 ] || return 1
  apt_repo_spec "$repo_id" || return 1
  shift
  method_apt_present "$@" || return 1
  apt_source_exists "$repo_uri" || return 1
  apt_repo_key_usable "$repo_uri" "$repo_key_path"
}

# An enabled source that already has the repo URI stays as it is: a second
# source with another Signed-By value makes apt reject both. A disabled
# stanza does not count; the write path backs up a file with the same name.
method_apt_repo_install() {
  local repo_id="${1:-}"
  local repo_uri='' repo_suite='' repo_component='' repo_key_url=''
  local repo_key_path='' repo_file='' repo_archs='' repo_key_refresh=0

  if [ "$#" -lt 2 ]; then
    warn 'apt_repo: give a repo id and at least one package'
    return 1
  fi
  if ! apt_repo_spec "$repo_id"; then
    warn "apt_repo: unknown repo id '$repo_id', or the Ubuntu codename is empty"
    return 1
  fi
  shift
  ubuntu_arch_supported "$repo_archs" || return "$RC_UNSUPPORTED"
  if [ "$repo_id" = docker ]; then
    docker_check_conflicts || return 1
  fi

  if apt_source_exists "$repo_uri"; then
    apt_repo_reconcile_key "$repo_uri" "$repo_key_url" "$repo_key_path" "$repo_key_refresh" || return 1
  else
    apt_repo_prepare_key "$repo_key_url" "$repo_key_path" "$repo_key_refresh" || return 1
    apt_repo_write_source "$repo_file" "$repo_uri" "$repo_suite" "$repo_component" "$repo_key_path" || return 1
  fi
  method_apt_install "$@"
}

# Method: deb <deb_id> --------------------------------------------------------

# Sets the deb_pkg and deb_archs locals of the caller (Bash dynamic scope).
# Returns 1 for an unknown id. Quiet.
deb_spec() {
  case "$1" in
    chrome)
      # The package then adds and manages its own Google apt source.
      deb_pkg='google-chrome-stable'
      deb_archs='amd64 arm64'
      ;;
    discord)
      deb_pkg='discord'
      deb_archs='amd64'
      ;;
    parsec)
      deb_pkg='parsec'
      deb_archs='amd64'
      ;;
    rustdesk)
      deb_pkg='rustdesk'
      deb_archs='amd64 arm64'
      ;;
    *)
      return 1
      ;;
  esac
}

# Prints the .deb URL of the latest RustDesk release for PLATFORM_ARCH.
# The release also has assets such as rustdesk-<tag>-x86_64-sciter.deb and
# rustdesk-unattended-wayland-<tag>-x86_64.deb, so the asset name must match
# exactly.
rustdesk_deb_url() {
  local json tag asset suffix
  local tag_re='"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)"'

  case "$PLATFORM_ARCH" in
    amd64) suffix='x86_64' ;;
    arm64) suffix='aarch64' ;;
    *) return "$RC_UNSUPPORTED" ;;
  esac
  if ! json="$(fetch 'https://api.github.com/repos/rustdesk/rustdesk/releases/latest')"; then
    warn 'cannot read the latest RustDesk release from the GitHub API'
    return 1
  fi
  if ! [[ "$json" =~ $tag_re ]]; then
    warn 'the GitHub API answer has no RustDesk tag_name'
    return 1
  fi
  tag="${BASH_REMATCH[1]}"
  case "$tag" in
    *[!0-9A-Za-z._-]*)
      warn "unexpected RustDesk release tag: $tag"
      return 1
      ;;
  esac
  asset="rustdesk-$tag-$suffix.deb"
  case "$json" in
    *"/$asset\""*) ;;
    *)
      warn "RustDesk release $tag has no asset $asset"
      return 1
      ;;
  esac
  printf '%s\n' "https://github.com/rustdesk/rustdesk/releases/download/$tag/$asset"
}

# Prints the download URL of <deb_id> for PLATFORM_ARCH.
deb_url() {
  case "$1" in
    chrome) printf '%s\n' "https://dl.google.com/linux/direct/google-chrome-stable_current_$PLATFORM_ARCH.deb" ;;
    discord) printf '%s\n' 'https://discord.com/api/download?platform=linux&format=deb' ;;
    parsec) printf '%s\n' 'https://builds.parsec.app/package/parsec-linux.deb' ;;
    rustdesk) rustdesk_deb_url ;;
    *) return 1 ;;
  esac
}

method_deb_present() {
  local deb_pkg='' deb_archs=''

  deb_spec "${1:-}" || return 1
  apt_pkg_installed "$deb_pkg"
}

# apt-get installs the local file and its dependencies (also the t64 names).
# Bare "dpkg -i" does not resolve dependencies.
method_deb_install() {
  local deb_id="${1:-}" deb_pkg='' deb_archs='' url deb_file

  if ! deb_spec "$deb_id"; then
    warn "deb: unknown id '$deb_id'"
    return 1
  fi
  ubuntu_arch_supported "$deb_archs" || return "$RC_UNSUPPORTED"
  url="$(deb_url "$deb_id")" || return "$?"
  deb_file="$(cache_file "$deb_id.deb")"
  download "$url" "$deb_file" || return 1
  apt_update_once || return 1
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb_file" || return 1
}
