# shellcheck shell=bash
# Tool: Node.js LTS through nvm. Cross-OS.
# nvm fails under "set -u", so nvm runs only in a child bash with
# "set +eu +o pipefail". The installer itself never sources nvm.sh.

nvm_dir() {
  printf '%s\n' "$USER_HOME/.nvm"
}

# Print the Node.js version of the nvm alias "default", for example v24.22.0.
# Quiet and read-only. Fail when nvm or the default version is missing.
nvm_default_version() {
  local version

  # shellcheck disable=SC2016  # The child bash expands NVM_DIR, not this shell.
  version="$(env "NVM_DIR=$(nvm_dir)" bash -c 'set +eu +o pipefail; . "$NVM_DIR/nvm.sh" --no-use >/dev/null 2>&1 || exit 1; nvm version default' 2>/dev/null)" || return 1
  case "$version" in
    v[0-9]*) printf '%s\n' "$version" ;;
    *) return 1 ;;
  esac
}

# Print the newest nvm release tag. Use a fixed tag when GitHub does not
# answer or the answer is not a tag.
nvm_latest_tag() {
  local fallback='v0.40.8' pattern='^v[0-9]+\.[0-9]+\.[0-9]+$' tag

  tag="$(fetch https://api.github.com/repos/nvm-sh/nvm/releases/latest 2>/dev/null |
    tr ',' '\n' |
    sed -n 's/^[[:space:]{]*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*$/\1/p')" || tag=''
  if [[ $tag =~ $pattern ]]; then
    printf '%s\n' "$tag"
  else
    warn "cannot read the latest nvm release; use $fallback"
    printf '%s\n' "$fallback"
  fi
}

# Install nvm into <dir>. PROFILE=/dev/null stops the rc file edits. The nvm
# installer stops when a custom NVM_DIR does not exist, so create it first.
nvm_bootstrap() {
  local dir="$1" installer tag

  tag="$(nvm_latest_tag)"
  installer="$(cache_file nvm-install.sh)"
  download "https://raw.githubusercontent.com/nvm-sh/nvm/$tag/install.sh" "$installer" || return 1
  run mkdir -p "$dir" || return 1
  run env PROFILE=/dev/null "NVM_DIR=$dir" bash "$installer"
}

tool_node_present() {
  [ -s "$(nvm_dir)/nvm.sh" ] || return 1
  nvm_default_version >/dev/null
}

tool_node_install() {
  local dir version

  dir="$(nvm_dir)"
  if [ ! -s "$dir/nvm.sh" ]; then
    nvm_bootstrap "$dir" || return 1
  fi
  # shellcheck disable=SC2016  # The child bash expands NVM_DIR, not this shell.
  run env "NVM_DIR=$dir" bash -c 'set +eu +o pipefail; . "$NVM_DIR/nvm.sh" --no-use || exit 1; nvm install --lts || exit 1; nvm alias default "lts/*"' || return 1
  # Put the default node on PATH for later steps. A dry run on a fresh
  # machine has no default version yet; skip it then.
  if version="$(nvm_default_version)"; then
    path_prepend "$dir/versions/node/$version/bin"
  fi
}
