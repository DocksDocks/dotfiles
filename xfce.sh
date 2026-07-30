#!/usr/bin/env bash
#
# xfce.sh -- apply the Night Owl Xfce desktop to a live Xfce session.
#
# Ported from the provisioning scripts of the Debian 13 Vagrant dev box, which
# apply the same look to a fresh VM. Two things differ here, and they are why
# this is a separate script rather than a copy:
#
#   1. The VM scripts run as root against a not-yet-existing user with no D-Bus
#      session, so they write xfconf channel XML directly and `dconf compile` a
#      whole new database. Both of those REPLACE state wholesale. On a real
#      desktop that erases settings you already have, so this script goes
#      through `xfconf-query` and `dconf load` instead: both merge, and both
#      apply live without a logout.
#   2. Anything the VM installs system-wide that does not need to be is
#      user-scoped here (~/.themes, ~/.local/share/icons, ~/.local/share/fonts,
#      ~/.local/bin). Only distro packages and the dock plugin need sudo.
#
# Every managed setting is snapshotted before the first change; `revert` puts
# the snapshot back.
#
# Usage:
#   ./xfce.sh [all|deps|theme|fonts|icons|gtk|settings|tilix|screenshot|rofi|
#              dock <docklike|plank|tasklist>|pins|panels|status|backup|revert]
#
#   FORCE=1             rebuild the theme / refetch the font even if present
#   XFCE_DOCK=...       dock engine to install and build the panel around,
#                       during `all` (docklike|plank|tasklist)
#   XFCE_DOCK_PANEL=... force which panel becomes the single bottom panel
#                       (default: the one already carrying the dock)
#   XFCE_DOCK_PINS=...  space-separated desktop-entry IDs pinned to docklike

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
payload="$repo_root/xfce4"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/xfce-nightowl"

theme_name="Tokyonight-Dark"
# One immutable commit, asserted after fetch. Upstream publishes no tags to pin
# to and the installer compiles from SASS, so an unpinned clone would mean the
# desktop silently restyles itself on some future re-run.
tokyonight_repo="https://github.com/Fausto-Korpsvart/Tokyonight-GTK-Theme"
tokyonight_pin="6c340e058e84c1975a038a8e5d1e384477225dc0"
# Tilix keys profiles by UUID. Fixed so `default-profile`, `profile-list` and
# the `[profiles/...]` block in night-owl.dconf all agree.
tilix_profile="2b7c4080-0ddd-46c5-8f23-563fd3ba789d"
# Last docklike release that builds against Xfce 4.18: 0.4.3 swapped libwnck
# for libxfce4windowing and requires >= 4.19.4, which ships with Xfce 4.20.
docklike_pin="9debe3d943081091f5b2fa205513104896b55d88"
docklike_version="0.4.2"
docklike_repo="https://gitlab.xfce.org/panel-plugins/xfce4-docklike-plugin.git"
# The launcher is deliberately NOT pinned: Super+Space reaches it faster than
# a dock tile, and the entry still exists in the applications menu for anyone
# who wants to pin it by hand. Add `night-owl-launcher` to XFCE_DOCK_PINS to
# put it back.
default_dock_pins="google-chrome com.gexperts.Tilix thunar"

# Pinned like the theme and dock commits, and for the same reason: the font is
# named directly by tilix/night-owl.dconf, so tracking `latest` would restyle
# every terminal on the box the day upstream cuts a release. The digest is the
# one published in the release's own SHA-256.txt.
nerd_font_version="v3.4.0"
nerd_font_sha256="ef552a3e638f25125c6ad4c51176a6adcdce295ab1d2ffacf0db060caf8c1582"

# Distinct name on purpose -- see the header of the index.theme asset for why
# calling it "Papirus-Dark" would collapse the system theme down to hicolor.
icon_overlay="Papirus-Dark-NightOwl"

apt_packages=(
  papirus-icon-theme      # icon theme
  fonts-noto              # UI font
  fonts-noto-color-emoji  # emoji coverage in the UI font
  dmz-cursor-theme        # DMZ-White pointer
  sassc                   # the GTK theme is compiled from SASS
  git                     # to fetch the pinned theme commit
  xfce4-screenshooter     # backs the Print-key wrapper
  xclip                   # puts the screenshot on the clipboard
  xfce4-notifyd           # notification daemon (the expire-timeout target)
  rofi                    # Night Owl application launcher and command prompt
  xfce4-whiskermenu-plugin # Vagrant panel's app menu
  libglib2.0-bin          # gtk-update-icon-cache, dconf
)

log()  { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# channel|property|type|value -- the complete set of settings this script owns.
# backup, apply, status and revert all iterate this, so a new setting only has
# to be added here. Emitted by a function rather than held in a flat array
# because the icon theme depends on whether the overlay got installed.
#
# `vblank_mode=off` from the VM is deliberately absent: it works around
# VirtualBox's VMSVGA software renderer and has no purpose on real hardware.
settings_table() {
  local icon_theme="Papirus-Dark"
  [[ -f "$HOME/.local/share/icons/$icon_overlay/index.theme" ]] && icon_theme="$icon_overlay"
  cat <<TABLE
xsettings|/Net/ThemeName|string|${theme_name}
xsettings|/Net/IconThemeName|string|${icon_theme}
xsettings|/Gtk/FontName|string|Noto Sans 10
xsettings|/Gtk/CursorThemeName|string|DMZ-White
xsettings|/Gtk/CursorThemeSize|int|24
xfwm4|/general/theme|string|${theme_name}
xfwm4|/general/title_font|string|Noto Sans Bold 10
xfwm4|/general/use_compositing|bool|true
xfce4-notifyd|/expire-timeout|int|2
xfce4-notifyd|/expire-timeout-enabled|bool|true
TABLE
}

require_session() {
  command -v xfconf-query >/dev/null 2>&1 \
    || die "xfconf-query not found -- this is not an Xfce install."
  # xfconf-query talks to xfconfd over the session bus; without one it fails
  # with an opaque libxfconf error, so say something useful up front.
  [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] \
    || die "No D-Bus session bus. Run this inside your Xfce session, not from a bare SSH shell."
  case "${XDG_CURRENT_DESKTOP:-}" in
    *XFCE*) ;;
    *) warn "XDG_CURRENT_DESKTOP is '${XDG_CURRENT_DESKTOP:-unset}', not XFCE -- settings may not apply live." ;;
  esac
}

require_cmd() {
  local cmd="$1" operation="$2"
  command -v "$cmd" >/dev/null 2>&1 \
    || die "$cmd is required to $operation. Install it, or run ./xfce.sh deps first."
}

# Without this early guard, a missing dpkg-query makes every package look
# absent and the script reaches apt-get only after callers may have written a
# snapshot. Automatic package installation is intentionally Debian/Ubuntu-only.
require_apt() {
  if ! command -v apt-get >/dev/null 2>&1 \
      || ! command -v dpkg-query >/dev/null 2>&1 \
      || ! command -v sudo >/dev/null 2>&1; then
    die "Automatic package installation supports Debian/Ubuntu only and requires apt-get, dpkg-query, and sudo. Install packages by hand on other distributions; the configuration subcommands gtk, settings, tilix, panels, pins, rofi, screenshot, and icons still work elsewhere when their packages are installed manually."
  fi
}

# ---------------------------------------------------------------- backup ----

# Records the CURRENT value of everything this script mutates, so `revert` can
# put it back.
#
# An older version of this script recorded the dock panel's autohide setting on
# its own, in panel-autohide.bak, because autohide was the only panel property
# it ever wrote. The single-panel rewrite folded autohide into panel-props.bak
# along with every other panel property.
#
# That leaves a trap on any box the older version already ran against. Its
# panel-props row for autohide-behavior was captured AFTER the older version
# had written its own value, so it records the installer's 0 rather than the
# user's real setting. panel-autohide.bak was captured before that write, so it
# is strictly older and strictly more trustworthy -- it wins, and only then is
# it removed. Without this, `revert` would quietly restore 0 and the user's
# "intelligently hide" would be gone with nothing left to recover it from.
migrate_legacy_state() {
  local legacy="$state_dir/panel-autohide.bak"
  local props="$state_dir/panel-props.bak"
  local panel value property obsolete

  # Artifacts written by mechanisms this script no longer has. Both were tried
  # and removed: `dock-margin` fed a CSS dock-centring rule that cannot work
  # (the panel ignores CSS box properties, and docklike lives behind a
  # GtkSocket), and `systray-hidden.bak` fed a systray hide that only collapsed
  # the item behind an expander arrow. Nothing reads either file now, so a
  # snapshot taken by one of those versions would carry state forward forever.
  for obsolete in dock-margin systray-hidden.bak; do
    if [[ -e "$state_dir/$obsolete" ]]; then
      rm -f "$state_dir/$obsolete"
      log "Dropped obsolete snapshot artifact $obsolete."
    fi
  done

  [[ -f "$legacy" ]] || return 0

  while IFS='|' read -r panel value; do
    [[ -n "$panel" && -n "$value" ]] || continue
    property="/panels/$panel/autohide-behavior"
    if [[ -f "$props" ]]; then
      grep -vF -- "$panel|$property|" "$props" > "$props.tmp" || true
      mv -f "$props.tmp" "$props"
    fi
    # The legacy writer stored the literal UNSET when the panel had no
    # autohide-behavior property at all -- which is the normal case for a top
    # panel. Carry that through as a real UNSET row; replaying it as
    # `--type uint --set UNSET` would just fail on a non-numeric int.
    if [[ "$value" == UNSET ]]; then
      printf '%s|%s|UNSET|\n' "$panel" "$property" >> "$props"
    else
      printf '%s|%s|uint|%s\n' "$panel" "$property" "$value" >> "$props"
    fi
    log "Adopted $panel autohide-behavior=$value from the pre-rewrite snapshot."
  done < "$legacy"

  rm -f "$legacy"
}

