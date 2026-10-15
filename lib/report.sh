# shellcheck shell=bash
# Result recording and the end-of-run summary. Bash 3.2 has no associative
# arrays, so the results use parallel indexed arrays.

RESULT_IDS=()
RESULT_LABELS=()
RESULT_STATUSES=()
RESULT_LINKS=()
RESULT_DETAILS=()

# Summary order: work done first, problems last, so that they stay visible.
REPORT_STATUS_ORDER='installed planned present synced n/a unsupported failed'
# These groups need no action, so the summary shows only their count. The
# list command shows every package.
REPORT_COMPACT_STATUSES='present synced n/a'

report_status_title() {
  case "$1" in
    installed) printf 'Installed' ;;
    planned) printf 'Planned (dry-run, no changes made)' ;;
    present) printf 'Already present' ;;
    synced) printf 'Routine syncs (run every time)' ;;
    n/a) printf 'Not applicable on this platform' ;;
    unsupported) printf 'Not supported here; install by hand' ;;
    failed) printf 'Failed' ;;
  esac
}

record_result() {
  local id="$1" label="$2" status="$3" link="$4" detail="${5:-}"

  case " $REPORT_STATUS_ORDER " in
    *" $status "*) ;;
    *) die "record_result: unknown status '$status' for $id" ;;
  esac
  RESULT_IDS[${#RESULT_IDS[@]}]="$id"
  RESULT_LABELS[${#RESULT_LABELS[@]}]="$label"
  RESULT_STATUSES[${#RESULT_STATUSES[@]}]="$status"
  RESULT_LINKS[${#RESULT_LINKS[@]}]="$link"
  RESULT_DETAILS[${#RESULT_DETAILS[@]}]="$detail"
}

report_count_status() {
  local status="$1" count=0 i=0

  while [ "$i" -lt "${#RESULT_STATUSES[@]}" ]; do
    if [ "${RESULT_STATUSES[$i]}" = "$status" ]; then
      count=$((count + 1))
    fi
    i=$((i + 1))
  done
  printf '%s\n' "$count"
}

# Failed and unsupported items show their download page, so that the user
# can install them by hand.
report_print_item() {
  local i="$1" status="$2" line link

  line="  - ${RESULT_LABELS[$i]} [${RESULT_IDS[$i]}]"
  if [ -n "${RESULT_DETAILS[$i]}" ]; then
    line="$line (${RESULT_DETAILS[$i]})"
  fi
  link="${RESULT_LINKS[$i]}"
  case "$status" in
    failed | unsupported)
      if [ -n "$link" ] && [ "$link" != - ]; then
        paint out "$(status_color "$status")" "$line"
        printf ': '
        osc8_link "$link"
        return 0
      fi
      ;;
  esac
  paint out "$(status_color "$status")" "$line"
  printf '\n'
}

report_print_group() {
  local status="$1" count color i=0

  count="$(report_count_status "$status")"
  if [ "$count" -eq 0 ]; then
    return 0
  fi
  color="$(status_color "$status")"
  printf '\n'
  case " $REPORT_COMPACT_STATUSES " in
    *" $status "*)
      paint out "$color" "$(report_status_title "$status"): $count"
      printf '\n'
      return 0
      ;;
  esac
  paint out "1;$color" "$(report_status_title "$status") ($count):"
  printf '\n'
  while [ "$i" -lt "${#RESULT_STATUSES[@]}" ]; do
    if [ "${RESULT_STATUSES[$i]}" = "$status" ]; then
      report_print_item "$i" "$status"
    fi
    i=$((i + 1))
  done
}

print_summary() {
  local status new_count

  out_flush
  printf '\n'
  step Summary
  for status in $REPORT_STATUS_ORDER; do
    report_print_group "$status"
  done
  new_count=$(($(report_count_status installed) + $(report_count_status planned)))
  if [ "$new_count" -eq 0 ]; then
    printf '\n'
    log_status present 'Nothing new to install.'
  fi
}

report_has_failures() {
  local i=0

  while [ "$i" -lt "${#RESULT_STATUSES[@]}" ]; do
    if [ "${RESULT_STATUSES[$i]}" = failed ]; then
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}
