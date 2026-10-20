# shellcheck shell=bash
# Tool: omp (oh-my-pi) as the official prebuilt binary. Cross-OS.
# An omp in the Tern directory does not count: Tern keeps that copy for its
# own processes, and "omp update" refuses to update it. The Tern link at
# ~/.local/bin/omp counts, so the installer never replaces it. An omp in the
# bun directory does not count either: Tern reports it as a PATH conflict.

omp_tern_dir() {
  printf '%s\n' "$USER_HOME/.local/share/tern"
}

# True when an executable omp exists in a PATH directory outside the Tern
# directory and the bun directory. Quiet and read-only.
omp_binary_on_path() {
  local dir tern bun_bin
  local -a dirs

  tern="$(omp_tern_dir)/"
  bun_bin="$(bun_dir)/bin/"
  IFS=: read -r -a dirs <<<"$PATH"
  for dir in ${dirs[@]+"${dirs[@]}"}; do
    [ -n "$dir" ] || continue
    case "$dir/" in
      "$tern"* | "$bun_bin") continue ;;
    esac
    if [ -f "$dir/omp" ] && [ -x "$dir/omp" ]; then
      return 0
    fi
  done
  return 1
}

# Put the user binary directory on PATH for this run when omp exists there.
omp_path_add() {
  if [ -x "$(local_bin_dir)/omp" ]; then
    path_prepend "$(local_bin_dir)"
  fi
}

tool_omp_present() {
  [ -x "$(local_bin_dir)/omp" ] && return 0
  omp_binary_on_path
}

# "--binary" makes the official installer download the prebuilt binary from
# build.stencil.so and check its SHA-256. It never uses bun in this mode and
# edits no rc file. PI_INSTALL_DIR keeps omp in the directory that
# tool_omp_present checks.
tool_omp_install() {
  local installer

  installer="$(cache_file omp-install.sh)"
  download https://omp.sh/install "$installer" || return 1
  run env "PI_INSTALL_DIR=$(local_bin_dir)" sh "$installer" --binary || return 1
  path_prepend "$(local_bin_dir)"
}