# Do not move these captures back behind backup(): GTK CSS and Tilix dconf
# operations do not require a live Xfce session, while backup() reads xfconf
# and therefore requires one.
capture_gtkcss_state() {
  mark_snapshot
  # A marker is required because "no .bak" is meaningful: there was no gtk.css
  # to begin with, so revert must delete the file installed by this script.
  if [[ ! -f "$state_dir/gtk.state" ]]; then
    if [[ -f "$HOME/.config/gtk-3.0/gtk.css" ]]; then
      cp -a "$HOME/.config/gtk-3.0/gtk.css" "$state_dir/gtk.css.bak"
      printf 'present\n' > "$state_dir/gtk.state"
    else
      printf 'absent\n' > "$state_dir/gtk.state"
    fi
  fi
}

capture_tilix_state() {
  require_cmd dconf "capture the Tilix settings"
  mark_snapshot
  [[ -f "$state_dir/tilix.bak" ]] \
    || dconf dump "/com/gexperts/Tilix/" > "$state_dir/tilix.bak" 2>/dev/null || true
}

# Marks that a snapshot exists. `revert` gates on this rather than on any one
# artifact, because the artifacts are captured by whichever subcommand first
# touches the thing they describe -- `./xfce.sh gtk` alone produces a state
# directory with gtk.state and no settings.bak. Gating on settings.bak would
# make that capture unreachable and revert would refuse a snapshot it holds.
mark_snapshot() {
  mkdir -p "$state_dir"
  [[ -f "$state_dir/taken-at" ]] || date '+%Y-%m-%d %H:%M:%S' > "$state_dir/taken-at"
}

# Each artifact is guarded INDIVIDUALLY rather than behind one early return on
# the directory existing. Two reasons: capturing an artifact twice would record
# the values we just applied over the originals, and an all-or-nothing return
# means a snapshot taken before this script learned to manage something new
# never gains it -- `revert` would then silently skip that part and still
# report success. Per-artifact guards both capture once and fill in gaps.
backup() {
  mkdir -p "$state_dir/xfconf-xml"
  mark_snapshot
  migrate_legacy_state

  local channel property type old panel

  if [[ ! -f "$state_dir/settings.bak" ]]; then
    : > "$state_dir/settings.bak.tmp"
    while IFS='|' read -r channel property type _; do
      [[ -n "$channel" ]] || continue
      if old="$(xfconf-query -c "$channel" -p "$property" 2>/dev/null)"; then
        printf '%s|%s|%s|%s\n' "$channel" "$property" "$type" "$old" >> "$state_dir/settings.bak.tmp"
      else
        printf '%s|%s|UNSET|\n' "$channel" "$property" >> "$state_dir/settings.bak.tmp"
      fi
    done < <(settings_table)
    mv "$state_dir/settings.bak.tmp" "$state_dir/settings.bak"
  fi

  if [[ ! -f "$state_dir/print-binding.bak" ]]; then
    if old="$(xfconf-query -c xfce4-keyboard-shortcuts -p /commands/custom/Print 2>/dev/null)"; then
      printf 'set|%s\n' "$old" > "$state_dir/print-binding.bak"
    else
      printf 'unset|\n' > "$state_dir/print-binding.bak"
    fi
  fi

  # Panel state is split by concern: this snapshot keeps every panel's ordered
  # plugin ids, while install_panels capture-once records changed panel/plugin
  # properties and the names of panels it removes. Unreferenced plugin entries
  # and their settings survive a panel restart, so unlinking is reversible.
  # Removing a PANEL is different: Xfce resets plugins still attached to it.
  # The panel is therefore stopped before plugins are moved and panels removed.
  if [[ ! -f "$state_dir/panels.bak" ]]; then
    : > "$state_dir/panels.bak"
    for panel in $(panel_names); do
      printf '%s|%s\n' "$panel" "$(panel_plugin_ids "$panel" | tr '\n' ' ')" >> "$state_dir/panels.bak"
    done
  fi

  capture_tilix_state
  capture_gtkcss_state

  # Readable archive only -- revert restores values, not these files. xfconfd
  # owns them at runtime and rewrites them on exit, so replaying them
  # underneath a live session is unreliable.
  #
  # Guarded like every other artifact: unguarded, it would re-copy on each run
  # and the disaster-recovery fallback would end up holding post-Night-Owl XML
  # instead of the pre-change state.
  if [[ ! -e "$state_dir/xfconf-xml/.captured" ]]; then
    cp -a "$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/." "$state_dir/xfconf-xml/" 2>/dev/null || true
    touch "$state_dir/xfconf-xml/.captured"
  fi

  log "Snapshot in $state_dir (undo with: ./xfce.sh revert)"
}

# ---------------------------------------------------------------- panels ----

panel_names() {
  xfconf-query -c xfce4-panel -p /panels -l 2>/dev/null \
    | sed -n 's|^/panels/\(panel-[0-9]\{1,\}\)/.*|\1|p' | sort -u
}

# xfconf-query renders an array as a header line, a blank line, then one value
# per line, so pull out the bare integers.
panel_plugin_ids() {
  xfconf-query -c xfce4-panel -p "/panels/$1/plugin-ids" 2>/dev/null | grep -oE '^[0-9]+'
}

panel_array_ids() {
  xfconf-query -c xfce4-panel -p /panels 2>/dev/null | grep -oE '^[0-9]+'
}

# EVERY /plugins/plugin-N key in the channel, referenced by a panel or not.
# Allocating a new id from the max of only the REFERENCED ids is unsafe: this
# script deliberately leaves plugins unreferenced, so an unreferenced entry can
# sit above the referenced max and get overwritten, then deleted by revert as
# if it belonged to this script.
all_plugin_ids() {
  # Match both `/plugins/plugin-N` and its children, so even an entry surfaced
  # only through a child path contributes to the collision-avoiding high-water
  # mark.
  xfconf-query -c xfce4-panel -p /plugins -l 2>/dev/null \
    | sed -n 's|^/plugins/plugin-\([0-9]\{1,\}\)\(/.*\)\{0,1\}$|\1|p' | sort -un
}

plugin_entry_exists() {
  xfconf-query -c xfce4-panel -p /plugins -l 2>/dev/null \
    | grep -E "^/plugins/plugin-$1(/|\$)" >/dev/null
}

# Rewrite a panel's plugin-ids. --force-array keeps it an array even when a
# single id is left; xfce4-panel will not parse a bare int where it wants a
# list. Order is layout order, so callers must preserve it.
set_panel_plugin_ids() {
  local panel="$1"; shift
  local args=() id
  for id in "$@"; do args+=(-t int -s "$id"); done
  xfconf-query -c xfce4-panel -p "/panels/$panel/plugin-ids" --create --force-array "${args[@]}" >/dev/null
}

set_panel_array() {
  local args=() id
  for id in "$@"; do args+=(-t int -s "$id"); done
  xfconf-query -c xfce4-panel -p /panels --create --force-array "${args[@]}" >/dev/null
}

# The panel's legacy-item hiding property is intentionally not used here: it
# only collapses the ibus item behind a systray expander arrow. Disabling this
# key stops ibus from registering the tray icon at all. The nearby
# org.freedesktop.ibus.panel `show` key is already 0 ("Do not show") on this
# box, yet the icon still appears, so it is not the control for this indicator.
install_ibus_hide() {
  local schema="org.freedesktop.ibus.panel" key="show-icon-on-systray"
  local state_file="$state_dir/ibus-tray.bak" schemas previous

  if ! command -v gsettings >/dev/null 2>&1; then
    warn "gsettings not found; the ibus systray icon was not disabled."
    return 0
  fi
  if ! schemas="$(gsettings list-schemas 2>/dev/null)" \
    || ! grep -Fxq "$schema" <<< "$schemas"; then
    warn "GSettings schema $schema not found; the ibus systray icon was not disabled."
    return 0
  fi
  if ! previous="$(gsettings get "$schema" "$key" 2>/dev/null)"; then
    warn "Could not read $schema $key; the ibus systray icon was not disabled."
    return 0
  fi

  # Capture once before writing so an idempotent rerun cannot replace the
  # user's original value with the false value installed below.
  if [[ ! -f "$state_file" ]]; then
    printf '%s\n' "$previous" > "$state_file"
  fi
  gsettings set "$schema" "$key" false
  log "Disabled ibus systray icon registration (was $previous)."
}

restore_ibus_hide() {
  local schema="org.freedesktop.ibus.panel" key="show-icon-on-systray"
  local state_file="$state_dir/ibus-tray.bak" schemas previous
  [[ -f "$state_file" ]] || return 0
  command -v gsettings >/dev/null 2>&1 || return 0
  schemas="$(gsettings list-schemas 2>/dev/null)" || return 0
  grep -Fxq "$schema" <<< "$schemas" || return 0

  previous="$(<"$state_file")"
  gsettings set "$schema" "$key" "$previous"
  rm -f "$state_file"
  log "Restored ibus systray icon registration to $previous."
}

# Record a property's pre-change value exactly once. The property field is the
# full xfconf path so replay does not have to infer a path from the state key.
# record_prop <state-file> <key> <channel> <property> <type>
record_prop() {
  local state_file="$1" key="$2" channel="$3" property="$4" type="$5"
  local saved_key saved_property value

  if [[ -f "$state_file" ]]; then
    while IFS='|' read -r saved_key saved_property _; do
      [[ "$saved_key" == "$key" && "$saved_property" == "$property" ]] && return 0
    done < "$state_file"
  fi

  if value="$(xfconf-query -c "$channel" -p "$property" 2>/dev/null)"; then
    printf '%s|%s|%s|%s\n' "$key" "$property" "$type" "$value" >> "$state_file"
  else
    printf '%s|%s|UNSET|\n' "$key" "$property" >> "$state_file"
  fi
}

