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

chain_keys() {
  awk '
    /^retry:[[:space:]]*$/ {
      in_retry = 1
      next
    }
    in_retry && /^[^[:space:]]/ {
      exit
    }
    in_retry && /^  fallbackChains:[[:space:]]*$/ {
      in_chains = 1
      next
    }
    in_chains && /^  [^[:space:]]/ {
      in_chains = 0
    }
    in_chains && /^    [^[:space:]-]/ {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/:.*$/, "", line)
      print line
    }
  ' "$1"
}

chain_key_present() {
  local key

  while IFS= read -r key; do
    if [[ "$key" == "$2" ]]; then
      return 0
    fi
  done < "$1"
  return 1
}

top_level_value() {
  awk -v key="$2" '
    index($0, key ":") == 1 {
      line = $0
      sub(/^[^:]+:[[:space:]]*/, "", line)
      print line
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
  /^  fallbackChains:[[:space:]]*$/ {
    print
    print "    local/stale-model: "
    print "      - anthropic/claude-opus-5:high"
    print "    local/*: "
    print "      - anthropic/claude-opus-5:high"
    print "    futurerole: "
    print "      - anthropic/claude-opus-5:high"
    added_chains = 1
    next
  }
  {
    print
  }
  END {
    print "local/keep-me: true"
    if (!added_effort || !added_custom || !changed_default || !added_provider ||
        !added_chains) {
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

actual_chain_keys="$test_home/actual-chain-keys"
chain_keys "$installed_config" > "$actual_chain_keys"

for stale_key in 'local/stale-model' 'local/*'; do
  if chain_key_present "$actual_chain_keys" "$stale_key"; then
    fail "retry.fallbackChains kept the model-oriented key $stale_key"
  fi
done

if ! chain_key_present "$actual_chain_keys" futurerole; then
  fail "retry.fallbackChains dropped the destination-only role key futurerole"
fi

if ! chain_key_present "$actual_chain_keys" advisor; then
  fail "retry.fallbackChains lost the repository advisor chain"
fi

actual_keep="$(top_level_value "$installed_config" 'local/keep-me')"
if [[ "$actual_keep" != "true" ]]; then
  fail "the prune reached outside retry.fallbackChains and removed local/keep-me (expected true, got ${actual_keep:-<missing>})"
fi

printf 'OMP config merge regression passed\n'
