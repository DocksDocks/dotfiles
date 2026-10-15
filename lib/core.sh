# shellcheck shell=bash
# Core helpers for the entry point, the OS adapters, and the tools.
# install.sh sets REPO_ROOT, DRY_RUN, USER_HOME, CACHE_DIR, and RUN_TIMESTAMP
# before it calls a function from this file.

# Return codes of an installer beyond 0 (installed) and 1 (failed).
# RC_UNSUPPORTED: the package is not supported on this platform or
# architecture. RC_SYNCED: a step that runs on every run (a sync) finished; it
# is routine work, so the summary does not count it as new.
# shellcheck disable=SC2034  # The dispatcher and the adapters read these values.
RC_UNSUPPORTED=3
# shellcheck disable=SC2034  # The dispatcher and the tools read this value.
RC_SYNCED=4

# Bookkeeping for one run. The ids list has a space before and after each id,
# so that a pattern match finds a full id only.
PLANNED_IDS=' '
SUDO_READY=0

# Colors apply only on a terminal. NO_COLOR (https://no-color.org/) and
# TERM=dumb turn them off. color_init sets the flags once, so that paint also
# works inside a command substitution, where stdout is a pipe.
COLOR_OUT=0
COLOR_ERR=0

# Output layout. Unchanged items (present, not applicable, routine syncs)
# share one line that grows until other output starts. A package step gets
# its "==>" header only when it prints something, so a silent step adds to
# that line instead. out_flush closes the line and prints a pending header;
# every output helper calls it first.
QUIET_LINE_OPEN=0
QUIET_LINE_LEN=0
QUIET_LINE_WIDTH=100
PENDING_STEP=''

color_init() {
  local columns

  if [ -t 1 ]; then
    columns="$(tput cols 2>/dev/null || true)"
    case "$columns" in
      '' | *[!0-9]*) ;;
      *) [ "$columns" -lt 40 ] || QUIET_LINE_WIDTH="$columns" ;;
    esac
  fi
  if [ -n "${NO_COLOR:-}" ] || [ "${TERM:-dumb}" = dumb ]; then
    return 0
  fi
  if [ -t 1 ]; then
    COLOR_OUT=1
  fi
  if [ -t 2 ]; then
    COLOR_ERR=1
  fi
}

# paint <out|err> <SGR code> <text>: print the text without a newline, in
# color when that stream shows colors.
paint() {
  local enabled="$COLOR_OUT"

  if [ "$1" = err ]; then
    enabled="$COLOR_ERR"
  fi
  if [ "$enabled" = 1 ]; then
    printf '\033[%sm%s\033[0m' "$2" "$3"
  else
    printf '%s' "$3"
  fi
}

# SGR color of a result status: green is new, cyan is planned, dim is
# unchanged, yellow needs a manual install, red failed.
status_color() {
  case "$1" in
    installed) printf '32' ;;
    planned) printf '36' ;;
    unsupported) printf '33' ;;
    failed) printf '31' ;;
    *) printf '2' ;;
  esac
}

# Only the main shell owns the layout. In a command substitution, stdout is
# the captured value, so a newline or a header there would corrupt the value.
out_flush() {
  local header

  if [ "$BASH_SUBSHELL" -ne 0 ]; then
    return 0
  fi
  if [ "$QUIET_LINE_OPEN" = 1 ]; then
    printf '\n'
    QUIET_LINE_OPEN=0
    QUIET_LINE_LEN=0
  fi
  if [ -n "$PENDING_STEP" ]; then
    header="$PENDING_STEP"
    PENDING_STEP=''
    paint out 1 "==> $header"
    printf '\n'
  fi
}

# Set the header of the next step. It prints with the first output of the
# step; a step without output never shows it.
defer_step() {
  PENDING_STEP="$*"
}

# Drop the header of a step that printed nothing, so that it cannot appear
# above the output of a later step.
end_step() {
  PENDING_STEP=''
}

