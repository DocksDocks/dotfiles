#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

backup_if_changed() {
  local source_file="$1"
  local target_file="$2"

  if [[ ! -f "$target_file" ]] || cmp -s "$source_file" "$target_file"; then
    return
  fi

  local timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"
  cp -- "$target_file" "${target_file}.backup.${timestamp}"
  printf 'Backed up %s\n' "$target_file"
}

# Merge the serializer-produced block YAML without requiring a YAML runtime.
# Mapping nodes merge recursively; every other source node replaces its target.
merge_omp_config() {
  local source_file="$1"
  local target_file="$2"

  awk -v source_path="$source_file" -v target_path="$target_file" '
    function reject(reason) {
      if (invalid_reason == "") {
        invalid_reason = reason
      }
    }

    function is_sequence_item(text) {
      return text == "-" || text ~ /^-[[:space:]]/
    }

    function load_document(document, path,    line, status) {
      while ((status = (getline line < path)) > 0) {
        line_count[document]++
        yaml_line[document SUBSEP line_count[document]] = line
      }
      if (status < 0) {
        reject("cannot read " document " document")
      }
      close(path)
    }

    function parse_document(document,    count, i, j, line, text, indent, colon, key, value, parent, id, end_line, first, lookup_key) {
      count = line_count[document]
      if (count == 0) {
        reject("missing " document " document")
        return
      }

      for (i = 1; i <= count; i++) {
        line = yaml_line[document SUBSEP i]
        if (index(line, "\t") != 0) {
          reject(document " line " i " contains a tab")
          continue
        }

        text = line
        sub(/^ */, "", text)
        if (text == "" || text ~ /^#/ || is_sequence_item(text)) {
          continue
        }

        indent = length(line) - length(text)
        colon = index(text, ":")
        if (colon == 0) {
          if (indent == 0) {
            reject(document " line " i " is not a mapping entry")
          }
          continue
        }

        key = substr(text, 1, colon - 1)
        sub(/ *$/, "", key)
        if (key == "") {
          reject(document " line " i " has an empty mapping key")
          continue
        }

        id = ++node_count[document]
        node_start[document SUBSEP id] = i
        node_indent[document SUBSEP id] = indent
        node_key[document SUBSEP id] = key

        value = substr(text, colon + 1)
        sub(/^ */, "", value)
        sub(/ *$/, "", value)
        node_value[document SUBSEP id] = value

        parent = 0
        for (j = id - 1; j >= 1; j--) {
          if (node_indent[document SUBSEP j] < indent) {
            parent = j
            break
          }
        }
        node_parent[document SUBSEP id] = parent
      }

      for (id = 1; id <= node_count[document]; id++) {
        end_line = count
        for (j = id + 1; j <= node_count[document]; j++) {
          if (node_indent[document SUBSEP j] <= node_indent[document SUBSEP id]) {
            end_line = node_start[document SUBSEP j] - 1
            break
          }
        }
        node_end[document SUBSEP id] = end_line

        value = node_value[document SUBSEP id]
        if (value == "{}") {
          node_type[document SUBSEP id] = "mapping"
        } else if (value == "[]" || value != "") {
          node_type[document SUBSEP id] = "value"
        } else {
          first = ""
          for (i = node_start[document SUBSEP id] + 1; i <= end_line; i++) {
            text = yaml_line[document SUBSEP i]
            sub(/^ */, "", text)
            if (text != "" && text !~ /^#/) {
              first = text
              break
            }
          }
          if (first == "" || is_sequence_item(first)) {
            node_type[document SUBSEP id] = "value"
          } else {
            node_type[document SUBSEP id] = "mapping"
          }
        }
      }

      for (id = 1; id <= node_count[document]; id++) {
        parent = node_parent[document SUBSEP id]
        if (parent != 0 && node_type[document SUBSEP parent] != "mapping") {
          continue
        }
        if (parent == 0 && node_indent[document SUBSEP id] != 0) {
          reject(document " line " node_start[document SUBSEP id] " has no mapping parent")
          continue
        }

        key = node_key[document SUBSEP id]
        lookup_key = document SUBSEP parent SUBSEP key
        if (node_lookup[lookup_key] != "") {
          reject(document " line " node_start[document SUBSEP id] " duplicates key " key)
        } else {
          node_lookup[lookup_key] = id
        }
      }
    }

    function print_node(document, id,    i) {
      for (i = node_start[document SUBSEP id]; i <= node_end[document SUBSEP id]; i++) {
        print yaml_line[document SUBSEP i]
      }
    }

    function print_mapping_header(document, id,    line, text, colon, indent) {
      line = yaml_line[document SUBSEP node_start[document SUBSEP id]]
      if (node_value[document SUBSEP id] != "{}") {
        print line
        return
      }

      text = line
      sub(/^ */, "", text)
      indent = length(line) - length(text)
      colon = index(text, ":")
      print substr(line, 1, indent + colon)
    }

    function render_mapping(source_parent, target_parent,    i, source_index, target_index, target_id, key) {
      for (i = 1; i <= node_count["source"]; i++) {
        source_index = "source" SUBSEP i
        if (node_parent[source_index] != source_parent) {
          continue
        }

        key = node_key[source_index]
        target_id = node_lookup["target" SUBSEP target_parent SUBSEP key]
        if (node_type[source_index] == "mapping" &&
            target_id != "" &&
            node_type["target" SUBSEP target_id] == "mapping") {
          print_mapping_header("source", i)
          render_mapping(i, target_id)
        } else {
          print_node("source", i)
        }
      }

      for (i = 1; i <= node_count["target"]; i++) {
        target_index = "target" SUBSEP i
        if (node_parent[target_index] != target_parent) {
          continue
        }

        key = node_key[target_index]
        if (node_lookup["source" SUBSEP source_parent SUBSEP key] == "") {
          print_node("target", i)
        }
      }
    }

    BEGIN {
      load_document("source", source_path)
      load_document("target", target_path)
      parse_document("source")
      parse_document("target")
      if (invalid_reason != "") {
        print "Cannot merge OMP config: " invalid_reason > "/dev/stderr"
        exit 1
      }
      render_mapping(0, 0)
    }
  '
}

