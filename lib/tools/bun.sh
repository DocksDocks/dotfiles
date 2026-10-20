# shellcheck shell=bash
# Tools: Bun, the docks-kit global package, and "docks-kit sync omp".
# Cross-OS. The functions use USER_HOME, never HOME.

# BUN_INSTALL for this installer.
bun_dir() {
  printf '%s\n' "$USER_HOME/.bun"
}

# Print the bun command to use: the user copy first, then a bun on PATH.
# Fail quietly when no bun exists.
bun_cmd() {
  if [ -x "$(bun_dir)/bin/bun" ]; then
    printf '%s\n' "$(bun_dir)/bin/bun"
  else
    command -v bun
  fi
}

# Put the user bun directory on PATH for this run when bun exists. Global bun
# packages (docks-kit) also go into this directory.
bun_path_add() {
  if [ -x "$(bun_dir)/bin/bun" ]; then
    path_prepend "$(bun_dir)/bin"
  fi
}

tool_bun_present() {
  [ -x "$(bun_dir)/bin/bun" ]
}

tool_bun_install() {
  local dir installer

  dir="$(bun_dir)"
  installer="$(cache_file bun-install.sh)"
  if [ -e /usr/bin/bun ]; then
    warn "/usr/bin/bun exists; it breaks 'bun upgrade'. Remove it by hand."
  fi
  download https://bun.sh/install "$installer" || return 1
  # The bun installer has no opt-out for rc file edits. With SHELL=/bin/sh it
  # only prints the PATH hint and edits no rc file.
  run env SHELL=/bin/sh "BUN_INSTALL=$dir" bash "$installer" || return 1
  path_prepend "$dir/bin"
}

tool_docks_kit_present() {
  [ -e "$(bun_dir)/bin/docks-kit" ]
}

tool_docks_kit_install() {
  local bun dir

  dir="$(bun_dir)"
  bun_path_add
  require_cmd bun bun || return 1
  # A dry run with bun only planned has no bun path yet.
  bun="$(bun_cmd)" || bun=bun
  # BUN_INSTALL keeps the package in the directory that
  # tool_docks_kit_present checks.
  run env "BUN_INSTALL=$dir" "$bun" install -g docks-kit || return 1
  path_prepend "$dir/bin"
}

# The sync is idempotent and runs on each install, so it is never present.
# It returns RC_SYNCED, so the summary does not list a routine sync as new.
tool_docks_kit_sync_present() {
  return 1
}

# A routine sync prints its output only when the output reports a problem.
# The full output of the last run stays in the cache as docks-kit-sync.log.
tool_docks_kit_sync_install() {
  local log_file

  bun_path_add
  omp_path_add
  require_cmd docks-kit docks-kit || return 1
  require_cmd omp omp || return 1
  require_cmd git git || return 1
  if [ "$DRY_RUN" = 1 ]; then
    run docks-kit sync omp || return 1
    return "$RC_SYNCED"
  fi
  log_file="$(cache_file docks-kit-sync.log)"
  mkdir -p "$CACHE_DIR" || return 1
  if ! docks-kit sync omp >"$log_file" 2>&1; then
    out_flush
    cat "$log_file"
    return 1
  fi
  if grep -Eiq 'warn|skip|error|fail' "$log_file"; then
    out_flush
    cat "$log_file"
  fi
  return "$RC_SYNCED"
}
