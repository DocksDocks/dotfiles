#!/usr/bin/env bash
# Install the packages, the shared shell profile, and the Git hooks of this
# repository on Ubuntu 26.04 or later and on macOS. Run with --help for usage.
# The work is idempotent: a second run finds each item present and skips it.

set -euo pipefail

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# A Rosetta 2 shell on Apple silicon runs x86_64 code, and Homebrew refuses to
# run in /opt/homebrew under Rosetta. Restart this script as native arm64 code.
if [ "$(uname -s)" = Darwin ] &&
  [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = 1 ]; then
  exec /usr/bin/arch -arm64 /bin/bash "$REPO_ROOT/install.sh" "$@"
fi

# These libraries only define functions and constants. They load before the
# guards, because the guards use die and --help lists the package ids.
# shellcheck source=lib/core.sh
. "$REPO_ROOT/lib/core.sh"
# shellcheck source=lib/platform.sh
. "$REPO_ROOT/lib/platform.sh"
# shellcheck source=lib/report.sh
. "$REPO_ROOT/lib/report.sh"
# shellcheck source=lib/registry.sh
. "$REPO_ROOT/lib/registry.sh"

DRY_RUN=0
COMMAND=''
SHOW_HELP=0
PACKAGE_IDS=()
USER_HOME=''
CACHE_DIR=''
RUN_TIMESTAMP=''

# Print the ids as words on lines of at most 76 characters.
print_wrapped_ids() {
  local id line='  '

  while IFS= read -r id; do
    if [ "${#line}" -gt 2 ] && [ $((${#line} + ${#id} + 1)) -gt 76 ]; then
      printf '%s\n' "$line"
      line='  '
    fi
    if [ "$line" = '  ' ]; then
      line="$line$id"
    else
      line="$line $id"
    fi
  done < <(registry_ids)
  printf '%s\n' "$line"
}

usage() {
  local name="${0##*/}"

  cat <<EOF
Usage: $name [--dry-run|-n] [all | packages [id...] | shell | hooks | list]
       $name --help

Commands:
  all       Enable the Git hooks, install all packages, and wire the shell
            profile. This is the default.
  packages  Install all packages, or only the given ids.
  shell     Wire the shared shell profile into the shell rc files.
  hooks     Enable the Git hooks of this repository (.githooks).
  list      Show the packages and the install method on this platform.

Options:
  -n, --dry-run  Show the commands, but make no changes.
  -h, --help     Show this help.

Environment (only with --dry-run or the shell command):
  DOTFILES_OS=ubuntu|macos    Use this OS instead of the detected OS.
  DOTFILES_ARCH=amd64|arm64   Use this CPU architecture instead of the
                              detected architecture.

Package ids (install order):
EOF
  print_wrapped_ids
}

usage_error() {
  printf 'error: %s\n' "$*" >&2
  printf 'Run %s --help for usage.\n' "${0##*/}" >&2
  exit 2
}

parse_args() {
  local arg

  while [ "$#" -gt 0 ]; do
    arg="$1"
    shift
    case "$arg" in
      -n | --dry-run) DRY_RUN=1 ;;
      -h | --help) SHOW_HELP=1 ;;
      -*) usage_error "unknown option: $arg" ;;
      *)
        if [ -z "$COMMAND" ]; then
          case "$arg" in
            all | packages | shell | hooks | list) COMMAND="$arg" ;;
            *) usage_error "unknown command: $arg" ;;
          esac
        elif [ "$COMMAND" = packages ]; then
          registry_has_id "$arg" || usage_error "unknown package id: $arg"
          PACKAGE_IDS[${#PACKAGE_IDS[@]}]="$arg"
        else
          usage_error "the $COMMAND command takes no arguments: $arg"
        fi
        ;;
    esac
  done
  if [ -z "$COMMAND" ]; then
    COMMAND=all
  fi
}

# The installer uses sudo for each privileged step. A root run would create
# root-owned files in the user's home and install user tools for root.
refuse_root() {
  if [ "$(id -u)" = 0 ]; then
    die 'do not run this installer as root; run it as your user (it uses sudo when necessary)'
  fi
}

# This is the only place that reads HOME. All other code uses USER_HOME, so a
# bad HOME cannot send writes to an unexpected directory.
validate_home() {
  local raw="${HOME:-}" home

  home="$raw"
  while :; do
    case "$home" in
      */) home="${home%/}" ;;
      *) break ;;
    esac
  done
  case "$home" in
    /?*) ;;
    *) die "HOME must be an absolute path other than /; found '$raw'" ;;
  esac
  [ -d "$home" ] || die "HOME is not a directory: $home"
  [ -O "$home" ] || die "HOME is not owned by the current user: $home"
  USER_HOME="$home"
}