panel_is_running() {
  pgrep -u "$(id -u)" -x xfce4-panel >/dev/null 2>&1
}

panel_launch_detached() {
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid -f xfce4-panel </dev/null >/dev/null 2>&1
  else
    nohup xfce4-panel </dev/null >/dev/null 2>&1 &
    disown || true
  fi
}

panel_emergency_start() {
  trap - ERR EXIT
  panel_is_running || panel_launch_detached || true
}

panel_stop() {
  local attempt

  # xfce4-panel saves its layout on exit. The write phase must begin only after
  # that save is finished or it can overwrite our changes. Arm the rescue trap
  # first so a failure can never strand the live desktop without a panel.
  trap panel_emergency_start ERR EXIT
  xfce4-panel -q >/dev/null 2>&1 || true
  for (( attempt = 0; attempt < 50; attempt++ )); do
    panel_is_running || return 0
    sleep 0.1
  done
  die "xfce4-panel did not stop after 5 seconds."
}

panel_start() {
  local attempt

  panel_is_running || panel_launch_detached
  for (( attempt = 0; attempt < 50; attempt++ )); do
    if panel_is_running; then
      trap - ERR EXIT
      return 0
    fi
    sleep 0.1
  done
  die "xfce4-panel did not start after 5 seconds."
}

panel_restart() {
  if panel_is_running; then
    xfce4-panel -r >/dev/null 2>&1
  else
    # -r only talks to an ALREADY-RUNNING instance. After an explicit stop the
    # bring-back must be a plain detached launch.
    panel_start
  fi
}

panel_layout() {
  local menu_type engine="${XFCE_DOCK:-docklike}"

  if [[ -f /usr/share/xfce4/panel/plugins/whiskermenu.desktop ]]; then
    menu_type=whiskermenu
  else
    menu_type=applicationsmenu
    warn "Whisker Menu is not installed; using Applications Menu. Run ./xfce.sh deps to install it."
  fi

  printf '%s\n' \
    "menu|$menu_type" \
    'sep-a|separator'

  case "$engine" in
    docklike) printf '%s\n' 'dock|docklike' ;;
    tasklist) printf '%s\n' 'dock|tasklist' ;;
    plank) ;;
    *) die "Unknown dock engine '$engine'." ;;
  esac

  printf '%s\n' \
    'sep-b|separator' \
    'tray|systray' \
    'volume|pulseaudio' \
    'clock|clock' \
    'sep-c|separator'
}

plugin_subprops() {
  case "$1" in
    sep-a|sep-b)
      printf '%s\n' 'expand|bool|true' 'style|uint|0'
      ;;
    tray)
      printf '%s\n' 'square-icons|bool|true'
      ;;
    clock)
      # The clock plugin installs these pango strings as label attributes.
      # Their explicit sizes override CSS font-size, so size belongs here.
      cat <<'CLOCK_PROPERTIES'
mode|uint|2
digital-layout|uint|1
digital-time-format|string|%^a  %H:%M
digital-date-format|string|%d %B %Y
digital-time-font|string|Noto Sans Bold 10
digital-date-font|string|Noto Sans 8
CLOCK_PROPERTIES
      ;;
    sep-c)
      printf '%s\n' 'expand|bool|false' 'style|uint|0'
      ;;
  esac
}

target_panel_props() {
  # Enum: 0 never / 1 intelligently / 2 always. Always-hide is a deliberate
  # user choice even though docklike is the only window list. The type must be
  # uint; int silently reads back as 0.
  cat <<'PANEL_PROPERTIES'
size|uint|48
length|uint|100
length-adjust|bool|false
icon-size|uint|22
autohide-behavior|uint|2
position-locked|bool|true
span-monitors|bool|false
output-name|string|Primary
PANEL_PROPERTIES
}

known_panel_props() {
  cat <<'KNOWN_PANEL_PROPERTIES'
position|string
position-locked|bool
size|uint
length|uint
length-adjust|bool
icon-size|uint
autohide-behavior|uint
span-monitors|bool
output-name|string
nrows|uint
mode|uint
background-style|uint
background-alpha|uint
enter-opacity|uint
leave-opacity|uint
disable-struts|bool
KNOWN_PANEL_PROPERTIES
}

# Uses the dynamically scoped current_dock_ids, assigned_plugin_ids and
# next_plugin_id owned by install_panels, and returns through resolved_plugin_id.
resolve_role_plugin() {
  local role="$1" type="$2" dock_panel="$3" position="$4"
  local id ptype candidate="${current_dock_ids[$position]:-}"

  [[ -f "/usr/share/xfce4/panel/plugins/$type.desktop" ]] \
    || die "Cannot create panel plugin type '$type': /usr/share/xfce4/panel/plugins/$type.desktop is missing."

  if [[ -n "$candidate" && -z "${assigned_plugin_ids[$candidate]+_}" ]]; then
    ptype="$(xfconf-query -c xfce4-panel -p "/plugins/plugin-$candidate" 2>/dev/null || true)"
    if [[ "$ptype" == "$type" ]]; then
      resolved_plugin_id="$candidate"
      assigned_plugin_ids["$candidate"]=1
      log "Mapped $role to existing plugin-$candidate ($type) by position."
      return 0
    fi
  fi

  # Prefer an unused matching plugin already on the surviving panel.
  for id in "${current_dock_ids[@]}"; do
    [[ -z "${assigned_plugin_ids[$id]+_}" ]] || continue
    ptype="$(xfconf-query -c xfce4-panel -p "/plugins/plugin-$id" 2>/dev/null || true)"
    if [[ "$ptype" == "$type" ]]; then
      resolved_plugin_id="$id"
      assigned_plugin_ids["$id"]=1
      log "Mapped $role to existing plugin-$id ($type) on $dock_panel."
      return 0
    fi
  done

  # Then reuse any other matching entry, including one left unreferenced.
  while IFS= read -r id; do
    [[ -n "$id" && -z "${assigned_plugin_ids[$id]+_}" ]] || continue
    ptype="$(xfconf-query -c xfce4-panel -p "/plugins/plugin-$id" 2>/dev/null || true)"
    if [[ "$ptype" == "$type" ]]; then
      resolved_plugin_id="$id"
      assigned_plugin_ids["$id"]=1
      log "Mapped $role to existing plugin-$id ($type)."
      return 0
    fi
  done < <(all_plugin_ids)

  while plugin_entry_exists "$next_plugin_id"; do
    next_plugin_id=$(( next_plugin_id + 1 ))
  done
  resolved_plugin_id="$next_plugin_id"
  xfconf-query -c xfce4-panel -p "/plugins/plugin-$resolved_plugin_id" \
    --create --type string --set "$type" >/dev/null
  printf '%s\n' "$resolved_plugin_id" >> "$state_dir/panels-added.bak"
  assigned_plugin_ids["$resolved_plugin_id"]=1
  next_plugin_id=$(( next_plugin_id + 1 ))
  log "Created plugin-$resolved_plugin_id ($type) for $role."
}

