# shellcheck shell=bash
# Tool: omp (oh-my-pi) through the official installer. Cross-OS.
# A Tern-managed omp does not count: Tern keeps that copy for its own
# processes, and "omp update" refuses to update it.

omp_tern_dir() {
  printf '%s\n' "$USER_HOME/.local/share/tern"
}

# True when an executable omp exists in a PATH directory outside the Tern
# directory. Quiet and read-only.
omp_on_path_outside_tern() {
  local dir tern
  local -a dirs

  tern="$(omp_tern_dir)/"
  IFS=: read -r -a dirs <<<"$PATH"
  for dir in ${dirs[@]+"${dirs[@]}"}; do
    [ -n "$dir" ] || continue
    case "$dir/" in
      "$tern"*) continue ;;
    esac
    if [ -f "$dir/omp" ] && [ -x "$dir/omp" ]; then
      return 0
    fi
  done
  return 1
}

# Put the user omp directories on PATH for this run when omp exists there.
# The bun directory goes first, as in the shell profile.
omp_path_add() {
  if [ -x "$(local_bin_dir)/omp" ]; then
    path_prepend "$(local_bin_dir)"
  fi
  if [ -x "$(bun_dir)/bin/omp" ]; then
    path_prepend "$(bun_dir)/bin"
  fi
}

tool_omp_present() {
  [ -x "$(bun_dir)/bin/omp" ] && return 0
  [ -x "$(local_bin_dir)/omp" ] && return 0
  omp_on_path_outside_tern
}

# The installer runs "bun install -g" when bun 1.3.14 or newer is on PATH,
# else it installs a checksum-verified binary into PI_INSTALL_DIR. It edits
# no rc file. BUN_INSTALL and PI_INSTALL_DIR keep omp in the directories that
# tool_omp_present checks.
tool_omp_install() {
  local installer

  installer="$(cache_file omp-install.sh)"
  bun_path_add
  download https://omp.sh/install "$installer" || return 1
  run env "BUN_INSTALL=$(bun_dir)" "PI_INSTALL_DIR=$(local_bin_dir)" sh "$installer" || return 1
  path_prepend "$(local_bin_dir)"
  path_prepend "$(bun_dir)/bin"
}
