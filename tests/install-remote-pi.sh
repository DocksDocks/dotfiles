#!/usr/bin/env bash

# Covers the remote-pi version floor: the installer must upgrade to the newest
# published release, keep an install that is already newer, and fall back to the
# floor when the registry is unreachable or answers with something that is not a
# version.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
installer="$repo_root/install.sh"

# Absolute, because each case runs with a PATH that holds only the sandbox.
bash_bin="$(command -v bash)"

# The only host tools a case may reach: `dirname` runs while the installer is
# sourced, `sed` reads the plugin manifest, and `install` creates the relay
# config directory in the end-to-end case. Everything else is a stub, so an
# absent npm is genuinely absent rather than the real one inherited from PATH.
host_tools=(dirname sed install)

test_root="$(mktemp -d "${TMPDIR:-/tmp}/install-remote-pi.XXXXXX")"
cleanup() {
  rm -rf -- "$test_root"
}
trap cleanup EXIT

failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

# Read the floor from the installer so a future bump does not silently
# invalidate every expectation below.
floor="$(PATH="$PATH" "$bash_bin" -c "source '$installer'; printf '%s' \"\$remote_pi_floor\"")"
if [[ -z "$floor" ]]; then
  printf 'FAIL: could not read remote_pi_floor from %s\n' "$installer" >&2
  exit 1
fi

# Builds one sandbox and echoes its bin directory.
#
# installed: manifest version, or empty for no manifest
# npm_mode:  a version to publish, `fail` for a lookup error, `absent` for no npm
# present:   whether `omp plugin list` reports remote-pi
make_sandbox() {
  local installed="$1" npm_mode="$2" present="$3"
  local case_dir bin home listed tool tool_path

  case_dir="$(mktemp -d "$test_root/case.XXXXXX")"
  bin="$case_dir/bin"
  home="$case_dir/home"
  mkdir -p "$bin" "$home"

  for tool in "${host_tools[@]}"; do
    tool_path="$(command -v "$tool")"
    ln -s "$tool_path" "$bin/$tool"
  done

  listed=""
  if [[ "$present" == "yes" ]]; then
    listed="remote-pi"
  fi
  cat > "$bin/omp" <<EOF
#!$bash_bin
case "\$1" in
  plugin) printf '%s\n' '$listed' ;;
  install) printf 'INSTALL:%s\n' "\$2" ;;
esac
EOF
  chmod +x "$bin/omp"

  # Records what the installer asks the remote-pi CLI to do, so the end-to-end
  # case can assert the relay step ran instead of tolerating its failure.
  cat > "$bin/remote-pi" <<EOF
#!$bash_bin
printf '%s\n' "\$*" >> '$home/remote-pi-calls'
EOF
  chmod +x "$bin/remote-pi"

  if [[ "$npm_mode" != "absent" ]]; then
    if [[ "$npm_mode" == "fail" ]]; then
      cat > "$bin/npm" <<EOF
#!$bash_bin
printf 'npm ERR! network unreachable\n' >&2
exit 1
EOF
    else
      cat > "$bin/npm" <<EOF
#!$bash_bin
printf '%s\n' '$npm_mode'
EOF
    fi
    chmod +x "$bin/npm"
  fi

  if [[ -n "$installed" ]]; then
    mkdir -p "$home/.omp/plugins/node_modules/remote-pi"
    printf '{\n  "name": "remote-pi",\n  "version": "%s"\n}\n' "$installed" \
      > "$home/.omp/plugins/node_modules/remote-pi/package.json"
  fi

  printf '%s' "$bin"
}

# Runs install_remote_plugin in a sandbox and reports one token: `INSTALL:<spec>`
# when it installs, `skip` when it leaves the install alone, or `EXIT:<status>`
# when the installer aborts.
plugin_action() {
  local bin output status

  bin="$(make_sandbox "$1" "$2" "$3")"

  set +e
  output="$(PATH="$bin" HOME="$(dirname "$bin")/home" "$bash_bin" -c \
    "source '$installer'; install_remote_plugin" 2>&1)"
  status=$?
  set -e

  # A nonzero exit is always a defect here: an unreachable registry must not
  # abort the installer.
  if (( status != 0 )); then
    printf 'EXIT:%s (%s)' "$status" "${output//$'\n'/ }"
    return
  fi
  if [[ "$output" == *INSTALL:* ]]; then
    output="${output#*INSTALL:}"
    printf 'INSTALL:%s' "${output%%$'\n'*}"
    return
  fi
  if [[ "$output" == *skipping* ]]; then
    printf 'skip'
    return
  fi
  printf 'NONE (%s)' "${output//$'\n'/ }"
}