# quiet_add <item>: add an unchanged item to the shared "Already present"
# line. The line wraps before the terminal edge.
quiet_add() {
  local item="$1" sep prefix='Already present:'

  PENDING_STEP=''
  if [ "$QUIET_LINE_OPEN" = 0 ]; then
    paint out 32 '✓'
    printf ' '
    paint out 2 "$prefix"
    QUIET_LINE_OPEN=1
    QUIET_LINE_LEN=$((${#prefix} + 2))
    sep=' '
  else
    sep=', '
  fi
  if [ $((QUIET_LINE_LEN + ${#sep} + ${#item})) -gt "$QUIET_LINE_WIDTH" ]; then
    paint out 2 ','
    printf '\n'
    sep='  '
    QUIET_LINE_LEN=0
  fi
  paint out 2 "$sep$item"
  QUIET_LINE_LEN=$((QUIET_LINE_LEN + ${#sep} + ${#item}))
}

log() {
  out_flush
  printf '%s\n' "$*"
}

# log_status <status> <message>: one log line in the color of the status.
log_status() {
  out_flush
  paint out "$(status_color "$1")" "$2"
  printf '\n'
}

warn() {
  out_flush
  paint err 33 'warning:' >&2
  printf ' %s\n' "$*" >&2
}

die() {
  out_flush
  paint err 31 'error:' >&2
  printf ' %s\n' "$*" >&2
  exit 1
}

step() {
  out_flush
  paint out 1 "==> $*"
  printf '\n'
}

have() {
  command -v "$1" >/dev/null 2>&1
}

# Print a command in a form that a user can copy into a shell.
print_dry_run() {
  out_flush
  printf '[dry-run]'
  printf ' %q' "$@"
  printf '\n'
}

# Real commands write their own output, so the step header comes first.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    print_dry_run "$@"
    return 0
  fi
  out_flush
  "$@"
}

# Ask for the sudo password once, at the first privileged step. A run that
# needs no privileged step never asks.
ensure_sudo() {
  if [ "$SUDO_READY" = 1 ]; then
    return 0
  fi
  have sudo || die 'sudo is missing; install sudo or run the privileged steps by hand'
  # The password prompt must start on its own line, under the step header.
  out_flush
  sudo -v || return 1
  SUDO_READY=1
}

run_sudo() {
  if [ "$DRY_RUN" = 1 ]; then
    print_dry_run sudo "$@"
    return 0
  fi
  ensure_sudo || return 1
  out_flush
  sudo "$@"
}

# Read-only GET to stdout. This also runs in dry-run, because the planned
# commands can depend on metadata such as the latest release tag.
fetch() {
  if ! have curl; then
    warn "curl is missing; cannot fetch $1"
    return 1
  fi
  curl -fsSL --retry 3 "$1"
}

cache_file() {
  printf '%s/%s\n' "$CACHE_DIR" "$1"
}

# Download into the cache only. A fixed file name in the cache is overwritten
# on each run, so the cache does not grow and nothing must be deleted.
download() {
  local url="$1" dest="$2"

  case "$dest" in
    */../* | */..)
      warn "download target must not contain '..': $dest"
      return 1
      ;;
    "$CACHE_DIR"/?*) ;;
    *)
      warn "download target must be under $CACHE_DIR: $dest"
      return 1
      ;;
  esac
  if [ "$DRY_RUN" = 1 ]; then
    print_dry_run curl -fsSL --retry 3 -o "$dest" "$url"
    return 0
  fi
  if ! have curl; then
    warn "curl is missing; cannot download $url"
    return 1
  fi
  mkdir -p "${dest%/*}" || return 1
  curl -fsSL --retry 3 -o "$dest" "$url"
}

backup_path() {
  printf '%s.backup.%s\n' "$1" "$RUN_TIMESTAMP"
}

# Keep the first backup of this run. A second backup in the same run would
# overwrite the copy of the original file with an already changed file.
backup_file() {
  local path="$1" backup

  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  backup="$(backup_path "$path")"
  if [ -e "$backup" ]; then
    return 0
  fi
  run cp -p "$path" "$backup"
}

# System backups end in .bak: apt silently ignores that suffix in
# /etc/apt/sources.list.d, but warns on every update about other suffixes.
backup_file_sudo() {
  local path="$1" backup

  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 0
  fi
  backup="$(backup_path "$path").bak"
  if [ -e "$backup" ]; then
    return 0
  fi
  run_sudo cp -p "$path" "$backup"
}

path_prepend() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *)
      PATH="$1:$PATH"
      export PATH
      ;;
  esac
}

mark_planned() {
  if ! is_planned "$1"; then
    PLANNED_IDS="$PLANNED_IDS$1 "
  fi
}

is_planned() {
  case "$PLANNED_IDS" in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

# A dry-run does not install anything, so a command from an earlier planned
# package is missing. The planned id stands in for the command then.
require_cmd() {
  local cmd="$1" id="$2"

  if have "$cmd"; then
    return 0
  fi
  if [ "$DRY_RUN" = 1 ] && is_planned "$id"; then
    return 0
  fi
  warn "$cmd is missing; install $id first"
  return 1
}

# Terminals without OSC 8 support show the text only, so a text other than the
# URL gets the plain URL in parentheses. When the text is the URL itself, the
# visible text already is the fallback. Logs and pipes get the plain URL only.
osc8_link() {
  local url="$1" text="${2:-$1}" st=$'\033\\'

  if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then
    printf '\033]8;;%s%s%s\033]8;;%s' "$url" "$st" "$text" "$st"
    if [ "$text" != "$url" ]; then
      printf ' (%s)' "$url"
    fi
    printf '\n'
  else
    printf '%s\n' "$url"
  fi
}
