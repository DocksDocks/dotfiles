# shellcheck shell=sh
# Linux-only interactive settings. install.sh copies this file into
# ~/.docks_profile in place of the @os-profile@ line of profile.sh.

# pnpm
export PNPM_HOME="$HOME/.local/share/pnpm"

# Android SDK. profile.sh adds its tool directories to PATH.
if [ -d "$HOME/Android/Sdk" ]; then
  export ANDROID_HOME="$HOME/Android/Sdk"
fi

# Android emulator aliases
if [ -f "$HOME/projects/android-in-linux/start.sh" ]; then
  alias android-start='"$HOME/projects/android-in-linux/start.sh"'
fi
if [ -f "$HOME/projects/android-in-linux/kill.sh" ]; then
  alias android-kill='"$HOME/projects/android-in-linux/kill.sh"'
fi

# Rootless Docker socket for tools that ignore docker contexts.
_dotfiles_docker_sock="/run/user/$(id -u)/docker.sock"
if [ -S "$_dotfiles_docker_sock" ]; then
  export DOCKER_HOST="unix://$_dotfiles_docker_sock"
fi
unset _dotfiles_docker_sock

# VTE terminal integration (Tilix, GNOME Terminal).
if [ -n "${TILIX_ID:-}" ] || [ -n "${VTE_VERSION:-}" ]; then
  for _dotfiles_vte in /etc/profile.d/vte-2.91.sh /etc/profile.d/vte.sh; do
    if [ -r "$_dotfiles_vte" ]; then
      # shellcheck source=/dev/null # The file belongs to the system.
      . "$_dotfiles_vte"
      break
    fi
  done
  unset _dotfiles_vte
fi