# Runs the real entry point, `install.sh remote`, as a subprocess. The dispatch
# path calls install_remote_plugin unguarded, unlike the `all` target which
# wraps it in `if !`, so an abort inside the plugin step ends the run before it
# can report anything. Asserting on the plugin's own output therefore proves
# the step both ran and completed.
expect_end_to_end() {
  local name="$1" want="$2" installed="$3" npm_mode="$4" present="$5"
  local bin home output status

  bin="$(make_sandbox "$installed" "$npm_mode" "$present")"
  home="$(dirname "$bin")/home"

  # REMOTE_PI_RELAY short-circuits relay detection, so the run needs no network
  # and must succeed outright. Anything nonzero is a real failure.
  set +e
  output="$(PATH="$bin" HOME="$home" REMOTE_PI_RELAY="http://127.0.0.1:3000" \
    "$bash_bin" "$installer" remote 2>&1)"
  status=$?
  set -e

  if (( status != 0 )); then
    fail "$name (exited $status: ${output//$'\n'/ })"
    return
  fi
  if [[ "$output" != *"$want"* ]]; then
    fail "$name (want output containing $want, got ${output//$'\n'/ })"
    return
  fi
  # The relay step runs after the plugin step, so its record also proves the
  # plugin step did not abort the run. Assert what was recorded, not merely
  # that something was.
  local recorded=""
  if [[ -f "$home/remote-pi-calls" ]]; then
    recorded="$(sed -n '1p' "$home/remote-pi-calls")"
  fi
  if [[ "$recorded" != "set-relay http://127.0.0.1:3000" ]]; then
    fail "$name (relay step recorded '${recorded:-<nothing>}')"
  fi
}

expect() {
  local name="$1" want="$2" installed="$3" npm_mode="$4" present="$5"
  local got

  got="$(plugin_action "$installed" "$npm_mode" "$present")"
  if [[ "$got" != "$want" ]]; then
    fail "$name (want $want, got $got)"
  fi
}

# Guard the guard: if the sandbox could still reach a host npm, every `absent`
# case below would silently query the real registry and prove nothing.
sandbox_bin="$(make_sandbox "" absent yes)"
visible_npm="$(PATH="$sandbox_bin" "$bash_bin" -c 'command -v npm || printf none')"
if [[ "$visible_npm" != "none" ]]; then
  printf 'FAIL: sandbox PATH still resolves npm at %s\n' "$visible_npm" >&2
  exit 1
fi

expect "upgrades to the newest published release" \
  "INSTALL:remote-pi@0.99.1" "$floor" "0.99.1" yes

expect "keeps an install newer than the registry" \
  "skip" "99.0.0" "0.99.1" yes

expect "skips when the install already matches the registry" \
  "skip" "0.99.1" "0.99.1" yes

expect "upgrades an install below the floor" \
  "INSTALL:remote-pi@$floor" "0.5.5" absent yes

expect "holds the floor when the registry is behind it" \
  "INSTALL:remote-pi@$floor" "0.5.5" "0.0.1" yes

expect "installs the target when the plugin is absent" \
  "INSTALL:remote-pi@0.99.1" "" "0.99.1" no

expect "repairs an unreadable manifest" \
  "INSTALL:remote-pi@0.99.1" "" "0.99.1" yes

# Without npm the installer must hold at the floor, not reach for a newer one.
expect "holds the floor when npm is unavailable" \
  "skip" "$floor" absent yes

# A failed lookup used to abort the whole installer through `pipefail`.
expect "survives a registry lookup failure" \
  "skip" "$floor" fail yes

expect "still repairs below the floor when the lookup fails" \
  "INSTALL:remote-pi@$floor" "0.5.5" fail yes

# Version strings must be validated, not sanitized. Deleting stray characters
# would read `9garbage.0.0` as 9.0.0, so a corrupt install would pass for
# current and a corrupt registry answer would become the install spec.
expect "treats a malformed manifest version as needing repair" \
  "INSTALL:remote-pi@$floor" "not-a-version" absent yes

expect "does not read a digit-prefixed manifest version as current" \
  "INSTALL:remote-pi@$floor" "9garbage.0.0" absent yes

expect "ignores a malformed registry version" \
  "skip" "$floor" "not-a-version" yes

expect "never installs a digit-prefixed registry version" \
  "skip" "$floor" "9garbage.0.0" yes

# npm versions always carry three components, so an abbreviated one is a
# corrupt manifest. It must repair, even though `99.0` would numerically
# outrank the floor if it were parsed leniently.
expect "treats an abbreviated manifest version as needing repair" \
  "INSTALL:remote-pi@$floor" "99.0" absent yes

expect "never installs an abbreviated registry version" \
  "skip" "$floor" "99.0" yes

expect "ranks a prerelease below the release it precedes" \
  "INSTALL:remote-pi@0.99.1" "0.99.1-rc.1" "0.99.1" yes

# Build metadata carries no precedence, so a local build of the current release
# is current. Treating `+local` like a prerelease would reinstall over it.
expect "treats build metadata as the release it was built from" \
  "skip" "0.99.1+local" "0.99.1" yes

expect "keeps a local build that is newer than the registry" \
  "skip" "99.0.0+local" "0.99.1" yes

expect "still upgrades a local build that is below the floor" \
  "INSTALL:remote-pi@$floor" "0.5.5+local" absent yes

expect "ranks a prerelease below its release even with build metadata" \
  "INSTALL:remote-pi@0.99.1" "0.99.1-rc.1+local" "0.99.1" yes

# The public entry point, not just the sourced function. `remote` reaches
# install_remote_plugin unguarded, so a regression there fails the whole run.
expect_end_to_end "install.sh remote upgrades to the published release" \
  "INSTALL:remote-pi@0.99.1" "$floor" "0.99.1" yes

expect_end_to_end "install.sh remote survives a registry lookup failure" \
  "skipping" "$floor" fail yes

expect_end_to_end "install.sh remote repairs an install below the floor" \
  "INSTALL:remote-pi@$floor" "0.5.5" fail yes

if (( failures > 0 )); then
  printf '%d remote-pi floor check(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'remote-pi version floor regression passed\n'
