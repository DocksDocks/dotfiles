# shellcheck shell=sh
# macOS-only interactive settings. install.sh copies this file into
# ~/.docks_profile in place of the @os-profile@ line of profile.sh.

# Homebrew (Apple silicon first, then Intel).
for _dotfiles_brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  if [ -x "$_dotfiles_brew" ]; then
    if [ -n "${ZSH_VERSION:-}" ]; then
      eval "$("$_dotfiles_brew" shellenv zsh)"
    else
      eval "$("$_dotfiles_brew" shellenv bash)"
    fi
    break
  fi
done
unset _dotfiles_brew

# pnpm
export PNPM_HOME="$HOME/Library/pnpm"

# Android SDK. profile.sh adds its tool directories to PATH.
if [ -d "$HOME/Library/Android/sdk" ]; then
  export ANDROID_HOME="$HOME/Library/Android/sdk"
fi

# Stop the macOS notice that zsh is the default shell.
if [ -n "${BASH_VERSION:-}" ]; then
  export BASH_SILENCE_DEPRECATION_WARNING=1
fi