record_removed_panel_props() {
  local panel="$1" property type path relative prefix="/panels/$1/"
  local -A known=()
  local -a unknown=()

  while IFS='|' read -r property type; do
    known["$property"]="$type"
    if xfconf-query -c xfce4-panel -p "$prefix$property" >/dev/null 2>&1; then
      record_prop "$state_dir/panel-props.bak" "$panel" xfce4-panel \
        "$prefix$property" "$type"
    fi
  done < <(known_panel_props)

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    relative="${path#"$prefix"}"
    [[ "$relative" == plugin-ids || -n "${known[$relative]+_}" ]] && continue
    unknown+=("$relative")
  done < <(xfconf-query -c xfce4-panel -p "/panels/$panel" -l 2>/dev/null || true)

  if (( ${#unknown[@]} > 0 )); then
    warn "Not snapshotting unknown properties on $panel (type unavailable): ${unknown[*]}"
  fi
}

# Version-independent confirmation that the surviving panel really is a footer.
# The `position` property encodes an XfceScreenPosition whose numbering has not
# been stable across releases, so the only trustworthy answer is where the
# panel actually rendered. Warn rather than fail: the layout is otherwise
# correct and the user can drag the panel in one gesture.
verify_panel_edge() {
  command -v xwininfo >/dev/null 2>&1 && command -v xprop >/dev/null 2>&1 || return 0

  local id geom w h y screen_h lowest=-1 lowest_h=0 seen=0

  # No `exit` in the awk: it would close the pipe early, and under `pipefail`
  # the SIGPIPE to xwininfo becomes a failed pipeline. Harmless-looking, but
  # this runs inside install_panels while the relaunch trap is armed.
  screen_h="$(xwininfo -root 2>/dev/null | awk '/Height:/ && !h {h=$2} END{print h}')"
  [[ "$screen_h" =~ ^[0-9]+$ ]] || return 0

  for id in $(xprop -root _NET_CLIENT_LIST 2>/dev/null | cut -d'#' -f2 | tr -d ' ' | tr ',' ' '); do
    [[ -n "$id" ]] || continue
    xprop -id "$id" WM_CLASS 2>/dev/null | grep xfce4-panel >/dev/null || continue
    geom="$(xwininfo -id "$id" 2>/dev/null)" || continue
    w="$(awk '/Width:/{print $NF; exit}' <<< "$geom")"
    h="$(awk '/Height:/{print $NF; exit}' <<< "$geom")"
    y="$(awk '/Absolute upper-left Y/{print $NF; exit}' <<< "$geom")"
    [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]] || continue
    # Skip xfce4-panel's tiny offscreen helper windows.
    (( w > 100 && h > 10 )) || continue
    seen=$(( seen + 1 ))
    if (( y > lowest )); then lowest=$y; lowest_h=$h; fi
  done

  if (( seen == 0 )); then
    warn "The panel edge could NOT be verified; autohide likely collapsed the panel before it could be measured."
    return 0
  fi
  if (( lowest + lowest_h < screen_h / 2 )); then
    warn "The panel rendered on the TOP half of the screen, not as a footer."
    warn "Drag it to the bottom edge (right-click the panel -> Panel -> Panel Preferences),"
    warn "or re-run with XFCE_DOCK_PANEL=<panel-N> naming the panel that is already at the bottom."
  fi
}


install_panels() {
  [[ -f "$state_dir/panels.bak" ]] || die "No panel snapshot -- run ./xfce.sh backup first."

  local layout_text panel id ptype dock_panel="${XFCE_DOCK_PANEL:-}"
  local role type subproperty value property removed max=0 index
  local -a panels=() roles=() types=() current_dock_ids=() resolved_ids=()
  local -A assigned_plugin_ids=()
  local resolved_plugin_id="" next_plugin_id

  layout_text="$(panel_layout)"
  while IFS='|' read -r role type; do
    [[ -n "$role" && -n "$type" ]] || continue
    roles+=("$role")
    types+=("$type")
  done <<< "$layout_text"

  mapfile -t panels < <(panel_names)
  (( ${#panels[@]} > 0 )) || die "No Xfce panel found."

  if [[ -z "$dock_panel" && -f "$state_dir/dock-panel" ]]; then
    dock_panel="$(<"$state_dir/dock-panel")"
  fi
  # Look for the ENGINE's own plugin, not "a dock-ish plugin". Matching
  # `tasklist` here while the engine is docklike picks the panel carrying the
  # window list -- the very thing being replaced -- and on a two-panel desktop
  # that lands the merged panel on the top bar instead of the bottom one.
  local dock_type=""
  for index in "${!roles[@]}"; do
    [[ "${roles[$index]}" == dock ]] && dock_type="${types[$index]}"
  done
  if [[ -z "$dock_panel" && -n "$dock_type" ]]; then
    for panel in "${panels[@]}"; do
      while IFS= read -r id; do
        ptype="$(xfconf-query -c xfce4-panel -p "/plugins/plugin-$id" 2>/dev/null || true)"
        if [[ "$ptype" == "$dock_type" ]]; then
          dock_panel="$panel"
          break 2
        fi
      done < <(panel_plugin_ids "$panel")
    done
  fi

  # Still nothing to go on, so fall back to geometry: `position` reads
  # `p=<XfceScreenPosition>;x=..;y=..`. The numbering is NOT stable across
  # releases -- this box calls its top panel p=6, while the Vagrant box's
  # bottom panel is p=12 -- so the set below spans both readings and is a
  # TIEBREAK, never a correctness guarantee. XFCE_DOCK_PANEL is the authority,
  # and verify_panel_edge checks the rendered result afterwards.
  if [[ -z "$dock_panel" ]]; then
    for panel in "${panels[@]}"; do
      case "$(xfconf-query -c xfce4-panel -p "/panels/$panel/position" 2>/dev/null)" in
        p=8*|p=9*|p=10*|p=11*|p=12*) dock_panel="$panel"; break ;;
      esac
    done
  fi
  dock_panel="${dock_panel:-${panels[${#panels[@]}-1]}}"

  local panel_found=false
  for panel in "${panels[@]}"; do
    [[ "$panel" == "$dock_panel" ]] && panel_found=true
  done
  [[ "$panel_found" == true ]] || die "Requested dock panel '$dock_panel' does not exist."
  printf '%s\n' "$dock_panel" > "$state_dir/dock-panel"
  log "Using $dock_panel as the single bottom panel."

  panel_stop

  mapfile -t current_dock_ids < <(panel_plugin_ids "$dock_panel")
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if (( id > max )); then max=$id; fi
  done < <(all_plugin_ids)
  next_plugin_id=$(( max + 1 ))

  for index in "${!roles[@]}"; do
    role="${roles[$index]}"
    type="${types[$index]}"
    resolve_role_plugin "$role" "$type" "$dock_panel" "$index"
    resolved_ids+=("$resolved_plugin_id")

    while IFS='|' read -r subproperty type value; do
      [[ -n "$subproperty" ]] || continue
      property="/plugins/plugin-$resolved_plugin_id/$subproperty"
      record_prop "$state_dir/plugin-props.bak" "plugin-$resolved_plugin_id" \
        xfce4-panel "$property" "$type"
      xfconf-query -c xfce4-panel -p "$property" --create --type "$type" --set "$value" >/dev/null
      log "Set $role ($resolved_plugin_id) $subproperty=$value."
    done < <(plugin_subprops "$role")
  done

  set_panel_plugin_ids "$dock_panel" "${resolved_ids[@]}"
  log "Set $dock_panel plugin order: ${resolved_ids[*]}."

  while IFS='|' read -r property type value; do
    record_prop "$state_dir/panel-props.bak" "$dock_panel" xfce4-panel \
      "/panels/$dock_panel/$property" "$type"
    xfconf-query -c xfce4-panel -p "/panels/$dock_panel/$property" \
      --create --type "$type" --set "$value" >/dev/null
    log "Set $dock_panel $property=$value."
  done < <(target_panel_props)

  removed=false
  for panel in "${panels[@]}"; do
    [[ "$panel" == "$dock_panel" ]] && continue
    record_removed_panel_props "$panel"
    if ! grep -Fxq "$panel" "$state_dir/panels-removed.bak" 2>/dev/null; then
      printf '%s\n' "$panel" >> "$state_dir/panels-removed.bak"
    fi
    removed=true
  done

  set_panel_array "${dock_panel#panel-}"
  if [[ "$removed" == true ]]; then
    log "Reduced /panels to $dock_panel."
  fi
  for panel in "${panels[@]}"; do
    [[ "$panel" == "$dock_panel" ]] && continue
    xfconf-query -c xfce4-panel -p "/panels/$panel" -R -r >/dev/null
    log "Removed $panel; its plugins remain unreferenced and intact."
  done

  install_ibus_hide
  panel_start

  verify_panel_edge
  log "Installed the single bottom Xfce panel."
}

replay_prop_state() {
  local state_file="$1" _key property type value
  [[ -f "$state_file" ]] || return 0

  while IFS='|' read -r _key property type value; do
    [[ -n "$property" ]] || continue
    if [[ "$type" == UNSET ]]; then
      xfconf-query -c xfce4-panel -p "$property" --reset 2>/dev/null || true
    else
      xfconf-query -c xfce4-panel -p "$property" \
        --create --type "$type" --set "$value" >/dev/null
    fi
  done < "$state_file"
}

restore_panels() {
  [[ -f "$state_dir/panels.bak" ]] || return 0

  # `revert` does not go through backup(), so this is the other entry point
  # where a pre-rewrite snapshot has to be folded in before it is replayed.
  migrate_legacy_state

  local panel ids id changed
  local -a panel_ids=() recorded_ids=() filtered_ids=()
  local -A added_ids=()

  panel_stop

  restore_ibus_hide

  mapfile -t panel_ids < <(
    {
      panel_array_ids
      if [[ -f "$state_dir/panels-removed.bak" ]]; then
        sed -n 's/^panel-\([0-9]\{1,\}\)$/\1/p' "$state_dir/panels-removed.bak"
      fi
    } | sort -un
  )
  if (( ${#panel_ids[@]} > 0 )); then
    set_panel_array "${panel_ids[@]}"
    log "Restored panel ids: ${panel_ids[*]}."
  fi

  replay_prop_state "$state_dir/panel-props.bak"
  replay_prop_state "$state_dir/plugin-props.bak"

  while IFS='|' read -r panel ids; do
    [[ -n "$panel" ]] || continue
    read -r -a recorded_ids <<< "$ids"
    filtered_ids=()
    for id in "${recorded_ids[@]}"; do
      if plugin_entry_exists "$id"; then
        filtered_ids+=("$id")
      else
        log "Dropped missing plugin-$id while restoring $panel."
      fi
    done
    if (( ${#filtered_ids[@]} > 0 )); then
      set_panel_plugin_ids "$panel" "${filtered_ids[@]}"
    else
      xfconf-query -c xfce4-panel -p "/panels/$panel/plugin-ids" --reset 2>/dev/null || true
    fi
  done < "$state_dir/panels.bak"

  if [[ -f "$state_dir/panels-added.bak" ]]; then
    while IFS= read -r id; do
      [[ "$id" =~ ^[0-9]+$ ]] && added_ids["$id"]=1
    done < "$state_dir/panels-added.bak"

    # Snapshot panels no longer reference our ids after the replay above.
    # Also unlink them from any panel the user added later before deleting the
    # entries, so no live array can be left dangling.
    for panel in $(panel_names); do
      mapfile -t recorded_ids < <(panel_plugin_ids "$panel")
      filtered_ids=()
      changed=false
      for id in "${recorded_ids[@]}"; do
        if [[ -n "${added_ids[$id]+_}" ]]; then
          changed=true
        else
          filtered_ids+=("$id")
        fi
      done
      if [[ "$changed" == true ]]; then
        if (( ${#filtered_ids[@]} > 0 )); then
          set_panel_plugin_ids "$panel" "${filtered_ids[@]}"
        else
          xfconf-query -c xfce4-panel -p "/panels/$panel/plugin-ids" --reset 2>/dev/null || true
        fi
        log "Unlinked script-created plugins from $panel."
      fi
    done

    for id in "${!added_ids[@]}"; do
      xfconf-query -c xfce4-panel -p "/plugins/plugin-$id" -R -r 2>/dev/null || true
      log "Deleted script-created plugin-$id."
    done
    rm -f "$state_dir/panels-added.bak"
  fi

  rm -f "$state_dir/panels-removed.bak" \
    "$state_dir/panel-props.bak" \
    "$state_dir/plugin-props.bak" \
    "$state_dir/dock-panel"

  panel_start
  log "Panel layout restored."
}

# ------------------------------------------------------------ components ----

install_deps() {
  require_apt
  local missing=() pkg
  for pkg in "${apt_packages[@]}"; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep '^install ok installed$' >/dev/null \
      || missing+=("$pkg")
  done
  if (( ${#missing[@]} == 0 )); then
    log "All distro packages already installed."
    return
  fi
  log "Installing: ${missing[*]}"
  sudo apt-get update
  sudo apt-get install -y "${missing[@]}"
}

install_theme() {
  local dest="$HOME/.themes"
  # ~/.themes rather than /usr/share/themes: no sudo needed, and `rm -rf` is a
  # complete uninstall. Xfce and GTK read it with higher precedence anyway.
  if [[ -f "$dest/$theme_name/gtk-3.0/gtk.css" && "${FORCE:-0}" != "1" ]]; then
    log "$theme_name already built -- skipping (FORCE=1 to rebuild)."
    return
  fi
  require_cmd git "build the Tokyo Night theme"
  command -v sassc >/dev/null 2>&1 || die "sassc is required to compile the theme. Run: ./xfce.sh deps"

  log "Building $theme_name from ${tokyonight_pin:0:12}"
  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064  # expand $tmp now, not when the trap fires
  trap "rm -rf '$tmp'" RETURN

  git init --quiet "$tmp"
  git -C "$tmp" remote add origin "$tokyonight_repo"
  git -C "$tmp" fetch --depth 1 --quiet origin "$tokyonight_pin"
  git -C "$tmp" checkout --quiet FETCH_HEAD
  local got; got="$(git -C "$tmp" rev-parse HEAD)"
  [[ "$got" == "$tokyonight_pin" ]] \
    || die "Theme commit mismatch: wanted $tokyonight_pin, got $got. Refusing to build."

  mkdir -p "$dest"
  "$tmp/themes/install.sh" --dest "$dest" --theme default --color dark --size standard >/dev/null

  # Upstream's installer prints an error and still exits 0 when sassc is
  # missing, so trust the artefact rather than the exit status.
  [[ -f "$dest/$theme_name/gtk-3.0/gtk.css" ]] \
    || die "Theme build produced no gtk.css at $dest/$theme_name/gtk-3.0/"
  log "Installed $dest/$theme_name"
}

install_fonts() {
  # Match the exact family that tilix/night-owl.dconf asks for. The nerd-fonts
  # tarball also installs short aliases ("JetBrainsMono NF", "NFM", "NFP"), and
  # a box can have those from an older partial install while still lacking the
  # long name -- in which case Tilix silently falls back to a default font. So
  # grep for the long family, not just "jetbrains".
  if fc-list : family 2>/dev/null | grep 'JetBrainsMono Nerd Font' >/dev/null && [[ "${FORCE:-0}" != "1" ]]; then
    log "JetBrainsMono Nerd Font already available -- skipping."
    return
  fi
  require_cmd curl "download the JetBrainsMono Nerd Font"
  local dir="$HOME/.local/share/fonts/JetBrainsMonoNerdFont"
  log "Installing JetBrainsMono Nerd Font $nerd_font_version"
  rm -rf "$dir"; mkdir -p "$dir"
  local tarball; tarball="$(mktemp -t JetBrainsMono.XXXXXX.tar.xz)"
  curl -fsSL --retry 4 --retry-delay 2 -o "$tarball" \
    "https://github.com/ryanoasis/nerd-fonts/releases/download/${nerd_font_version}/JetBrainsMono.tar.xz"
  # Same contract as the theme and dock commits: fetch a fixed version, then
  # prove it is the artifact we expected before unpacking it. `latest` would
  # restyle every terminal on the box the day upstream cuts a release, and an
  # unverified tarball is remote code reaching a font directory.
  local got; got="$(sha256sum "$tarball" | cut -d' ' -f1)"
  if [[ "$got" != "$nerd_font_sha256" ]]; then
    rm -f "$tarball"
    die "JetBrainsMono $nerd_font_version checksum mismatch: wanted $nerd_font_sha256, got $got. Refusing to install."
  fi
  tar -xJf "$tarball" -C "$dir"
  rm -f "$tarball"
  fc-cache -f "$dir" >/dev/null
}

install_icons() {
  local size
  # Papirus-Dark inherits from `breeze-dark,hicolor`, NOT from Papirus, so
  # `utilities-terminal` -- which only Papirus ships -- never resolves, and
  # Tilix logs an icon warning every time its close-confirmation dialog opens.
  # hicolor is GTK's universal fallback, so an overlay there fixes the lookup
  # for whichever theme is active. Safe to shadow, because the index.theme is a
  # verbatim copy of the system one and keeps its full Directories list.
  local hicolor="$HOME/.local/share/icons/hicolor"
  if [[ -d /usr/share/icons/Papirus ]]; then
    for size in 16x16 22x22 24x24 32x32 48x48 64x64; do
      mkdir -p "$hicolor/$size/apps"
      ln -sfn "/usr/share/icons/Papirus/$size/apps/utilities-terminal.svg" \
              "$hicolor/$size/apps/utilities-terminal.svg"
    done
    mkdir -p "$hicolor/scalable/apps"
    ln -sfn "/usr/share/icons/Papirus/64x64/apps/utilities-terminal.svg" \
            "$hicolor/scalable/apps/utilities-terminal.svg"
    # gtk-update-icon-cache will not write a cache without an index.theme.
    [[ -e "$hicolor/index.theme" ]] || cp /usr/share/icons/hicolor/index.theme "$hicolor/"
    gtk-update-icon-cache -q -f "$hicolor" >/dev/null 2>&1 || true
    log "hicolor overlay installed (utilities-terminal)."
  else
    warn "Papirus not installed -- skipping the hicolor terminal-icon overlay. Run: ./xfce.sh deps"
  fi

  # Papirus-Dark ships a flat grey com.gexperts.Tilix.svg that wins over the
  # hicolor chain and is indistinguishable from a generic terminal at panel
  # size. Override it with upstream's navy icon in a DERIVED theme, so a dock
  # shows real branding without shadowing Papirus-Dark itself.
  local tilix_icon="/usr/share/icons/hicolor/scalable/apps/com.gexperts.Tilix.svg"
  if [[ -f "$tilix_icon" && -d /usr/share/icons/Papirus-Dark ]]; then
    local overlay="$HOME/.local/share/icons/$icon_overlay"
    mkdir -p "$overlay"
    install -m 0644 "$payload/icons/$icon_overlay.index.theme" "$overlay/index.theme"
    for size in 16x16 22x22 24x24 32x32 48x48 64x64; do
      mkdir -p "$overlay/$size/apps"
      ln -sfn "$tilix_icon" "$overlay/$size/apps/com.gexperts.Tilix.svg"
    done
    gtk-update-icon-cache -q -f "$overlay" >/dev/null 2>&1 || true
    log "$icon_overlay overlay installed (derives from Papirus-Dark)."
  else
    warn "Papirus-Dark not installed -- skipping the derived icon theme. Run: ./xfce.sh deps"
  fi
}

# Deploy the repository payload verbatim. The timestamped copy is a
# belt-and-braces convenience only; revert does not consume it, so the
# state-directory capture is the rollback source that matters.
install_gtkcss() {
  capture_gtkcss_state
  local target="$HOME/.config/gtk-3.0/gtk.css"
  local source="$payload/gtk-3.0/gtk.css"
  mkdir -p "$(dirname "$target")"
  if [[ -f "$target" ]] && ! cmp -s "$source" "$target"; then
    cp -a "$target" "${target}.backup.$(date +%Y%m%d-%H%M%S)"
  fi
  install -m 0644 "$source" "$target"
  log "Installed $target"
}

apply_settings() {
  local channel property type value count=0
  while IFS='|' read -r channel property type value; do
    [[ -n "$channel" ]] || continue
    xfconf-query -c "$channel" -p "$property" --create --type "$type" --set "$value"
    (( ++count ))
  done < <(settings_table)
  log "Applied $count xfconf settings (live -- no logout needed)."
}

install_tilix() {
  capture_tilix_state
  # `dconf load` without -f MERGES, so every Tilix preference not named in
  # night-owl.dconf survives. This is the deliberate difference from the VM,
  # which uses `dconf compile` and replaces the entire database.
  #
  # It merges per KEY, though, and `profile-list` is a single key holding an
  # array -- loading it verbatim would REPLACE the list and orphan any other
  # profile: still there under /profiles/<uuid>/, but gone from Tilix's UI,
  # silently. So load everything except the two list keys and union them here.
  grep -Ev '^(profile-list|default-profile)=' "$payload/tilix/night-owl.dconf" \
    | dconf load "/com/gexperts/Tilix/"

  local profiles
  profiles="$(dconf read /com/gexperts/Tilix/profile-list 2>/dev/null || true)"
  if [[ "$profiles" != *"$tilix_profile"* ]]; then
    if [[ -z "$profiles" || "$profiles" == "@as []" || "$profiles" == "[]" ]]; then
      profiles="['$tilix_profile']"
    else
      profiles="${profiles%]}, '$tilix_profile']"
    fi
    dconf write /com/gexperts/Tilix/profile-list "$profiles"
  fi
  dconf write /com/gexperts/Tilix/default-profile "'$tilix_profile'"
  log "Tilix Night Owl palette loaded into profile ${tilix_profile:0:8}."

  # Tilix needs VTE's bash hooks sourced in INTERACTIVE shells or it shows
  # "Configuration Issue Detected". Debian and Ubuntu ship those hooks in
  # /etc/profile.d, which only LOGIN shells read, while Tilix spawns non-login
  # interactive shells -- hence the explicit guard appended to bashrc.
  local candidate vte_script=""
  for candidate in /etc/profile.d/vte-2.91.sh /etc/profile.d/vte.sh; do
    [[ -f "$candidate" ]] && { vte_script="$candidate"; break; }
  done
  if [[ -z "$vte_script" ]]; then
    warn "No VTE profile script found -- skipping Tilix shell integration."
  elif grep -q 'TILIX_ID' "$HOME/.bashrc" 2>/dev/null; then
    log "VTE shell integration already present in ~/.bashrc."
  else
    # Fenced with markers so `revert` can remove exactly this block and
    # nothing else -- an unfenced append would be unremovable without
    # guessing at line numbers in a file the user also edits by hand.
    cat >> "$HOME/.bashrc" <<BASHRC_VTE

# >>> xfce.sh: VTE shell integration for Tilix >>>
# OSC 7 cwd tracking + prompt markers.
if [ -n "\$TILIX_ID" ] || [ -n "\$VTE_VERSION" ]; then
  . $vte_script
fi
# <<< xfce.sh: VTE shell integration for Tilix <<<
BASHRC_VTE
    log "Added VTE shell integration to ~/.bashrc"
  fi
}

install_screenshot() {
  local bin="$HOME/.local/bin/screenshot-region"
  mkdir -p "$(dirname "$bin")"
  install -m 0755 "$payload/bin/screenshot-region" "$bin"
  mkdir -p "${XDG_PICTURES_DIR:-$HOME/Pictures}/Screenshots"
  # Absolute path: xfce4-settings spawns the command without a login shell, so
  # ~/.local/bin is not guaranteed to be on PATH.
  xfconf-query -c xfce4-keyboard-shortcuts -p /commands/custom/Print \
    --create --type string --set "$bin"
  log "Print key bound to $bin"
}

install_rofi() {
  command -v rofi >/dev/null 2>&1 \
    || die "rofi not found -- run ./xfce.sh deps first."

  local theme_dir="$HOME/.config/rofi/themes"
  local desktop_dir="$HOME/.local/share/applications"
  local config="$HOME/.config/rofi/config.rasi"
  local state_file="$state_dir/rofi.state"
  local grid_command="rofi -show drun -show-icons -theme night-owl"
  local run_command="rofi -show run -theme night-owl-run"
  local source destination backup property command
  local -a sources=(
    "$payload/rofi/night-owl.rasi"
    "$payload/rofi/night-owl-run.rasi"
    "$payload/applications/night-owl-launcher.desktop"
  )
  local -a destinations=(
    "$theme_dir/night-owl.rasi"
    "$theme_dir/night-owl-run.rasi"
    "$desktop_dir/night-owl-launcher.desktop"
  )
  local index

  mkdir -p "$state_dir" "$theme_dir" "$desktop_dir"
  touch "$state_file"

  for index in "${!sources[@]}"; do
    source="${sources[$index]}"
    destination="${destinations[$index]}"
    if ! grep -Fqx "created|$destination" "$state_file" \
      && ! grep -Fqx "existed|$destination" "$state_file"; then
      if [[ -e "$destination" || -L "$destination" ]]; then
        backup="$state_dir/$(basename "$destination").bak"
        cp -a -- "$destination" "$backup"
        printf 'existed|%s\n' "$destination" >> "$state_file"
      else
        printf 'created|%s\n' "$destination" >> "$state_file"
      fi
    fi
    if grep -Fqx "existed|$destination" "$state_file"; then
      backup="$state_dir/$(basename "$destination").bak"
      [[ -e "$backup" || -L "$backup" ]] \
        || die "Rofi snapshot is incomplete: $backup is missing."
    fi
    rm -f -- "$destination"
    install -m 0644 "$source" "$destination"
  done

  if [[ ! -e "$config" && ! -L "$config" ]]; then
    if ! grep -Fqx "created|$config" "$state_file"; then
      printf 'created|%s\n' "$config" >> "$state_file"
    fi
    printf '@theme "night-owl"\n' > "$config"
  elif ! grep -Fqx "created|$config" "$state_file"; then
    warn "$config already exists; leaving it unchanged. Select the night-owl theme there manually if desired."
  fi

  # These checks prove only that each file parses, not anything about how it
  # looks. A malformed .rasi does not fail loudly at runtime -- rofi silently
  # falls back to its default theme -- so parsing is the only honest signal.
  #
  # Deliberately NOT fatal. This runs late in `all`, after apt, the SASS theme
  # build and the docklike compile, and immediately before install_pins. Dying
  # here would cost the user their dock pins over a cosmetic launcher. Instead
  # a bad theme costs only the launcher: drop the desktop entry, leave the
  # existing appfinder shortcuts alone, and let install_pins discard the now
  # unresolvable pin with the warning it already emits.
  local theme_file bad=0
  for theme_file in "$theme_dir/night-owl.rasi" "$theme_dir/night-owl-run.rasi"; do
    rofi -no-config -theme "$theme_file" -dump-theme >/dev/null 2>&1 && continue
    warn "Rofi theme failed to parse: $theme_file"
    bad=1
  done
  if (( bad )); then
    rm -f -- "$desktop_dir/night-owl-launcher.desktop"
    warn "Left the existing application-finder shortcuts untouched."
    return 0
  fi

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$desktop_dir" || true
  fi

  while IFS='|' read -r property command; do
    record_prop "$state_dir/rofi-keys.bak" rofi xfce4-keyboard-shortcuts \
      "$property" string
    xfconf-query -c xfce4-keyboard-shortcuts -p "$property" \
      --create --type string --set "$command" >/dev/null
  done <<BINDINGS
/commands/custom/<Super>space|$grid_command
/commands/custom/<Alt>F3|$grid_command
/commands/custom/<Alt>F2|$run_command
/commands/custom/<Super>r|$run_command
BINDINGS

  log "Bound Super+Space and Alt+F3 to the application grid; Alt+F2 and Super+R to the command prompt."
}

restore_rofi() {
  local state_file="$state_dir/rofi.state"
  [[ -f "$state_file" ]] || return 0

  local key property type value state path backup
  if [[ -f "$state_dir/rofi-keys.bak" ]]; then
    while IFS='|' read -r key property type value; do
      [[ -n "$property" ]] || continue
      if [[ "$type" == "UNSET" ]]; then
        xfconf-query -c xfce4-keyboard-shortcuts -p "$property" \
          --reset 2>/dev/null || true
      else
        xfconf-query -c xfce4-keyboard-shortcuts -p "$property" \
          --create --type "$type" --set "$value" >/dev/null
      fi
    done < "$state_dir/rofi-keys.bak"
  fi

  while IFS='|' read -r state path; do
    [[ -n "$path" ]] || continue
    case "$state" in
      created)
        rm -f -- "$path"
        ;;
      existed)
        backup="$state_dir/$(basename "$path").bak"
        [[ -e "$backup" || -L "$backup" ]] \
          || die "Rofi snapshot is incomplete: $backup is missing."
        mkdir -p "$(dirname "$path")"
        rm -f -- "$path"
        cp -a -- "$backup" "$path"
        rm -f -- "$backup"
        ;;
      *)
        die "Invalid Rofi file snapshot state: $state"
        ;;
    esac
  done < "$state_file"

  rm -f -- "$state_file" "$state_dir/rofi-keys.bak"
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$HOME/.local/share/applications" || true
  fi
}

# ------------------------------------------------------------------ dock ----

dock_docklike() {
  require_apt
  if dpkg-query -W -f='${Status}' xfce4-docklike-plugin 2>/dev/null | grep '^install ok installed$' >/dev/null; then
    log "xfce4-docklike-plugin already installed."
    return
  fi
  # Prefer the distro package wherever the release has one -- Ubuntu ships it
  # from 25.10 onward. Only 24.04 and older need the source build below.
  local candidate
  candidate="$(apt-cache policy xfce4-docklike-plugin 2>/dev/null | sed -n 's/^  Candidate: //p')"
  if [[ -n "$candidate" && "$candidate" != "(none)" ]]; then
    log "Installing xfce4-docklike-plugin $candidate from the distro archive."
    sudo apt-get install -y xfce4-docklike-plugin
    return
  fi

  require_cmd git "build xfce4-docklike-plugin from source"
  log "No archive package -- building docklike $docklike_version from ${docklike_pin:0:12}"
  local build_deps=(
    build-essential xfce4-dev-tools intltool
    libxfce4panel-2.0-dev libxfce4ui-2-dev libxfce4util-dev
    libwnck-3-dev libgtk-3-dev libglib2.0-dev libcairo2-dev
    libx11-dev libice-dev
  )
  local missing=() pkg
  for pkg in "${build_deps[@]}"; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep '^install ok installed$' >/dev/null \
      || missing+=("$pkg")
  done
  if (( ${#missing[@]} )); then
    sudo apt-get update
    sudo apt-get install -y "${missing[@]}"
    # docklike is not in the noble archive, so compiling is the only route --
    # but the toolchain it drags in is ~140 MB that nothing needs afterwards.
    # Mark only what WE installed as automatic, so a later `apt autoremove`
    # can reclaim it. Nothing is removed here, and `apt-mark manual` undoes it.
    #
    # build-essential is deliberately exempt: silently making the compiler
    # removable on a development box is a worse outcome than the disk it uses.
    local reclaim=()
    for pkg in "${missing[@]}"; do
      [[ "$pkg" == build-essential ]] || reclaim+=("$pkg")
    done
    if (( ${#reclaim[@]} )); then
      # Non-critical: this runs before the compile, so letting a dpkg lock or
      # an odd package state abort the whole dock install would trade a working
      # build for a cosmetic disk saving. Report honestly either way rather
      # than claiming success on a swallowed failure.
      if sudo apt-mark auto "${reclaim[@]}" >/dev/null 2>&1; then
        log "Marked ${#reclaim[@]} build-only packages auto-removable (apt autoremove reclaims them)."
      else
        warn "Could not mark build-only packages auto-removable. Run: sudo apt-mark auto ${reclaim[*]}"
      fi
    fi
  fi

  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN
  local src="$tmp/src" stage="$tmp/stage"

  git init --quiet "$src"
  git -C "$src" remote add origin "$docklike_repo"
  git -C "$src" fetch --depth 1 --quiet origin "$docklike_pin"
  git -C "$src" checkout --quiet FETCH_HEAD
  local got; got="$(git -C "$src" rev-parse HEAD)"
  [[ "$got" == "$docklike_pin" ]] \
    || die "docklike commit mismatch: wanted $docklike_pin, got $got. Refusing to build."

  # xfce4-panel only scans $libdir/xfce4/panel/plugins, and on Debian/Ubuntu
  # that is the multiarch /usr/lib/<triplet> -- never /usr/local/lib. A default
  # --prefix would build cleanly and then never be found by the panel.
  local triplet; triplet="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
  ( cd "$src" && ./autogen.sh --prefix=/usr --libdir="/usr/lib/$triplet" >/dev/null )
  make -C "$src" -j"$(nproc)" >/dev/null
  make -C "$src" install DESTDIR="$stage" >/dev/null

  [[ -f "$stage/usr/lib/$triplet/xfce4/panel/plugins/libdocklike.so" ]] \
    || die "Build produced no libdocklike.so -- refusing to package."

  # The panel discovers plugins by the .desktop basename in this datadir, and
  # /plugins/plugin-N must contain that basename. A missing descriptor makes
  # the daemon silently drop the new dock after install_panels removes the old
  # window list, even when the module itself built successfully.
  [[ -f "$stage/usr/share/xfce4/panel/plugins/docklike.desktop" ]] \
    || die "Build produced no docklike.desktop -- refusing to package."

  # Wrapped as a real .deb instead of `sudo make install`, so dpkg owns the
  # files, `apt remove xfce4-docklike-plugin` is a clean uninstall, and it is
  # visible in `dpkg -l` rather than an untracked stray .so that would silently
  # stop loading after a panel ABI bump.
  rm -f "$stage/usr/lib/$triplet/xfce4/panel/plugins/"*.la
  mkdir -p "$stage/DEBIAN"
  cat > "$stage/DEBIAN/control" <<CONTROL
Package: xfce4-docklike-plugin
Version: ${docklike_version}-local1
Architecture: $(dpkg --print-architecture)
Maintainer: local build <build@localhost>
Section: xfce
Priority: optional
Depends: libc6, libgtk-3-0t64 | libgtk-3-0, libglib2.0-0t64 | libglib2.0-0, libcairo2, libwnck-3-0, libx11-6, libxfce4panel-2.0-4, libxfce4ui-2-0, libxfce4util7
Description: Docklike taskbar plugin for the Xfce panel
 Minimalist taskbar that groups windows per application and supports pinning,
 in the style of the Windows 11 taskbar or a macOS dock.
 .
 Built locally from upstream commit ${docklike_pin}
 because this Ubuntu release has no archive package: docklike releases after
 ${docklike_version} require libxfce4windowing >= 4.19.4, which ships with
 Xfce 4.20.
CONTROL

  local deb
  deb="$tmp/xfce4-docklike-plugin_${docklike_version}-local1_$(dpkg --print-architecture).deb"
  dpkg-deb --root-owner-group --build "$stage" "$deb" >/dev/null
  sudo apt-get install -y "$deb"
  log "Installed docklike $docklike_version."
  log "Add it with: right-click the panel -> Panel -> Add New Items -> Docklike Taskbar"
}

dock_plank() {
  require_apt
  sudo apt-get install -y plank
  mkdir -p "$HOME/.config/autostart"
  cat > "$HOME/.config/autostart/plank.desktop" <<'PLANK'
[Desktop Entry]
Type=Application
Name=Plank
Exec=plank
X-GNOME-Autostart-enabled=true
PLANK
  log "Plank installed and set to autostart. Start it now with: plank &"
}

dock_tasklist() {
  # Turn the panel's built-in window list into a grouped, icon-only dock. No
  # install and nothing to maintain, but no pinning either -- add `launcher`
  # plugins next to it for pinned apps.
  local prop id=""
  while read -r prop; do
    if [[ "$(xfconf-query -c xfce4-panel -p "$prop" 2>/dev/null)" == tasklist ]]; then
      id="${prop##*/}"; break
    fi
  done < <(xfconf-query -c xfce4-panel -p /plugins -l 2>/dev/null)
  [[ -n "$id" ]] \
    || die "No tasklist plugin on any panel. Add one first: Panel -> Add New Items -> Window Buttons."
  xfconf-query -c xfce4-panel -p "/plugins/$id/grouping"     --create --type bool --set true
  xfconf-query -c xfce4-panel -p "/plugins/$id/show-labels"  --create --type bool --set false
  xfconf-query -c xfce4-panel -p "/plugins/$id/flat-buttons" --create --type bool --set true
  log "Configured $id as a grouped, icon-only dock."
}

install_dock() {
  case "${1:-}" in
    docklike) dock_docklike ;;
    plank)    dock_plank ;;
    tasklist) dock_tasklist ;;
    *)        die "Usage: ./xfce.sh dock <docklike|plank|tasklist>" ;;
  esac
}

install_pins() {
  local plugin_id="" id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if [[ "$(xfconf-query -c xfce4-panel -p "/plugins/plugin-$id" 2>/dev/null || true)" == docklike ]]; then
      plugin_id="$id"
      break
    fi
  done < <(all_plugin_ids)
  if [[ -z "$plugin_id" ]]; then
    warn "Docklike is not installed in the panel -- pins were not changed."
    return 0
  fi

  local configured="${XFCE_DOCK_PINS-"$default_dock_pins"}"
  local -a requested=() pins=()
  read -r -a requested <<< "$configured" || true
  local pin data_dir found
  for pin in "${requested[@]}"; do
    found=false
    if [[ "$pin" != */* ]]; then
      for data_dir in \
        "$HOME/.local/share/applications" \
        /usr/local/share/applications \
        /usr/share/applications \
        /var/lib/flatpak/exports/share/applications; do
        if [[ -f "$data_dir/$pin.desktop" ]]; then
          found=true
          break
        fi
      done
    fi
    if [[ "$found" == true ]]; then
      pins+=("$pin")
    else
      warn "Dropping dock pin '$pin': no matching desktop entry."
    fi
  done
  if (( ${#pins[@]} == 0 )); then
    warn "No dock pins resolve to installed desktop entries -- pins were not changed."
    return 0
  fi

  local serialized rc rc_state rc_backup
  printf -v serialized '%s;' "${pins[@]}"
  rc="$HOME/.config/xfce4/panel/docklike-$plugin_id.rc"
  rc_state="$state_dir/docklike-rc.state"
  rc_backup="$state_dir/docklike-rc.bak"
  mkdir -p "$(dirname "$rc")" "$state_dir"

  # Snapshot only once: every later run must continue to restore the state from
  # before this script's first pin write, not whatever an earlier run seeded.
  if [[ ! -e "$rc_state" ]]; then
    if [[ -f "$rc" ]]; then
      cp -a -- "$rc" "$rc_backup"
      printf 'present|%s\n' "$rc" > "$rc_state"
    else
      rm -f -- "$rc_backup"
      printf 'absent|%s\n' "$rc" > "$rc_state"
    fi
  fi

  if [[ -f "$rc" ]]; then
    local tmp
    tmp="$(mktemp "$rc.tmp.XXXXXX")"
    # Replay every line except pinned= inside [user], so docklike's roughly
    # twenty unrelated settings survive; append the key when that group lacks
    # it, or append a new [user] group when the file has none.
    if ! PINNED_VALUE="$serialized" awk '
      function write_pins() {
        if (!wrote_pins) {
          print "pinned=" ENVIRON["PINNED_VALUE"]
          wrote_pins = 1
        }
      }
      /^\[[^]]+\][[:space:]]*$/ {
        if (in_user) {
          write_pins()
        }
        in_user = ($0 ~ /^\[user\][[:space:]]*$/)
        if (in_user) {
          saw_user = 1
        }
        print
        next
      }
      in_user && /^[[:space:]]*pinned[[:space:]]*=/ {
        write_pins()
        next
      }
      { print }
      END {
        if (in_user) {
          write_pins()
        }
        if (!saw_user) {
          if (NR > 0) {
            print ""
          }
          print "[user]"
          print "pinned=" ENVIRON["PINNED_VALUE"]
        }
      }
    ' "$rc" > "$tmp"; then
      rm -f -- "$tmp"
      die "Could not update docklike pins in $rc."
    fi
    chmod --reference="$rc" "$tmp"
    mv -f -- "$tmp" "$rc"
  else
    printf '[user]\npinned=%s\n' "$serialized" > "$rc"
  fi

  # Docklike 0.4.2 reads this file only at plugin construction; it has no
  # xfconf watcher, so the panel must be restarted for a seeded value to take
  # effect. It also rewrites the file after any live pin action, so this has to
  # run AFTER install_panels has settled the dock plugin -- seeding earlier
  # would either find no docklike plugin at all on a first run, or write an rc
  # named for a plugin id install_panels then supersedes.
  panel_restart
  log "Pinned ${#pins[@]} applications in docklike-$plugin_id."
}

restore_pins() {
  local rc_state="$state_dir/docklike-rc.state"
  [[ -f "$rc_state" ]] || return 0

  local state rc
  IFS='|' read -r state rc < "$rc_state"
  case "$state" in
    present)
      [[ -f "$state_dir/docklike-rc.bak" ]] \
        || die "Docklike pin snapshot is incomplete: $state_dir/docklike-rc.bak is missing."
      mkdir -p "$(dirname "$rc")"
      rm -f -- "$rc"
      cp -a -- "$state_dir/docklike-rc.bak" "$rc"
      ;;
    absent)
      rm -f -- "$rc"
      ;;
    *)
      die "Invalid docklike pin snapshot state: $state"
      ;;
  esac
  rm -f -- "$rc_state" "$state_dir/docklike-rc.bak"
}

# ------------------------------------------------------- status / revert ----

status() {
  local channel property type want have id panel rc
  local dock_id="" pinned_value="<none>" dock_plugin_count=0
  local -a panels=() plugin_ids=()
  printf '%-16s %-26s %-24s %s\n' CHANNEL PROPERTY CURRENT WANTED
  while IFS='|' read -r channel property type want; do
    [[ -n "$channel" ]] || continue
    have="$(xfconf-query -c "$channel" -p "$property" 2>/dev/null || echo '<unset>')"
    printf '%-16s %-26s %-24s %s\n' "$channel" "$property" "$have" "$want"
  done < <(settings_table)

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if [[ "$(xfconf-query -c xfce4-panel -p "/plugins/plugin-$id" 2>/dev/null || true)" == docklike ]]; then
      dock_id="$id"
      break
    fi
  done < <(all_plugin_ids)

  if [[ -n "$dock_id" ]]; then
    rc="$HOME/.config/xfce4/panel/docklike-$dock_id.rc"
    if [[ -f "$rc" ]]; then
      pinned_value="$(awk '
        /^\[user\][[:space:]]*$/ { in_user = 1; next }
        /^\[[^]]+\][[:space:]]*$/ { in_user = 0 }
        in_user && /^[[:space:]]*pinned[[:space:]]*=/ {
          sub(/^[[:space:]]*pinned[[:space:]]*=/, "")
          print
          exit
        }
      ' "$rc")"
      [[ -n "$pinned_value" ]] || pinned_value="<none>"
    fi
  fi

  mapfile -t panels < <(panel_names)
  if [[ -n "$dock_id" ]]; then
    for panel in "${panels[@]}"; do
      mapfile -t plugin_ids < <(panel_plugin_ids "$panel")
      for id in "${plugin_ids[@]}"; do
        if [[ "$id" == "$dock_id" ]]; then
          dock_plugin_count="${#plugin_ids[@]}"
          break 2
        fi
      done
    done
  fi
  printf '\n%-16s %s\n' "theme"    "$([[ -d "$HOME/.themes/$theme_name" ]] && echo present || echo missing)"
  printf '%-16s %s\n'   "overlay"  "$([[ -d "$HOME/.local/share/icons/$icon_overlay" ]] && echo present || echo missing)"
  printf '%-16s %s\n'   "Print"    "$(xfconf-query -c xfce4-keyboard-shortcuts -p /commands/custom/Print 2>/dev/null || echo '<unset>')"
  printf '%-16s %s\n'   "launcher" "$(xfconf-query -c xfce4-keyboard-shortcuts -p '/commands/custom/<Super>space' 2>/dev/null || echo '<unset>')"
  printf '%-16s %s\n'   "pins"     "$pinned_value"
  printf '%-16s %s\n'   "panels"   "${#panels[@]} $([[ ${#panels[@]} -eq 1 ]] && echo panel || echo panels), $dock_plugin_count $([[ $dock_plugin_count -eq 1 ]] && echo plugin || echo plugins)"
  printf '%-16s %s\n'   "snapshot" "$([[ -f "$state_dir/taken-at" ]] && cat "$state_dir/taken-at" || echo none)"
}

revert() {
  # Gate on the snapshot sentinel, not on settings.bak. Artifacts are captured
  # by whichever subcommand first touches what they describe, so `./xfce.sh
  # gtk` alone yields a state directory holding the user's gtk.css and no
  # settings.bak. Requiring settings.bak here would refuse to restore a
  # snapshot we are actually holding. Every restore block below is already
  # individually conditional on its own artifact, so a partial snapshot
  # restores exactly the parts it captured.
  [[ -f "$state_dir/taken-at" ]] || die "No snapshot in $state_dir -- nothing to revert to."
  local channel property type value state
  # Conditional like every other restore block: a snapshot taken by a
  # standalone `gtk` or `tilix` run has no settings.bak, and redirecting from a
  # missing file would abort the whole revert under `set -e`.
  if [[ -f "$state_dir/settings.bak" ]]; then
    while IFS='|' read -r channel property type value; do
      [[ -n "$channel" ]] || continue
      if [[ "$type" == "UNSET" ]]; then
        xfconf-query -c "$channel" -p "$property" --reset 2>/dev/null || true
      else
        xfconf-query -c "$channel" -p "$property" --create --type "$type" --set "$value"
      fi
    done < "$state_dir/settings.bak"
  fi

  if [[ -f "$state_dir/print-binding.bak" ]]; then
    IFS='|' read -r state value < "$state_dir/print-binding.bak"
    if [[ "$state" == "set" ]]; then
      xfconf-query -c xfce4-keyboard-shortcuts -p /commands/custom/Print \
        --create --type string --set "$value"
    else
      xfconf-query -c xfce4-keyboard-shortcuts -p /commands/custom/Print --reset 2>/dev/null || true
    fi
  fi

  # `-f` (exists) rather than `-s` (non-empty): a user with no Tilix config at
  # all produces an EMPTY dump, and skipping the reset for that case would
  # leave the Night Owl palette applied while reporting a clean revert. Reset
  # unconditionally; only replay the dump when there was something in it.
  if [[ -f "$state_dir/tilix.bak" ]]; then
    dconf reset -f "/com/gexperts/Tilix/" 2>/dev/null || true
    [[ -s "$state_dir/tilix.bak" ]] \
      && dconf load "/com/gexperts/Tilix/" < "$state_dir/tilix.bak"
  fi

  # Keyed on the MARKER, not on the presence of the .bak. A snapshot can now be
  # created by a subcommand that never touched gtk.css at all -- `./xfce.sh
  # tilix` writes taken-at and tilix.bak and nothing else -- and deciding by
  # "no .bak" alone would read that as "there was no gtk.css before us" and
  # delete a file this script never owned. No marker means no claim.
  if [[ -f "$state_dir/gtk.state" ]]; then
    if [[ "$(<"$state_dir/gtk.state")" == present ]]; then
      install -m 0644 "$state_dir/gtk.css.bak" "$HOME/.config/gtk-3.0/gtk.css"
    else
      # The marker recorded "absent" -- there was no gtk.css before us, so ours
      # goes away.
      rm -f "$HOME/.config/gtk-3.0/gtk.css"
    fi
  fi

  restore_rofi
  restore_pins
  restore_panels

  rm -rf "$HOME/.local/share/icons/$icon_overlay" \
         "$HOME/.themes/$theme_name" \
         "$HOME/.local/bin/screenshot-region"

  # Strip the fenced VTE block, plus the blank line the heredoc put above it.
  if grep -q '^# >>> xfce.sh: VTE' "$HOME/.bashrc" 2>/dev/null; then
    sed -i -e '/^# >>> xfce\.sh: VTE/,/^# <<< xfce\.sh: VTE/d' \
           -e '${/^$/d}' "$HOME/.bashrc"
    log "Removed the VTE shell-integration block from ~/.bashrc"
  fi

  log "Reverted to the snapshot from $(cat "$state_dir/taken-at" 2>/dev/null)."
  log "Distro packages, the Nerd Font and any dock were left installed."
}

usage() { sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main() {
  case "${1:-all}" in
    all)
      require_session
      backup
      install_deps
      install_theme
      install_fonts
      install_icons
      install_gtkcss
      apply_settings
      install_tilix
      install_screenshot
      if [[ -n "${XFCE_DOCK:-}" ]]; then
        # Order matters. install_dock only installs the package; the panel
        # plugin entry is created by install_panels, and install_pins needs
        # that entry to exist so it can write docklike-<id>.rc for the right
        # id. Seeding pins before the panel is built silently produces a dock
        # with no pins on a first run.
        install_dock "$XFCE_DOCK"
        install_panels
      fi
      install_rofi
      if [[ -n "${XFCE_DOCK:-}" ]]; then
        # Pins drop desktop ids that do not resolve, so install the launcher first.
        install_pins
      else
        log "Dock not installed. Pick one: ./xfce.sh dock docklike|plank|tasklist"
      fi
      log "Done. Log out and back in if a GTK app still looks unstyled."
      ;;
    deps)       install_deps ;;
    theme)      require_session; backup; install_theme; apply_settings ;;
    fonts)      install_fonts ;;
    icons)      install_icons ;;
    gtk)        install_gtkcss ;;
    settings)   require_session; backup; apply_settings ;;
    tilix)      install_tilix ;;
    screenshot) require_session; backup; install_screenshot ;;
    rofi)       require_session; backup; install_rofi ;;
    dock)       require_session; backup; install_dock "${2:-}" ;;
    pins)       require_session; backup; install_pins ;;
    panels)     require_session; backup; install_panels ;;
    backup)     require_session; backup ;;
    status)     require_session; status ;;
    revert)     require_session; revert ;;
    -h|--help)  usage ;;
    *)          usage >&2; exit 2 ;;
  esac
}

main "$@"
