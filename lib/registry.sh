# shellcheck shell=bash
# Declarative package table and the dispatcher that installs one row.
# A row is: id|label|bin|ubuntu spec|macos spec|link
#   bin   A command name. When the adapter finds it, the package is present
#         (this covers snap and manual installs). "-" skips the check.
#   spec  "<method> <args...>". "-" is not supported on this OS (the summary
#         shows the link). "n/a" is not applicable (no link).

# The row order is the install order: a later row can need an earlier row.
registry_rows() {
  cat <<'EOF'
git|Git|-|apt git|formula git|https://git-scm.com/downloads
gh|GitHub CLI|-|apt_repo github-cli gh|formula gh|https://cli.github.com/
btop|btop|-|apt btop|formula btop|https://github.com/aristocratos/btop#installation
php|PHP (distro default, 8.5 on 26.04)|-|apt php-cli php-curl php-mbstring php-xml php-zip php-intl php-sqlite3 php-bcmath php-gd|formula php|https://www.php.net/downloads.php
composer|Composer|composer|tool composer|formula composer|https://getcomposer.org/download/
uv|uv|-|tool uv|tool uv|https://docs.astral.sh/uv/getting-started/installation/
python|Python (latest stable, uv)|-|tool python|tool python|https://www.python.org/downloads/
node|Node.js LTS (nvm)|-|tool node|tool node|https://github.com/nvm-sh/nvm#installing-and-updating
bun|Bun|-|tool bun|tool bun|https://bun.com/docs/installation
pnpm|pnpm|-|tool pnpm|tool pnpm|https://pnpm.io/installation
pnpm-store|pnpm global virtual store|-|tool pnpm_store|tool pnpm_store|https://pnpm.io/settings/node-modules
omp|omp|-|tool omp|tool omp|https://omp.sh/
docks-kit|docks-kit|-|tool docks_kit|tool docks_kit|https://github.com/DocksDocks/public
docks-kit-sync|docks-kit sync omp|-|tool docks_kit_sync|tool docks_kit_sync|https://github.com/DocksDocks/public
docker|Docker Engine|-|apt_repo docker docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras uidmap dbus-user-session slirp4netns|cask docker-desktop Docker.app|https://docs.docker.com/get-started/get-docker/
docker-rootless|Docker rootless mode|-|tool docker_rootless|n/a|https://docs.docker.com/engine/security/rootless/
tailscale|Tailscale|-|apt_repo tailscale tailscale tailscale-archive-keyring|cask tailscale-app Tailscale.app|https://tailscale.com/download
chrome|Google Chrome|google-chrome|deb chrome|cask google-chrome Google Chrome.app|https://www.google.com/chrome/
discord|Discord|discord|deb discord|cask discord Discord.app|https://discord.com/download
github-desktop|GitHub Desktop|-|n/a|cask github GitHub Desktop.app|https://desktop.github.com/download/
vlc|VLC|vlc|apt vlc|cask vlc VLC.app|https://www.videolan.org/vlc/
rustdesk|RustDesk|rustdesk|deb rustdesk|cask rustdesk RustDesk.app|https://rustdesk.com/download
parsec|Parsec|parsecd|deb parsec|cask parsec Parsec.app|https://parsec.app/downloads
EOF
}

# Fields of the row that registry_lookup found last.
ROW_ID=''
ROW_LABEL=''
ROW_BIN=''
ROW_UBUNTU=''
ROW_MACOS=''
ROW_LINK=''

registry_lookup() {
  local id label bin ubuntu macos link

  while IFS='|' read -r id label bin ubuntu macos link; do
    if [ "$id" = "$1" ]; then
      ROW_ID="$id"
      ROW_LABEL="$label"
      ROW_BIN="$bin"
      ROW_UBUNTU="$ubuntu"
      ROW_MACOS="$macos"
      ROW_LINK="$link"
      return 0
    fi
  done < <(registry_rows)
  return 1
}

registry_ids() {
  local id rest

  while IFS='|' read -r id rest; do
    printf '%s\n' "$id"
  done < <(registry_rows)
}

registry_has_id() {
  local id rest

  while IFS='|' read -r id rest; do
    if [ "$id" = "$1" ]; then
      return 0
    fi
  done < <(registry_rows)
  return 1
}

# The spec of the row from registry_lookup for PLATFORM_OS.
registry_spec() {
  case "$PLATFORM_OS" in
    ubuntu) printf '%s\n' "$ROW_UBUNTU" ;;
    macos) printf '%s\n' "$ROW_MACOS" ;;
    *) die "unknown platform: $PLATFORM_OS" ;;
  esac
}

registry_list() {
  local id label bin ubuntu macos link method

  printf '%-16s %-30s %s\n' ID LABEL "METHOD ($PLATFORM_OS)"
  while IFS='|' read -r id label bin ubuntu macos link; do
    case "$PLATFORM_OS" in
      ubuntu) method="${ubuntu%% *}" ;;
      *) method="${macos%% *}" ;;
    esac
    if [ "$method" = - ]; then
      method='unsupported'
    fi
    printf '%-16s %-30s %s\n' "$id" "$label" "$method"
  done < <(registry_rows)
}