record_success() {
  if [ "$DRY_RUN" = 1 ]; then
    record_result "$1" "$2" planned "$3"
  else
    record_result "$1" "$2" installed "$3"
  fi
}

install_git_hooks() {
  local id=hooks label='Git hooks (.githooks)' current

  defer_step "$label"
  # A release archive has no .git, so 'all' has no hooks to set there. The
  # explicit hooks command still fails outside a Git working tree.
  if [ "$COMMAND" = all ] && [ ! -e "$REPO_ROOT/.git" ]; then
    quiet_add "$id (n/a)"
    record_result "$id" "$label" n/a - 'not a Git working tree'
    return 0
  fi
  if ! require_cmd git git; then
    record_result "$id" "$label" failed - 'git is missing'
    return 0
  fi
  # In a dry-run git can be a planned package only, so the checks need git.
  if have git; then
    if ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      warn "$REPO_ROOT is not a Git working tree"
      record_result "$id" "$label" failed - 'not a Git working tree'
      return 0
    fi
    current="$(git -C "$REPO_ROOT" config --local --get core.hooksPath || true)"
    if [ "$current" = .githooks ]; then
      quiet_add "$id"
      record_result "$id" "$label" present -
      return 0
    fi
  fi
  if run git -C "$REPO_ROOT" config --local core.hooksPath .githooks; then
    log "Hooks path: $REPO_ROOT/.githooks"
    record_success "$id" "$label" -
  else
    record_result "$id" "$label" failed - 'git config failed'
  fi
}

prepare_os() {
  defer_step "Prerequisites for $PLATFORM_OS"
  if ! os_prepare; then
    warn 'the OS prerequisites failed; the run continues'
    record_result prepare "OS prerequisites ($PLATFORM_OS)" failed -
  fi
  end_step
}

wire_shell_profile() {
  if ! install_shell_profile; then
    warn 'the shell profile wiring failed'
    record_result shell 'Shell profile' failed - 'see the warnings above'
  fi
}

run_command() {
  case "$COMMAND" in
    all)
      install_git_hooks
      end_step
      prepare_os
      install_packages
      wire_shell_profile
      ;;
    packages)
      prepare_os
      install_packages ${PACKAGE_IDS[@]+"${PACKAGE_IDS[@]}"}
      ;;
    shell) wire_shell_profile ;;
    hooks)
      install_git_hooks
      end_step
      ;;
    list) registry_list ;;
  esac
}

color_init
parse_args "$@"
if [ "$SHOW_HELP" = 1 ]; then
  usage
  exit 0
fi
refuse_root
validate_home
CACHE_DIR="$USER_HOME/.cache/dotfiles-install"
RUN_TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
detect_platform "$COMMAND"

# Sourced at the top level, not in a function: a declare in a sourced file
# would make a local variable of that function.
# shellcheck source=lib/shell.sh
. "$REPO_ROOT/lib/shell.sh"
for tool_file in "$REPO_ROOT"/lib/tools/*.sh; do
  # An unmatched glob stays as the pattern when no tool file exists.
  [ -e "$tool_file" ] || continue
  # shellcheck source=/dev/null  # The glob selects the files; each file is linted alone.
  . "$tool_file"
done
unset tool_file
[ -r "$REPO_ROOT/lib/os/$PLATFORM_OS.sh" ] || die "missing OS adapter: lib/os/$PLATFORM_OS.sh"
# shellcheck source=/dev/null  # PLATFORM_OS selects the adapter; each adapter is linted alone.
. "$REPO_ROOT/lib/os/$PLATFORM_OS.sh"

log "Platform: $(platform_describe)"
if [ "$COMMAND" = list ]; then
  run_command
  exit 0
fi
if [ "$DRY_RUN" = 1 ]; then
  log 'Dry-run: the commands show, but nothing changes.'
fi
run_command
print_summary
print_tern_hint
if report_has_failures; then
  exit 1
fi
exit 0