install_omp_config() (
  local source_file="$1"
  local target_file="$2"
  local merged_file

  if [[ ! -f "$target_file" ]]; then
    install -m 0600 "$source_file" "$target_file"
    return
  fi

  merged_file="$(mktemp "${target_file}.merge.XXXXXX")"
  trap 'rm -f -- "$merged_file"' EXIT
  trap 'exit 1' HUP INT TERM

  if ! merge_omp_config "$source_file" "$target_file" > "$merged_file"; then
    return 1
  fi
  if cmp -s "$merged_file" "$target_file"; then
    return
  fi

  backup_if_changed "$merged_file" "$target_file"
  install -m 0600 "$merged_file" "$target_file"
)

intercom_dir() {
  local agent_dir

  if [[ -n "${PI_CODING_AGENT_DIR:-}" ]]; then
    if [[ "$PI_CODING_AGENT_DIR" == /* ]]; then
      agent_dir="$PI_CODING_AGENT_DIR"
    else
      agent_dir="$PWD/$PI_CODING_AGENT_DIR"
    fi
  else
    agent_dir="$HOME/.pi/agent"
  fi

  printf '%s/intercom\n' "${agent_dir%/}"
}

# Remote-pi hardcodes this path under the home directory.
# PI_CODING_AGENT_DIR applies only to pi-intercom.
remote_dir() {
  printf '%s/.pi/remote\n' "$HOME"
}

# The macOS application bundle frequently leaves the CLI outside PATH.
tailscale_cmd() {
  if command -v tailscale >/dev/null 2>&1; then
    printf 'tailscale\n'
    return
  fi
  if [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
    printf '/Applications/Tailscale.app/Contents/MacOS/Tailscale\n'
    return
  fi

  return 1
}

# The official script detects the operating system and selects the correct
# package manager. On macOS it opens the Mac App Store page.
tailscale_install_hint() {
  printf 'Tailscale is not installed, so the installer cannot find a relay\n' >&2

  case "$(uname -s 2>/dev/null)" in
    Darwin)
      printf 'Install it from the Mac App Store, or run one of these commands:\n' >&2
      printf '  brew install --cask tailscale\n' >&2
      printf '  curl -fsSL https://tailscale.com/install.sh | sh\n' >&2
      ;;
    Linux)
      printf 'Install it with this command:\n' >&2
      printf '  curl -fsSL https://tailscale.com/install.sh | sh\n' >&2
      ;;
    *)
      printf 'Install it from https://tailscale.com/download\n' >&2
      ;;
  esac
}

relay_health_ok() {
  local base_url="$1"
  local health

  # A missing probe tool is a prerequisite fault, not an absent relay.
  # The caller separates the two conditions, so never mask this case here.
  if ! command -v curl >/dev/null 2>&1; then
    return 2
  fi
  health="$(curl -fsS -m 2 "${base_url%/}/health" 2>/dev/null)" || return 1
  [[ "$health" == "OK" ]]
}

detect_relay_url() {
  local tailscale
  local status_output
  local suffix
  local line
  local address
  local short_name
  local remainder
  local relay_name
  local relay_url
  local probe_status

  if [[ -n "${REMOTE_PI_RELAY:-}" ]]; then
    printf 'Detected relay at %s\n' "$REMOTE_PI_RELAY" >&2
    printf '%s\n' "$REMOTE_PI_RELAY"
    return
  fi

  relay_url="http://127.0.0.1:3000"
  probe_status=0
  relay_health_ok "$relay_url" || probe_status=$?
  if [[ "$probe_status" -eq 0 ]]; then
    printf 'Detected relay at %s\n' "$relay_url" >&2
    printf '%s\n' "$relay_url"
    return
  fi
  if [[ "$probe_status" -eq 2 ]]; then
    printf 'Cannot probe for a relay: curl is not on PATH\n' >&2
    return 2
  fi

  # Status 3 marks an absent Tailscale CLI. The caller warns and continues.
  if ! tailscale="$(tailscale_cmd)"; then
    return 3
  fi
  # The macOS bundle executable chooses between the GUI and the CLI.
  # TAILSCALE_BE_CLI forces CLI mode and prevents a GUI launch. Linux ignores it.
  status_output="$(TAILSCALE_BE_CLI=1 "$tailscale" status 2>/dev/null)" || return 1
  suffix="$(
    TAILSCALE_BE_CLI=1 "$tailscale" status --json 2>/dev/null |
      grep -m1 '"MagicDNSSuffix"' |
      sed -e 's/.*: *"//' -e 's/".*//'
  )" || true

  while IFS= read -r line; do
    case "$line" in
      *offline*) continue ;;
    esac

    address=
    short_name=
    read -r address short_name remainder <<< "$line"
    if [[ -z "$address" || -z "$short_name" ]]; then
      continue
    fi

    if relay_health_ok "http://$address:3000"; then
      if [[ -n "$suffix" ]]; then
        relay_name="$(printf '%s' "$short_name" | tr '[:upper:]' '[:lower:]')"
        relay_url="http://$relay_name.$suffix:3000"
      else
        relay_url="http://$address:3000"
      fi
      printf 'Detected relay at %s\n' "$relay_url" >&2
      printf '%s\n' "$relay_url"
      return
    fi
  done <<< "$status_output"

  return 1
}

