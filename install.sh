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
  printf 'Installed OMP configuration at %s, %s, and %s\n' \
    "$agents_target" "$config_target" "$mcp_target"
}

usage() {
  printf 'Usage: %s [all|hooks|omp]\n' "${0##*/}"
}

case "${1:-all}" in
  all)
    install_git_hooks
    install_omp
    ;;
  hooks)
    install_git_hooks
    ;;
  omp)
    install_omp
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
