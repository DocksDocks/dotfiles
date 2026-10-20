# shellcheck shell=bash
# Tools: uv (standalone installer) and the newest stable CPython through uv.
# Cross-OS. The functions use USER_HOME, never HOME.

# The user binary directory. uv, the uv Python links, omp, and Composer go
# here.
local_bin_dir() {
  printf '%s\n' "$USER_HOME/.local/bin"
}

# Print the uv command to use: the user copy first, then a uv on PATH.
# Fail quietly when no uv exists.
uv_cmd() {
  if [ -x "$(local_bin_dir)/uv" ]; then
    printf '%s\n' "$(local_bin_dir)/uv"
  else
    command -v uv
  fi
}

# Put the user uv on PATH for this run when it exists.
uv_path_add() {
  if [ -x "$(local_bin_dir)/uv" ]; then
    path_prepend "$(local_bin_dir)"
  fi
}

tool_uv_present() {
  [ -x "$(local_bin_dir)/uv" ]
}

tool_uv_install() {
  local bin_dir installer

  bin_dir="$(local_bin_dir)"
  installer="$(cache_file uv-install.sh)"
  if [ -e /usr/bin/uv ]; then
    warn "/usr/bin/uv exists; it is not user-managed and 'uv self update' cannot manage it"
  fi
  download https://astral.sh/uv/install.sh "$installer" || return 1
  # UV_NO_MODIFY_PATH=1 stops the rc file edits. UV_INSTALL_DIR keeps the
  # binary in the directory that tool_uv_present checks.
  run env UV_NO_MODIFY_PATH=1 "UV_INSTALL_DIR=$bin_dir" sh "$installer" || return 1
  path_prepend "$bin_dir"
}

# Print major.minor of the newest stable CPython that uv can download.
# The pattern skips alpha, beta, and rc builds ("3.16.0a1") and free-threaded
# builds ("3.15.0+freethreaded"), because their patch number is not followed
# by "-". uv lists the newest version first.
python_latest_stable() {
  local uv version

  uv="$(uv_cmd)" || return 1
  version="$("$uv" python list --only-downloads 2>/dev/null | awk '
    !found && $1 ~ /^cpython-[0-9]+\.[0-9]+\.[0-9]+-/ {
      split(substr($1, 9), part, ".")
      print part[1] "." part[2]
      found = 1
    }')" || return 1
  [ -n "$version" ] || return 1
  printf '%s\n' "$version"
}

tool_python_present() {
  local uv version

  [ -e "$(local_bin_dir)/python3" ] || return 1
  uv="$(uv_cmd)" || return 1
  version="$(python_latest_stable)" || return 1
  "$uv" python find --managed-python "$version" >/dev/null 2>&1
}

tool_python_install() {
  local bin_dir uv version

  bin_dir="$(local_bin_dir)"
  uv_path_add
  require_cmd uv uv || return 1
  if ! uv="$(uv_cmd)"; then
    # Dry run only: the uv step is planned, so uv cannot list versions yet.
    log '[dry-run] uv python install <latest-stable> --default'
    return 0
  fi
  if ! version="$(python_latest_stable)"; then
    warn "cannot find a stable CPython in 'uv python list --only-downloads'"
    return 1
  fi
  # UV_PYTHON_BIN_DIR keeps the python and python3 links in the directory
  # that tool_python_present checks.
  run env "UV_PYTHON_BIN_DIR=$bin_dir" "$uv" python install "$version" --default || return 1
  path_prepend "$bin_dir"
}