remote_pi_cli() {
  local plugin_cli="$HOME/.omp/plugins/node_modules/remote-pi/dist/index.js"

  if command -v remote-pi >/dev/null 2>&1; then
    printf 'remote-pi\n'
    return
  fi
  if [[ ! -f "$plugin_cli" ]]; then
    return 1
  fi
  if command -v bun >/dev/null 2>&1; then
    printf 'bun %s\n' "$plugin_cli"
    return
  fi
  if command -v node >/dev/null 2>&1; then
    printf 'node %s\n' "$plugin_cli"
    return
  fi

  return 1
}

install_intercom_config() {
  local source_file="$repo_root/omp/intercom.json"
  local target_dir
  local target_file

  target_dir="$(intercom_dir)"
  target_file="$target_dir/config.json"
  install -d -m 0700 "$target_dir"
  backup_if_changed "$source_file" "$target_file"
  install -m 0600 "$source_file" "$target_file"
  printf 'Installed pi-intercom configuration at %s\n' "$target_file"
}

install_remote_config() {
  local relay_url
  local target_dir
  local target_file
  local existing_relay
  local remote_cli
  local remote_runtime
  local remote_script
  local timestamp
  local detect_status

  detect_status=0
  relay_url="$(detect_relay_url)" || detect_status=$?
  # Status 2 means curl is missing, so no probe is possible at all.
  # Never claim a successful install while remote-pi stays unconfigured.
  if [[ "$detect_status" -eq 2 ]]; then
    printf 'Install curl, then run this target again\n' >&2
    return 1
  fi
  # Status 3 means Tailscale is missing. Warn, then continue.
  if [[ "$detect_status" -eq 3 ]]; then
    tailscale_install_hint
    if [[ ! -f "$(remote_dir)/config.json" ]]; then
      printf 'Until a relay is configured, remote-pi uses the public community relay\n' >&2
    else
      printf 'The existing remote-pi configuration is unchanged\n' >&2
    fi
    return 0
  fi
  if [[ "$detect_status" -ne 0 ]]; then
    printf 'Cannot detect the remote-pi relay on local or Tailscale peers\n' >&2
    # An absent configuration makes remote-pi fall back to the public
    # community relay. Fail instead of accepting that silent substitution.
    if [[ ! -f "$(remote_dir)/config.json" ]]; then
      printf 'No relay is configured, so remote-pi would use the public community relay\n' >&2
      printf 'Start the relay, then run this target again\n' >&2
      return 1
    fi
    printf 'The existing remote-pi configuration is unchanged\n' >&2
    return 0
  fi

  target_dir="$(remote_dir)"
  target_file="$target_dir/config.json"
  existing_relay=
  if [[ -f "$target_file" ]]; then
    existing_relay="$(
      sed -n 's/.*"relay"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$target_file" |
        sed -n '1p'
    )"
  fi
  if [[ "$existing_relay" == "$relay_url" ]]; then
    printf 'Remote-pi already uses relay %s; skipping configuration\n' "$relay_url"
    return
  fi

  if ! remote_cli="$(remote_pi_cli)"; then
    printf 'Cannot configure remote-pi for relay %s automatically\n' "$relay_url" >&2
    printf 'Set it manually with: remote-pi set-relay %s\n' "$relay_url" >&2
    return 0
  fi

  install -d -m 0700 "$target_dir"
  if [[ -f "$target_file" ]]; then
    timestamp="$(date +%Y%m%d-%H%M%S)"
    cp "$target_file" "${target_file}.backup.${timestamp}"
    printf 'Backed up %s\n' "$target_file"
  fi

  if [[ "$remote_cli" == "remote-pi" ]]; then
    remote-pi set-relay "$relay_url"
  else
    remote_runtime="${remote_cli%% *}"
    remote_script="${remote_cli#* }"
    "$remote_runtime" "$remote_script" set-relay "$relay_url"
  fi
  printf 'Configured remote-pi relay at %s\n' "$relay_url"
}