# Generic method for the cross-OS tools in lib/tools/*.sh. A missing tool
# function is a failure of this package only, not of the run.
method_tool_present() {
  declare -F "tool_${1}_present" >/dev/null || return 1
  "tool_${1}_present"
}

method_tool_install() {
  if ! declare -F "tool_${1}_install" >/dev/null; then
    warn "no installer function tool_${1}_install"
    return 1
  fi
  "tool_${1}_install"
}

# Record the result of a successful install. A dry-run only plans the work;
# mark_planned lets later packages accept the missing command of this one.
registry_record_success() {
  if [ "$DRY_RUN" = 1 ]; then
    out_flush
    mark_planned "$ROW_ID"
    record_result "$ROW_ID" "$ROW_LABEL" planned "$ROW_LINK"
  else
    log_status installed 'Installed.'
    record_result "$ROW_ID" "$ROW_LABEL" installed "$ROW_LINK"
  fi
}

# Install one registry row. Each outcome goes to the report; one failure
# never stops the run. An unchanged row joins the shared "Already present"
# line; every other row gets its own "==>" header.
install_package() {
  local spec method rest token rc
  local -a args

  registry_lookup "$1" || die "unknown package id: $1"
  spec="$(registry_spec)"
  case "$spec" in
    -)
      step "$ROW_LABEL ($ROW_ID)"
      log_status unsupported "Not supported on $PLATFORM_OS; install by hand: $ROW_LINK"
      record_result "$ROW_ID" "$ROW_LABEL" unsupported "$ROW_LINK"
      return 0
      ;;
    n/a)
      quiet_add "$ROW_ID (n/a)"
      record_result "$ROW_ID" "$ROW_LABEL" n/a '-'
      return 0
      ;;
  esac

  method="${spec%% *}"
  rest="${spec#"$method"}"
  rest="${rest# }"
  # A cask spec has two arguments: the token and an app name that can
  # contain spaces. Other specs split on spaces.
  if [ "$method" = cask ]; then
    token="${rest%% *}"
    rest="${rest#"$token"}"
    args=("$token" "${rest# }")
  else
    IFS=' ' read -r -a args <<<"$rest"
  fi

  if ! declare -F "method_${method}_present" >/dev/null ||
    ! declare -F "method_${method}_install" >/dev/null; then
    step "$ROW_LABEL ($ROW_ID)"
    warn "the $PLATFORM_OS adapter has no method '$method'"
    record_result "$ROW_ID" "$ROW_LABEL" failed "$ROW_LINK" "no method $method"
    return 0
  fi

  if { [ "$ROW_BIN" != - ] && os_has_command "$ROW_BIN"; } ||
    "method_${method}_present" ${args[@]+"${args[@]}"} >/dev/null; then
    quiet_add "$ROW_ID"
    record_result "$ROW_ID" "$ROW_LABEL" present "$ROW_LINK"
    return 0
  fi

  # The header prints with the first output of the install. A routine sync
  # that prints nothing joins the shared line instead.
  defer_step "$ROW_LABEL ($ROW_ID)"
  if "method_${method}_install" ${args[@]+"${args[@]}"}; then
    rc=0
  else
    rc=$?
  fi
  case "$rc" in
    0) registry_record_success ;;
    "$RC_SYNCED")
      if [ -n "$PENDING_STEP" ]; then
        quiet_add "$ROW_ID (synced)"
      elif [ "$DRY_RUN" != 1 ]; then
        log_status synced 'Synced.'
      fi
      record_result "$ROW_ID" "$ROW_LABEL" synced "$ROW_LINK"
      ;;
    "$RC_UNSUPPORTED")
      log_status unsupported "Not supported on $PLATFORM_OS $PLATFORM_ARCH; install by hand: $ROW_LINK"
      record_result "$ROW_ID" "$ROW_LABEL" unsupported "$ROW_LINK" "$PLATFORM_ARCH"
      ;;
    *)
      warn "$ROW_ID: install failed (exit code $rc)"
      record_result "$ROW_ID" "$ROW_LABEL" failed "$ROW_LINK" "exit code $rc"
      ;;
  esac
  end_step
  return 0
}

# Validate every id before any work, then install in registry order, so that
# a dependency always comes before the package that needs it. The ids go into
# an array first: an installer that reads stdin must not eat the id list.
install_packages() {
  local id selected=' '
  local -a ids

  for id in "$@"; do
    registry_has_id "$id" || die "unknown package id: $id (run ./install.sh list)"
    selected="$selected$id "
  done
  ids=()
  while IFS= read -r id; do
    if [ "$selected" = ' ' ]; then
      ids[${#ids[@]}]="$id"
      continue
    fi
    case "$selected" in
      *" $id "*) ids[${#ids[@]}]="$id" ;;
    esac
  done < <(registry_ids)
  for id in ${ids[@]+"${ids[@]}"}; do
    install_package "$id"
  done
}
