#!/usr/bin/env bash
# Start a release of this repository from your machine. The script checks the
# local clone, picks the next version, and runs the manual Release workflow on
# GitHub (.github/workflows/release.yml). The workflow tests, builds, attests,
# and publishes the release. This script never makes or pushes a tag itself.
#
# Usage: ./release.sh [--dry-run] [--yes] [patch | minor | major | vX.Y.Z]

set -euo pipefail

REPO_ROOT="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WORKFLOW=release.yml
BRANCH=main
DRY_RUN=0
ASSUME_YES=0
REQUEST='patch'

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage: ${0##*/} [--dry-run] [--yes] [patch | minor | major | vX.Y.Z]

Start the Release workflow on GitHub for the next version. The default is
patch: the latest release v1.2.3 becomes v1.2.4.

Options:
  -n, --dry-run  Show the version and the command, but start nothing.
  -y, --yes      Do not ask for a confirmation.
  -h, --help     Show this help.

The local main branch must be clean and equal to origin/main, because the
workflow releases the commit on GitHub, not the local files.
EOF
}

parse_args() {
  local arg request_set=0

  while [ "$#" -gt 0 ]; do
    arg="$1"
    shift
    case "$arg" in
      -n | --dry-run) DRY_RUN=1 ;;
      -y | --yes) ASSUME_YES=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*) die "unknown option: $arg (run ${0##*/} --help)" ;;
      *)
        [ "$request_set" = 0 ] || die "too many arguments: $arg"
        REQUEST="$arg"
        request_set=1
        ;;
    esac
  done
}

is_version() {
  printf '%s\n' "$1" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'
}

# version_gt <vA> <vB>: true when vA is a later version than vB.
version_gt() {
  local a="${1#v}" b="${2#v}" a1 a2 a3 b1 b2 b3

  IFS=. read -r a1 a2 a3 <<<"$a"
  IFS=. read -r b1 b2 b3 <<<"$b"
  a1=$((10#$a1)) a2=$((10#$a2)) a3=$((10#$a3))
  b1=$((10#$b1)) b2=$((10#$b2)) b3=$((10#$b3))
  if [ "$a1" -ne "$b1" ]; then
    [ "$a1" -gt "$b1" ]
  elif [ "$a2" -ne "$b2" ]; then
    [ "$a2" -gt "$b2" ]
  else
    [ "$a3" -gt "$b3" ]
  fi
}

require_tools() {
  command -v git >/dev/null 2>&1 || die 'git is missing'
  command -v gh >/dev/null 2>&1 || die 'the GitHub CLI (gh) is missing; install it with ./install.sh packages gh'
  gh auth status >/dev/null 2>&1 || die 'gh is not signed in; run gh auth login'
}

# The workflow releases the commit on GitHub. Local changes or unpushed
# commits would not be in the release, so they stop the script.
check_clone() {
  local branch

  branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
  [ "$branch" = "$BRANCH" ] || die "check out $BRANCH first; the current branch is $branch"
  if [ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]; then
    die 'the clone has uncommitted changes; commit or stash them first'
  fi
  git -C "$REPO_ROOT" fetch --quiet origin "$BRANCH" ||
    die "cannot fetch origin/$BRANCH"
  if [ "$(git -C "$REPO_ROOT" rev-parse HEAD)" != "$(git -C "$REPO_ROOT" rev-parse "origin/$BRANCH")" ]; then
    die "the local $BRANCH is not equal to origin/$BRANCH; push or pull first"
  fi
}

# Print the latest vX.Y.Z tag on origin, or v0.0.0 when there is none. A
# failed lookup stops the script: v0.0.0 would then propose a wrong version.
latest_version() {
  local latest=v0.0.0 refs ref tag

  refs="$(git -C "$REPO_ROOT" ls-remote --tags --refs origin 'v*')" ||
    die 'cannot read the tags of origin'
  while read -r _ ref; do
    [ -n "$ref" ] || continue
    tag="${ref#refs/tags/}"
    if is_version "$tag" && version_gt "$tag" "$latest"; then
      latest="$tag"
    fi
  done <<<"$refs"
  printf '%s\n' "$latest"
}

# next_version <latest>: the version that REQUEST asks for.
next_version() {
  local latest="$1" major minor patch

  IFS=. read -r major minor patch <<<"${latest#v}"
  case "$REQUEST" in
    patch) printf 'v%s.%s.%s\n' "$major" "$minor" "$((patch + 1))" ;;
    minor) printf 'v%s.%s.0\n' "$major" "$((minor + 1))" ;;
    major) printf 'v%s.0.0\n' "$((major + 1))" ;;
    *)
      is_version "$REQUEST" || die "the version must be patch, minor, major, or vX.Y.Z; found '$REQUEST'"
      version_gt "$REQUEST" "$latest" || die "$REQUEST is not later than the latest release $latest"
      printf '%s\n' "$REQUEST"
      ;;
  esac
}

confirm() {
  local version="$1" commit="$2" answer

  [ "$ASSUME_YES" = 1 ] && return 0
  [ -t 0 ] || die 'no terminal for the confirmation; run with --yes'
  read -r -p "Release $version from commit $commit? [y/N] " answer
  case "$answer" in
    y | Y | yes | YES) return 0 ;;
    *) die 'cancelled; nothing was started' ;;
  esac
}

# Start the workflow and print the id of the new run. Recent gh versions
# print the run URL; older ones print nothing, so the newest dispatch run of
# the commit is the fallback.
dispatch() {
  local version="$1" commit="$2" output run_id try

  output="$(gh workflow run "$WORKFLOW" --ref "$BRANCH" -f "version=$version")" ||
    die 'gh workflow run failed'
  run_id="$(printf '%s\n' "$output" | sed -n 's#.*/actions/runs/\([0-9][0-9]*\).*#\1#p' | head -n 1)"
  try=0
  while [ -z "$run_id" ] && [ "$try" -lt 10 ]; do
    sleep 3
    run_id="$(gh run list --workflow "$WORKFLOW" --event workflow_dispatch \
      --commit "$commit" --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
    try=$((try + 1))
  done
  [ -n "$run_id" ] || die "the workflow started, but its run was not found; see: gh run list --workflow $WORKFLOW"
  printf '%s\n' "$run_id"
}

main() {
  local latest version commit run_id

  parse_args "$@"
  require_tools
  check_clone
  latest="$(latest_version)"
  version="$(next_version "$latest")"
  commit="$(git -C "$REPO_ROOT" rev-parse HEAD)"

  log "Latest release: $latest"
  log "New release:    $version"
  log "Commit:         $commit ($(git -C "$REPO_ROOT" log -1 --format=%s HEAD))"
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] gh workflow run $WORKFLOW --ref $BRANCH -f version=$version"
    return 0
  fi
  confirm "$version" "$commit"

  run_id="$(dispatch "$version" "$commit")"
  log "Workflow run: $run_id"
  if ! gh run watch "$run_id" --exit-status --compact; then
    die "the release workflow failed; see: gh run view $run_id --log-failed"
  fi
  log "Released $version: $(gh release view "$version" --json url --jq .url)"
}

# The last line calls main, so a partial copy of this file cannot run.
main "$@"
