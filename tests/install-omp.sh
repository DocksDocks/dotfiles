#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
source_config="$repo_root/omp/config.yml"

test_home="$(mktemp -d "${TMPDIR:-/tmp}/install-omp.XXXXXX")"
cleanup() {
  rm -rf -- "$test_home"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

mapping_value() {
  awk -v section="$2" -v key="$3" '
    $0 ~ "^" section ":[[:space:]]*$" {
      in_section = 1
      next
    }
    in_section && /^[^[:space:]]/ {
      exit
    }
    in_section {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ ("^" key ":[[:space:]]*")) {
        sub(/^[^:]+:[[:space:]]*/, "", line)
        print line
        exit
      }
    }
  ' "$1"
}

web_search_order() {
  awk '
    /^providers:[[:space:]]*$/ {
      in_providers = 1
      next
    }
    in_providers && /^[^[:space:]]/ {
      exit
    }
    in_providers && /^[[:space:]]+webSearchOrder:[[:space:]]*$/ {
      in_list = 1
      next
    }
    in_list && /^[[:space:]]+-[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]+-[[:space:]]*/, "", line)
      print line
      next
    }
    in_list {
      exit
    }
  ' "$1"
}

expected_default="$(mapping_value "$source_config" modelRoles default)"
expected_order="$test_home/expected-web-search-order"
web_search_order "$source_config" > "$expected_order"

HOME="$test_home" "$repo_root/install.sh" omp >/dev/null
installed_config="$test_home/.omp/agent/config.yml"
mutated_config="$test_home/config.mutated.yml"

if ! awk '
  /^task:[[:space:]]*$/ {
    print
    print "  enableEffort: false"
    added_effort = 1
    next
  }
  /^modelRoles:[[:space:]]*$/ {
    print
    print "  custom: local/custom"
    in_model_roles = 1
    added_custom = 1
    next
  }
  in_model_roles && /^  default:[[:space:]]*/ {
    print "  default: local/changed-default"
    changed_default = 1
    next
  }
  in_model_roles && /^[^[:space:]]/ {
    in_model_roles = 0
  }
  /^providers:[[:space:]]*$/ {
    in_providers = 1
    print
    next
  }
  in_providers && /^[^[:space:]]/ {
    in_providers = 0
  }
  in_providers && /^  webSearchOrder:[[:space:]]*$/ {
    print
    print "    - local-extra-provider"
    added_provider = 1
    next
  }
  {
    print
  }
  END {
    if (!added_effort || !added_custom || !changed_default || !added_provider) {
      exit 1
    }
  }
' "$installed_config" > "$mutated_config"; then
  fail "could not prepare the destination config fixture"
fi
mv -- "$mutated_config" "$installed_config"

HOME="$test_home" "$repo_root/install.sh" omp >/dev/null

actual_custom="$(mapping_value "$installed_config" modelRoles custom)"
if [[ "$actual_custom" != "local/custom" ]]; then
  fail "modelRoles.custom did not survive reinstall (expected local/custom, got ${actual_custom:-<missing>})"
fi

actual_effort="$(mapping_value "$installed_config" task enableEffort)"
if [[ "$actual_effort" != "false" ]]; then
  fail "task.enableEffort did not survive reinstall (expected false, got ${actual_effort:-<missing>})"
fi

actual_default="$(mapping_value "$installed_config" modelRoles default)"
if [[ "$actual_default" != "$expected_default" ]]; then
  fail "modelRoles.default did not revert to the repository value (expected $expected_default, got ${actual_default:-<missing>})"
fi

actual_order="$test_home/actual-web-search-order"
web_search_order "$installed_config" > "$actual_order"
if ! cmp -s "$expected_order" "$actual_order"; then
  fail "providers.webSearchOrder did not revert to the complete repository list"
fi

printf 'OMP config merge regression passed\n'
