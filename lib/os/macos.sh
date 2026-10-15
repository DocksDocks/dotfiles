# shellcheck shell=bash
# macOS adapter: Homebrew prerequisite and the formula and cask methods.
# Sourced by install.sh after lib/core.sh. Uses the core API and the
# globals DRY_RUN, USER_HOME, PLATFORM_ARCH and RC_UNSUPPORTED.

HOMEBREW_INSTALL_URL='https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh'
HOMEBREW_PAGE_URL='https://brew.sh/'
HOMEBREW_ARM64_BIN='/opt/homebrew/bin/brew'
HOMEBREW_INTEL_BIN='/usr/local/bin/brew'

# 1 when brew is missing and this Mac cannot get it from the official installer.
MACOS_BREW_UNSUPPORTED=0

# Prints the absolute path of brew. Returns 1 when brew is missing. Quiet.
brew_bin() {
  local found
  found=$(command -v brew 2>/dev/null) || found=''
  case "$found" in
    /*)
      printf '%s\n' "$found"
      return 0
      ;;
  esac
  if [ -x "$HOMEBREW_ARM64_BIN" ]; then
    printf '%s\n' "$HOMEBREW_ARM64_BIN"
    return 0
  fi
  if [ -x "$HOMEBREW_INTEL_BIN" ]; then
    printf '%s\n' "$HOMEBREW_INTEL_BIN"
    return 0
  fi
  return 1
}

# Loads the brew environment (PATH, HOMEBREW_PREFIX, ...) into this run.
brew_shellenv() {
  local brew="$1" env_script
  if ! env_script=$("$brew" shellenv bash); then
    warn "cannot read the Homebrew environment from $brew"
    return 1
  fi
  eval "$env_script"
}

# Records that Homebrew is not available on an Intel Mac. Warns one time.
brew_mark_unsupported() {
  if [ "$MACOS_BREW_UNSUPPORTED" = 1 ]; then
    return 0
  fi
  MACOS_BREW_UNSUPPORTED=1
  warn "Homebrew is missing. The official installer supports only Apple Silicon," \
    "so this installer does not install Homebrew on Intel Macs." \
    "Formula and cask packages are unsupported. See $HOMEBREW_PAGE_URL"
}

# Installs Homebrew on Apple Silicon. The official script also installs the
# Xcode Command Line Tools. NONINTERACTIVE makes it use "sudo -n", so the
# sudo credentials must be cached before it starts.
homebrew_install() {
  local installer
  installer=$(cache_file homebrew-install.sh) || return 1
  if [ "$DRY_RUN" = 1 ]; then
    log "Homebrew is missing. Plan: install it to /opt/homebrew (with the Xcode Command Line Tools)."
  else
    ensure_sudo || return 1
  fi
  download "$HOMEBREW_INSTALL_URL" "$installer" || return 1
  run env NONINTERACTIVE=1 /bin/bash "$installer" || return 1
  if [ "$DRY_RUN" = 1 ]; then
    mark_planned homebrew
    return 0
  fi
  if [ ! -x "$HOMEBREW_ARM64_BIN" ]; then
    warn "the Homebrew installer finished, but $HOMEBREW_ARM64_BIN is missing"
    return 1
  fi
  brew_shellenv "$HOMEBREW_ARM64_BIN"
}

# Returns 0 when brew can run (or is planned in dry-run), RC_UNSUPPORTED on an
# Intel Mac without brew, 1 otherwise.
brew_ready() {
  if [ "$MACOS_BREW_UNSUPPORTED" = 1 ]; then
    return "$RC_UNSUPPORTED"
  fi
  require_cmd brew homebrew
}

# Adapter interface -----------------------------------------------------------

os_prepare() {
  local brew
  # A present brew is the normal case, so it prints nothing.
  if brew=$(brew_bin); then
    brew_shellenv "$brew" || return 1
    return 0
  fi
  if [ "$PLATFORM_ARCH" != arm64 ]; then
    brew_mark_unsupported
    return 0
  fi
  homebrew_install
}

os_rc_files() {
  printf '%s\n' "$USER_HOME/.zshrc" "$USER_HOME/.bash_profile"
}

# Always false on macOS. /usr/bin holds stubs (for example git) that only
# offer to install the Xcode Command Line Tools, so "command -v" does not
# prove that a tool is installed.
os_has_command() {
  return 1
}

# Method: formula <token> ----------------------------------------------------

method_formula_present() {
  local token="${1:-}" brew
  [ -n "$token" ] || return 1
  brew=$(brew_bin) || return 1
  "$brew" list --formula "$token" >/dev/null 2>&1
}

method_formula_install() {
  local token="${1:-}"
  if [ -z "$token" ]; then
    warn 'formula: the spec has no token'
    return 1
  fi
  brew_ready || return $?
  run brew install "$token"
}

# Method: cask <token> <App Name>.app ------------------------------------------
# The words after the token form the app bundle name (it can contain spaces).

method_cask_present() {
  local token="${1:-}" app brew
  [ -n "$token" ] || return 1
  shift
  if [ "$#" -gt 0 ]; then
    app=$(cask_app_name "$@")
    if [ -e "/Applications/$app" ] || [ -e "$USER_HOME/Applications/$app" ]; then
      return 0
    fi
  fi
  brew=$(brew_bin) || return 1
  "$brew" list --cask "$token" >/dev/null 2>&1
}

method_cask_install() {
  local token="${1:-}"
  if [ -z "$token" ]; then
    warn 'cask: the spec has no token'
    return 1
  fi
  brew_ready || return $?
  run brew install --cask "$token"
}

# Joins the app name words with single spaces, independent of the caller IFS.
cask_app_name() {
  local IFS=' '
  printf '%s' "$*"
}
