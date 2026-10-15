# shellcheck shell=bash
# Tools: pnpm (standalone installer) and the pnpm global virtual store setting.
# Cross-OS. The functions use USER_HOME, never HOME.

# PNPM_HOME for this installer: the pnpm default for each platform.
pnpm_home_dir() {
  case "$PLATFORM_OS" in
    macos) printf '%s\n' "$USER_HOME/Library/pnpm" ;;
    *) printf '%s\n' "$USER_HOME/.local/share/pnpm" ;;
  esac
}

# Print the pnpm command to use: the user copy first, then a pnpm on PATH.
# Fail quietly when no pnpm exists.
pnpm_cmd() {
  if [ -x "$(pnpm_home_dir)/bin/pnpm" ]; then
    printf '%s\n' "$(pnpm_home_dir)/bin/pnpm"
  else
    command -v pnpm
  fi
}

# Put the user pnpm on PATH for this run when it exists.
pnpm_path_add() {
  if [ -x "$(pnpm_home_dir)/bin/pnpm" ]; then
    path_prepend "$(pnpm_home_dir)/bin"
  fi
}

tool_pnpm_present() {
  [ -x "$(pnpm_home_dir)/bin/pnpm" ]
}

# The pnpm installer always runs "pnpm setup", which edits a shell rc file
# and has no opt-out. pnpm picks the rc file from BASH_VERSION, ZSH_VERSION,
# FISH_VERSION, or NU_VERSION in the environment, then from SHELL. With these
# unset and SHELL=/bin/sh, pnpm writes its block into the file that ENV names:
# a throwaway file in the cache. Non-interactive sh does not read ENV.
tool_pnpm_install() {
  local home installer

  home="$(pnpm_home_dir)"
  installer="$(cache_file pnpm-install.sh)"
  download https://get.pnpm.io/install.sh "$installer" || return 1
  run env -u BASH_VERSION -u ZSH_VERSION -u FISH_VERSION -u NU_VERSION \
    SHELL=/bin/sh "ENV=$(cache_file pnpm-setup.rc)" "PNPM_HOME=$home" \
    sh "$installer" || return 1
  path_prepend "$home/bin"
}

tool_pnpm_store_present() {
  local pnpm value

  pnpm="$(pnpm_cmd)" || return 1
  value="$("$pnpm" config get --global virtualStoreType 2>/dev/null)" || return 1
  [ "$value" = global ]
}

# Never set extendNodePath here.
tool_pnpm_store_install() {
  local pnpm

  pnpm_path_add
  require_cmd pnpm pnpm || return 1
  # A dry run with pnpm only planned has no pnpm path yet.
  pnpm="$(pnpm_cmd)" || pnpm=pnpm
  run "$pnpm" config set --global virtualStoreType global
}
