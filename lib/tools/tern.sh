# shellcheck shell=bash
# Tern (Stencil Labs) is invite only: its builds need a Stencil sign-in, so
# the installer cannot download it. The run ends with the download link only
# when Tern is missing.

TERN_DOWNLOAD_URL='https://build.stencil.so/tern'
TERN_WAITLIST_URL='https://stencil.so/tern'

# Linux: the portable build links `tern` into ~/.local/bin and registers the
# desktop entry so.stencil.tern. macOS: the app bundle in an Applications
# folder.
tern_present() {
  if have tern || [ -x "$USER_HOME/.local/bin/tern" ]; then
    return 0
  fi
  if [ -e "$USER_HOME/.local/share/applications/so.stencil.tern.desktop" ]; then
    return 0
  fi
  if [ -d /Applications/Tern.app ] || [ -d "$USER_HOME/Applications/Tern.app" ]; then
    return 0
  fi
  return 1
}

print_tern_hint() {
  if tern_present; then
    return 0
  fi
  printf '\n'
  paint out 33 'Tern (Stencil Labs) is missing. It is invite only; download it by hand:'
  printf '\n  '
  osc8_link "$TERN_DOWNLOAD_URL"
  printf '  Waitlist: '
  osc8_link "$TERN_WAITLIST_URL"
}