install_git_hooks() {
  if ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'Cannot install hooks: %s is not a Git working tree\n' "$repo_root" >&2
    exit 1
  fi

  git -C "$repo_root" config --local core.hooksPath .githooks
  printf 'Enabled repository hooks from %s/.githooks\n' "$repo_root"
}

install_omp() {
  local agents_source="$repo_root/omp/AGENTS.md"
  local config_source="$repo_root/omp/config.yml"
  local mcp_source="$repo_root/omp/mcp.json"
  local target_dir="$HOME/.omp/agent"
  local agents_target="$target_dir/AGENTS.md"
  local config_target="$target_dir/config.yml"
  local mcp_target="$target_dir/mcp.json"

  install -d -m 0700 "$target_dir"
  backup_if_changed "$agents_source" "$agents_target"
  install_omp_config "$config_source" "$config_target"
  backup_if_changed "$mcp_source" "$mcp_target"
  install -m 0600 "$agents_source" "$agents_target"
  install -m 0600 "$mcp_source" "$mcp_target"
  install_intercom_config
  printf 'Installed OMP configuration at %s, %s, and %s\n' \
    "$agents_target" "$config_target" "$mcp_target"
}

# Pi-intercom's default npx --no-install tsx launcher cannot locate tsx under omp:
# omp installs plugins into one flat store, while the launcher's fallback path looks
# inside pi-intercom/node_modules, so the broker exits with code 1. Bun runs the
# TypeScript broker directly and needs no tsx path.
install_intercom_plugin() {
  local plugin_list

  if ! command -v omp >/dev/null 2>&1; then
    printf 'Cannot install pi-intercom: omp is not on PATH\n' >&2
    return 1
  fi
  if ! command -v bun >/dev/null 2>&1; then
    printf 'Cannot install pi-intercom: bun is not on PATH; bun is the broker runtime\n' >&2
    return 1
  fi

  plugin_list="$(omp plugin list 2>/dev/null || true)"
  if [[ "$plugin_list" == *pi-intercom* ]]; then
    printf 'pi-intercom is already installed; skipping plugin install\n'
  else
    omp install pi-intercom
  fi
}

install_remote_plugin() {
  local plugin_list

  if ! command -v omp >/dev/null 2>&1; then
    printf 'Cannot install remote-pi: omp is not on PATH\n' >&2
    return 1
  fi

  plugin_list="$(omp plugin list 2>/dev/null || true)"
  if [[ "$plugin_list" == *remote-pi* ]]; then
    printf 'remote-pi is already installed; skipping plugin install\n'
  else
    omp install remote-pi
  fi
}

install_intercom() {
  install_intercom_plugin
  install_intercom_config
}

install_remote() {
  install_remote_plugin
  install_remote_config
}

usage() {
  printf 'Usage: %s [all|hooks|omp|intercom|remote]\n' "${0##*/}"
}

case "${1:-all}" in
  all)
    install_git_hooks
    install_omp
    # Plugin availability must not block repository hooks or tracked configuration.
    if ! install_intercom_plugin; then
      printf 'Continuing without the pi-intercom plugin\n' >&2
    fi
    if ! install_remote_plugin; then
      printf 'Continuing without the remote-pi plugin\n' >&2
    fi
    if ! install_remote_config; then
      printf 'Continuing without the remote-pi relay configuration\n' >&2
    fi
    ;;
  hooks)
    install_git_hooks
    ;;
  omp)
    install_omp
    ;;
  intercom)
    install_intercom
    ;;
  remote)
    install_remote
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
