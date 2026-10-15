# shellcheck shell=sh
# Shared interactive shell profile for bash and zsh (POSIX sh syntax).
# install.sh builds ~/.docks_profile from this file: it puts the content of
# profile.linux.sh or profile.macos.sh in place of the @os-profile@ line.

# Put an existing directory first in PATH. An earlier copy of the directory
# is removed, so PATH never gets a duplicate and the precedence stays fixed
# (for example when ~/.profile already added ~/.local/bin).
_dotfiles_path_prepend() {
  [ -d "$1" ] || return 0
  _dotfiles_path=":$PATH:"
  case "$_dotfiles_path" in
    *":$1:"*)
      _dotfiles_path="${_dotfiles_path%%:"$1":*}:${_dotfiles_path#*:"$1":}"
      ;;
  esac
  _dotfiles_path="${_dotfiles_path#:}"
  _dotfiles_path="${_dotfiles_path%:}"
  PATH="$1${_dotfiles_path:+:$_dotfiles_path}"
}

# Append a directory to PATH when it exists and is not in PATH yet.
_dotfiles_path_append() {
  [ -d "$1" ] || return 0
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="${PATH:+$PATH:}$1" ;;
  esac
}

# OS-specific settings. They set PNPM_HOME, and ANDROID_HOME when the SDK exists.
# @os-profile@

# Android SDK tools (after the system tools).
if [ -n "${ANDROID_HOME:-}" ]; then
  _dotfiles_path_append "$ANDROID_HOME/cmdline-tools/latest/bin"
  _dotfiles_path_append "$ANDROID_HOME/platform-tools"
  _dotfiles_path_append "$ANDROID_HOME/emulator"
fi

# Secrets stay outside the repository.
# shellcheck source=/dev/null # The file is user-specific and not in the repository.
[ -r "$HOME/.config/secrets.env" ] && . "$HOME/.config/secrets.env"

# ENABLE_CLAUDEAI_MCP_SERVERS is not set here: `docks-kit sync claude` owns it
# and appends it to the shell rc file when no rc file names it.
alias clauded='claude --dangerously-skip-permissions'
alias claude='claude --thinking-display summarized'
alias pf='cd "$HOME/projects"'

# PATH. The last prepend wins: bun > pnpm > ~/.local/bin > opencode.
export BUN_INSTALL="$HOME/.bun"
_dotfiles_path_prepend "$HOME/.opencode/bin"
_dotfiles_path_prepend "$HOME/.local/bin"
if [ -n "${PNPM_HOME:-}" ]; then
  _dotfiles_path_prepend "$PNPM_HOME/bin"
fi
_dotfiles_path_prepend "$BUN_INSTALL/bin"
export PATH

# nvm
export NVM_DIR="$HOME/.nvm"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  # shellcheck source=/dev/null # nvm is installed at run time.
  . "$NVM_DIR/nvm.sh"
fi
if [ -n "${BASH_VERSION:-}" ] && [ -s "$NVM_DIR/bash_completion" ]; then
  # shellcheck source=/dev/null # nvm is installed at run time.
  . "$NVM_DIR/bash_completion"
fi

# rokit
if [ -r "$HOME/.rokit/env" ]; then
  # shellcheck source=/dev/null # rokit is installed at run time.
  . "$HOME/.rokit/env"
fi

unset _dotfiles_path
unset -f _dotfiles_path_prepend _dotfiles_path_append
