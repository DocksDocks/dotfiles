# Xfce -- Night Owl desktop

Applies the Night Owl desktop from the Debian 13 Vagrant dev box to a live Xfce
session. Installed by [`../xfce.sh`](../xfce.sh).

| Path | Purpose |
| --- | --- |
| `gtk-3.0/gtk.css` | CSD headerbar button styling |
| `tilix/night-owl.dconf` | Night Owl terminal palette, merged into the Tilix profile |
| `icons/Papirus-Dark-NightOwl.index.theme` | Derived icon theme with local application-icon overrides |
| `bin/screenshot-region` | Region-select screenshot with auto-save and clipboard copy |
| `rofi/night-owl.rasi` | Fullscreen Night Owl application-grid theme |
| `applications/night-owl-launcher.desktop` | Pinnable desktop entry for the rofi launcher |

Everything else the installer manages -- GTK theme, window-manager theme, UI
font, cursor, notification timeout, Print-key binding -- is a value rather than
a file, so it lives in the `settings_table` function in `../xfce.sh`.

## Before the first run

### Prerequisites

Run the session-dependent commands from a live Xfce session with its D-Bus
session bus running. `require_session` checks for `xfconf-query` and a
`DBUS_SESSION_BUS_ADDRESS`, and warns when the current desktop does not report
itself as Xfce. This is more than an environment check: `xfconf-query` talks to
`xfconfd` over that bus. Without it, libxfconf fails with an opaque error that
does not explain that the session bus is missing.

Debian or Ubuntu is also required for commands that install distro packages.
`deps`, `dock docklike` and `dock plank` are apt-only and refuse to run on
other distributions with a clear message. The configuration subcommands work
on any distribution when their packages have been installed by hand.

That apt refusal is enforced in the script, but the installer has not been run
on a non-Debian distribution. It is a guard against starting apt work on the
wrong system, not a claim of end-to-end Fedora or Arch support.

### Paths and displays

Nothing is pinned to the author's machine. The repository root comes from
`${BASH_SOURCE[0]}`, so the clone can live anywhere and `xfce.sh` can be
invoked from any working directory. Snapshot state lives under
`${XDG_STATE_HOME:-$HOME/.local/state}/xfce-nightowl`, and screenshots honour
`$XDG_PICTURES_DIR`.

The panel's `output-name` value is the literal token `Primary`. That is Xfce's
generic reference to whichever monitor is primary, not a hardware output name
such as `eDP-1`. The layout therefore follows the target machine's primary
display.

### Existing desktop state and the safety net

The panel and pin changes are destructive. The installer reduces the desktop
to a **single bottom panel**. On a default two-panel Xfce desktop, one stock
panel is removed. `install_pins` rewrites the whole `pinned=` list rather than
merging it, so pins added by hand disappear unless they are also declared in
`XFCE_DOCK_PINS`. Both states are snapshotted, and `./xfce.sh revert` restores
them. See [Undo](#undo) for the restore contract and its known limitation;
[Panels](#panels) and [Dock pins](#dock-pins) explain why these operations
replace state.

The capture boundary follows the first command that can change an artifact.
The subcommand that first touches `~/.config/gtk-3.0/gtk.css` or the Tilix
dconf tree takes its capture-once snapshot; capture is not deferred until a
separate `backup` command. This matters because `./xfce.sh gtk` and
`./xfce.sh tilix` are file and dconf operations that work without a live Xfce
session. Making them call `backup` would force them through xfconf reads and
add a session requirement they do not otherwise have.

`install_gtkcss` also leaves a timestamped `gtk.css.backup.<ts>` beside the
deployed file when it replaces an existing one. That copy is an extra manual
escape hatch; `revert` does not consume it. The capture in the state directory
is the baseline that `revert` uses.

### First run on a clean machine

Choose a dock engine, run `all` from the live Xfce session, then inspect the
result:

```sh
XFCE_DOCK=docklike ./xfce.sh all
./xfce.sh status
```

Replace `docklike` with `plank` or `tasklist` when that is the intended
engine. `all` takes the capture-once snapshots before changing session state.
`XFCE_DOCK` is required for the dock and single-panel layout to be built. If
it is omitted, `all` installs the theming and tells the user to choose a dock;
it does not silently pick one.

## Why this is not a copy of the VM's provisioning scripts

The VM applies the same look, but under conditions that do not hold on a real
desktop, and the differences are load-bearing.

**The VM replaces state; this merges into it.** Provisioning runs as root
against a user who has never logged in, with no D-Bus session, so it writes
xfconf channel XML files directly and builds the Tilix database with
`dconf compile`. Both replace wholesale -- `dconf compile` is a full GVDB
rebuild, not a merge, which is why the VM guards it behind a first-provision
sentinel. On a machine with settings you care about, that is data loss. This
installer uses `xfconf-query` and `dconf load` instead. Both merge, both go
through the running session bus, and both apply immediately: no logout, and
nothing you did not name is touched.

**The VM installs system-wide; this stays in `$HOME` where it can.** The GTK
theme goes to `~/.themes`, icons to `~/.local/share/icons`, the font to
`~/.local/share/fonts`, the screenshot wrapper to `~/.local/bin`. Uninstalling
is `rm -rf`, and none of it needs sudo. Only distro packages and the dock
plugin do.

## Non-obvious choices

**The icon overlay must not be called `Papirus-Dark`.** GTK loads a theme's
`index.theme` from the *first* search-path directory that has one, and
`~/.local/share/icons` precedes `/usr/share/icons`. A user-scoped file named
`Papirus-Dark` therefore wins that lookup, so its short `Directories=` list
replaces the system theme's full one, and `Inherits=Papirus-Dark` becomes a
self-reference that GTK drops as an already-loaded cycle. The result is every
mimetype, places and status icon collapsing to hicolor. The overlay is named
`Papirus-Dark-NightOwl` so Papirus-Dark loads normally as its parent, and
`/Net/IconThemeName` points at the derived theme only when it is present.

**The hicolor overlay is safe to shadow** because its `index.theme` is a
verbatim copy of the system file, so the full `Directories=` list survives. It
exists because Papirus-Dark inherits from `breeze-dark,hicolor` and *not* from
Papirus, leaving `utilities-terminal` -- which only Papirus ships --
unreachable. Tilix logs an icon warning for it on every close dialog.

**`profile-list` is unioned, not loaded.** `dconf load` merges per *key*, but
`profile-list` is one key holding an array, so loading it verbatim replaces the
whole list. Any other Tilix profile would stay under `/profiles/<uuid>/` while
disappearing from the UI, with no error anywhere. `install_tilix` therefore
strips `profile-list` and `default-profile` from the keyfile before loading and
computes the union afterwards.

**The GTK theme is pinned to one commit.** Upstream
[Tokyonight-GTK-Theme][tn] publishes no tags, and its installer compiles from
SASS, so an unpinned clone would silently restyle the desktop on any future
re-run. The installer asserts `git rev-parse HEAD` against the pin and refuses
to build on a mismatch. It also checks that `gtk-3.0/gtk.css` actually exists
afterwards, because upstream's installer prints an error and still exits `0`
when `sassc` is missing.

[tn]: https://github.com/Fausto-Korpsvart/Tokyonight-GTK-Theme

**No literal Night Owl GTK theme exists.** Night Owl is a code-editor theme
that nobody ported to window chrome. Tokyo Night is the closest maintained
deep-navy GTK3 + xfwm4 theme, so the chrome is Tokyo Night while the terminal
palette in `tilix/night-owl.dconf` is literal Night Owl.

**`vblank_mode=off` is deliberately absent.** The VM sets it because xfwm4
rejects `llvmpipe`/`SVGA3D`/`virgl` as GL renderers for vblank and VirtualBox's
VMSVGA exposes exactly those. On real hardware it would disable vblank
synchronisation for no reason.

**The Tilix profile UUID is fixed** at `2b7c4080-0ddd-46c5-8f23-563fd3ba789d`.
Tilix keys profiles by UUID, so `default-profile`, `profile-list` and the
`[profiles/...]` block have to agree; a random UUID would leave the palette
loaded but unused.

**Tilix shell integration is appended to `~/.bashrc`, not left to
`/etc/profile.d`.** Debian and Ubuntu ship VTE's hooks in `/etc/profile.d`,
which only *login* shells read, while Tilix spawns non-login interactive
shells. Without the explicit guard Tilix shows "Configuration Issue Detected".

**No early-exiting consumer on the receiving end of a pipeline.** The script
runs under `set -o pipefail`, so a pipeline reports the failure of *any*
stage. `grep -q` exits the instant it matches, the producer upstream then
takes `SIGPIPE`, and the pipeline's status becomes 141 -- a hard failure --
even though the pattern was found. `if fc-list : family | grep -q 'X'` is
therefore always false, and the guard it protects can never fire. `awk`
with `exit`, `head`, and `sed -n '...q'` all behave the same way.

Every such consumer in this script was replaced with one that drains its
input: `grep PATTERN >/dev/null` rather than `grep -q PATTERN`, and
`awk '/X/ && !v {v=$1} END{print v}'` rather than `awk '/X/{print $1; exit}'`.
The redirect gives the same silence without the early close. This is easy to
reintroduce, because the broken form is the idiomatic one and it works fine
whenever the producer's output happens to fit the 64 KB pipe buffer -- which
is exactly why the `dpkg-query` and `xfconf-query` guards looked correct while
the `fc-list` one, whose output is far larger, failed every single time. An
`awk ... exit` reading from a here-string or a file argument is not a
pipeline and is fine.

**The Nerd Font is pinned and its digest checked**, for the same reason as the
GTK theme commit: `tilix/night-owl.dconf` names the family directly, so
tracking `releases/latest` would restyle every terminal on the box the day
upstream cuts a release. The installer fetches a fixed tag and compares
`sha256sum` against the digest published in that release's own `SHA-256.txt`
before unpacking, refusing to install on a mismatch -- an unverified tarball
is remote content being written into a font directory.

**Build-only packages are marked auto after the dock compiles.** docklike is
not in the Ubuntu 24.04 archive, so building it is the only route, and the
toolchain it pulls in is roughly 140 MB that nothing needs afterwards. Only
packages the script itself installed are marked, and `build-essential` is
deliberately exempt: quietly making the compiler removable on a development
box is a worse outcome than the disk it occupies. Nothing is deleted at
install time -- the mark only lets a later `apt autoremove` reclaim them, and
`apt-mark manual` undoes it.

## Dock

Xfce 4.18 on Ubuntu 24.04 has no `xfce4-docklike-plugin` in the archive:
releases after 0.4.2 swapped libwnck for `libxfce4windowing` and require
`>= 4.19.4`, which ships with Xfce 4.20. Ubuntu carries the package from 25.10
onward (26.04 has 0.5.1-2 in universe).

`xfce.sh dock docklike` therefore prefers the archive package whenever the
release has one, and only falls back to building 0.4.2 from a pinned commit.
That build is wrapped as a `.deb` with `dpkg-deb` rather than
`sudo make install`, so dpkg owns the files, `apt remove` is a clean uninstall,
and it is visible in `dpkg -l` -- instead of an untracked stray `.so` that
would silently stop loading after a panel ABI bump.

`plank` and `tasklist` are the alternatives: `plank` is a separate dock process
from the archive, `tasklist` reconfigures the panel's built-in window list into
a grouped icon-only strip with no install at all and no pinning.

## Dock pins

Docklike 0.4.2 does not store its pins in xfconf. At commit
[`9debe3d94308`][docklike-commit], they live in a GKeyFile named
`~/.config/xfce4/panel/docklike-<plugin-id>.rc`, under group `[user]` and key
`pinned`. The value is a GLib string list: entries are separated by semicolons
and the final entry also has a trailing semicolon
([`src/Settings.cpp:209-232`][docklike-settings]).

Each entry is a desktop-entry id without the `.desktop` suffix
([`src/AppInfos.cpp:80-96`][docklike-appinfos]). Absolute paths to desktop
files are accepted and normalised to the bare id, which is why the Vagrant
repository's `assets/docklike.rc` can use full paths.

The default pins are `google-chrome`, `com.gexperts.Tilix` and `thunar`;
`XFCE_DOCK_PINS` overrides the list. The Vagrant asset pins a fourth entry,
VS Code, which is not installed here.

The application launcher is deliberately **not** among them. `Super+Space`
reaches it faster than a dock tile does, so a pinned copy would only take up
space next to the three apps that genuinely benefit from one-click access.
The desktop entry is still installed, so the launcher stays searchable; add
`night-owl-launcher` to `XFCE_DOCK_PINS` to put the tile back.

**The declared list is the whole list.** `install_pins` rewrites the entire
`pinned=` value from `default_dock_pins`/`XFCE_DOCK_PINS`, so anything pinned
by hand through docklike's own right-click menu is gone the next time the
installer runs. This is the same wholesale-replay tradeoff the panel section
describes, and it is deliberate here: merging instead would make removing a
default pin impossible, since the pin being dropped would simply be read back
out of the live file and re-added. `XFCE_DOCK_PINS`, or an edit to
`default_dock_pins`, is the durable way to change the set.

Docklike reads the file only when the plugin is constructed, so changing pins
requires a panel restart. It also writes the file after any pin action, which
means seeding it while the panel is live can be clobbered. `install_pins`
therefore writes the file and restarts the panel itself. It preserves the
roughly twenty other docklike settings in the same file and rewrites only the
`pinned=` line
([`src/Settings.cpp:41-59`][docklike-settings-load],
[`src/Dock.cpp:57-88`][docklike-dock]).

This is also why the tail of `all` runs `dock`, then `panels`, then `rofi`,
then `pins`. `install_dock` only installs the package; the panel plugin entry
is created by `install_panels`. Seeding pins any earlier finds no docklike
plugin to name the file after, and the first run on a fresh machine silently
produces a dock with no pins at all -- a second run would be needed to fix it.
Ordering `rofi` before `pins` also deploys the desktop entry before
`install_pins` resolves it. Keeping pins last guarantees the file is named for
the plugin id `install_panels` actually settled on, rather than one it might
supersede.

[docklike-commit]: https://gitlab.xfce.org/panel-plugins/xfce4-docklike-plugin/-/commit/9debe3d94308
[docklike-settings]: https://gitlab.xfce.org/panel-plugins/xfce4-docklike-plugin/-/blob/9debe3d94308/src/Settings.cpp#L209-232
[docklike-appinfos]: https://gitlab.xfce.org/panel-plugins/xfce4-docklike-plugin/-/blob/9debe3d94308/src/AppInfos.cpp#L80-96
[docklike-settings-load]: https://gitlab.xfce.org/panel-plugins/xfce4-docklike-plugin/-/blob/9debe3d94308/src/Settings.cpp#L41-59
[docklike-dock]: https://gitlab.xfce.org/panel-plugins/xfce4-docklike-plugin/-/blob/9debe3d94308/src/Dock.cpp#L57-88

## Application launcher

The launcher replaces `xfce4-appfinder`, whose interface the box's owner found
visually poor. The goal is the fullscreen, searchable application grid used by
GNOME and Ubuntu rather than another conventional application list.

`xfdashboard` is the closer structural match. It is an actual GNOME Activities
clone, with live window thumbnails, an application grid, favourites and a
workspace selector. It is also actively maintained: 1.1.0 was released on
2025-08-21, with upstream commits through 2026-07-25. It is not abandoned, and
any impression otherwise is wrong.

It was rejected for three concrete reasons. Ubuntu 24.04 ships 1.0.0 from
2022. On a dual-head desktop, only the theme's `primary` interface is created
automatically; non-primary monitors render empty unless a `secondary`
interface is written by hand. Finally, xfdashboard is built on Clutter/COGL,
which upstream itself described as effectively dead in issue #36 on
2025-08-22. rofi also has the simpler theme surface: one CSS-like `.rasi` file
instead of xfdashboard's bespoke INI, CSS and XML combination.

Noble ships rofi 1.7.5. Upstream 2.0.0, released on 2025-09-01, merged the
Wayland port and moved the build to meson. The distro version is one major
behind, but it is fully adequate for this X11 desktop and is the version the
distribution supports.

The theme creates the grid with these properties:

```rasi
window {
    fullscreen: true;
}

listview {
    layout: horizontal;
    columns: 6;
    fixed-columns: true;
}

element {
    orientation: vertical;
}

element-icon {
    size: 64px;
}
```

The surprising part is `layout: horizontal`: in rofi that is what produces a
multi-column grid, while `vertical` produces the ordinary single-column list.
The vertical element orientation and 64-pixel icon turn each cell into an
application tile.

The deployed theme is
`~/.config/rofi/themes/night-owl.rasi`. rofi resolves the bare name
`night-owl` by appending `.rasi` within its theme search path. When
`~/.config/rofi/config.rasi` is absent, the installer seeds it with only
`@theme "night-owl"`; an existing configuration is recorded and left intact.
A desktop entry is installed at
`~/.local/share/applications/night-owl-launcher.desktop` so the launcher is
searchable. It is not a dock pin by default; see the dock pins section for why
adding it to `XFCE_DOCK_PINS` is the way to change that.

After deploying the theme, the installer runs
`rofi -no-config -theme ... -dump-theme`. A malformed `.rasi` does not fail
visibly: rofi falls back to its default theme, so installation could appear to
succeed while the theme did nothing. This check proves only that the file
parses, which is a weaker claim than it looks: a theme can parse cleanly and
still lay out badly. The check is a guard against silent fallback, not a
judgement of the result. The fullscreen grid has been seen on a live session
and kept. The compact run prompt has only been parse-checked -- nobody has
confirmed how `night-owl-run.rasi` actually lays out, so treat its spacing and
width as a first draft.

rofi normally follows the desktop environment's icon theme. This theme sets
`icon-theme: "Papirus-Dark-NightOwl"` explicitly so launcher icons match the
rest of the desktop.

The `drun` mode honours `NoDisplay`, `OnlyShowIn`/`NotShowIn` and `TryExec`. It
scans user applications and every system data directory, so Snap and Flatpak
applications appear when their export directories are present in
`XDG_DATA_DIRS`.

### Keybindings

`Super+Space` is the new primary binding. Three existing shortcuts are
repointed as well, because leaving them attached to `xfce4-appfinder` would
keep a path open to exactly the interface being replaced.

| Binding | Previous command |
| --- | --- |
| `Super+Space` (`<Super>space`) | Unbound |
| `Alt+F2` (`<Alt>F2`) | `xfce4-appfinder --collapsed` |
| `Alt+F3` (`<Alt>F3`) | `xfce4-appfinder` |
| `Super+R` (`<Super>r`) | `xfce4-appfinder -c` |

The installer records all four original properties with `record_prop`, using
the `rofi` key in `rofi-keys.bak`, and revert restores them. A bare `Super_L`
binding was considered and rejected: on X11 it interferes with `Super+key`
combinations and needs an extra `xcape` or `ksuperkey` daemon to translate a
tap. `Super+Space` needs neither.

## Panels

The installer builds one bottom panel matching the Vagrant box. Plugin order
is part of the layout:

| Position | Plugin type | Sub-properties set |
| --- | --- | --- |
| 1 | `whiskermenu` | None |
| 2 | `separator` | `expand` (`bool`) = `true`; `style` (`uint`) = `0` |
| 3 | `docklike` | None |
| 4 | `separator` | `expand` (`bool`) = `true`; `style` (`uint`) = `0` |
| 5 | `systray` | `square-icons` (`bool`) = `true` |
| 6 | `pulseaudio` | None |
| 7 | `clock` | See clock settings below. |
| 8 | `separator` | `expand` (`bool`) = `false`; `style` (`uint`) = `0` |

The trailing transparent separator alone keeps the clock away from the screen
edge. A CSS `padding-right` rule was tried and removed: the panel ignores box
properties, so it never contributed any spacing.

The clock receives these values:

| Property | Type | Value |
| --- | --- | --- |
| `mode` | `uint` | `2` |
| `digital-layout` | `uint` | `1` |
| `digital-time-format` | `string` | `%^a  %H:%M` |
| `digital-date-format` | `string` | `%d %B %Y` |
| `digital-time-font` | `string` | `Noto Sans Bold 10` |
| `digital-date-font` | `string` | `Noto Sans 8` |

The first font sizes tried, `Noto Sans Bold 12` and `Noto Sans 9`, were too
large in practice. Size belongs in these xfconf Pango strings because the
clock applies them as label attributes, which override CSS `font-size`.
Colour remains in CSS.

The panel itself receives these values:

| Property | Type | Value |
| --- | --- | --- |
| `size` | `uint` | `48` |
| `length` | `uint` | `100` |
| `length-adjust` | `bool` | `false` |
| `icon-size` | `uint` | `22` |
| `position-locked` | `bool` | `true` |
| `autohide-behavior` | `uint` | `2` |
| `span-monitors` | `bool` | `false` |
| `output-name` | `string` | `Primary` |

`position` is deliberately not written. The surviving panel already has a
bottom snap, and rewriting that coordinate on a multi-monitor desktop risks
relocating it. `output-name` is explicitly set to `Primary`, rather than
inherited, so the panel has a defined home when an external display is
connected or removed. An absent value defaults to `Automatic`, which is not
the same guarantee.

The `2` is deliberate: `autohide-behavior` is an enum where `0` means never
hide, `1` means hide intelligently and `2` means always hide. Intelligent
hiding was considered, but the requested default is an always-hidden panel.
The property must still be written as `uint`, not `int`; the warning below
applies even though the chosen enum member changed.

The panel background comes from `gtk.css`, not the panel's
`background-rgba` xfconf property. It is the fully opaque
`rgb(1, 22, 39)`. An alpha of `0.94` was tried and rejected because the
wallpaper bled through the whole bar. A `border-top` at 14 percent alpha was
also rejected: it read as a gap along the top edge where the desktop showed
through, not as a border.

The xfconf property is an array of four doubles, which cannot be represented
by the `panel|property|type|value` rows in `panel-props.bak`. Attempting to
replay it through that format would either fail or reconstruct garbage. CSS
keeps the panel, clock and calendar paint styling in one file, and that file
is already covered by the `gtk.css` snapshot. xfce4-panel installs its
generated background CSS at `GTK_STYLE_PROVIDER_PRIORITY_APPLICATION` (600),
while `~/.config/gtk-3.0/gtk.css` loads at
`GTK_STYLE_PROVIDER_PRIORITY_USER` (800), so the user rule wins.

Which panel survives is decided in this order: `XFCE_DOCK_PANEL`, then the
choice persisted in `dock-panel`, then the panel already carrying the dock
engine's own plugin, then a geometry tiebreak, then the last panel. Two of
those steps are worth spelling out.

The engine probe matches the configured engine's plugin type only. Matching
`tasklist` as well looks reasonable and is wrong: with docklike as the engine
that selects the panel holding the window list, which is the thing being
replaced, and on a two-panel desktop it merges everything onto the top bar and
still reports success.

The geometry tiebreak reads `position`, which encodes an `XfceScreenPosition`
as `p=<n>;x=..;y=..`. That numbering is not stable across releases -- Xfce
4.18.4 gives a top panel `p=6`, while the Vagrant box's bottom panel is `p=12`
-- so the accepted set spans both readings and is only ever a tiebreak.
Because none of this is authoritative, `verify_panel_edge` measures the
panel's actual mapped window after the restart and warns if it did not land on
the bottom half of the screen. Window geometry is the one check that does not
depend on the enum.

Other panels are recorded in `panels-removed.bak` before they are removed.
Their plugins are unlinked from the departing panels, never deleted, so their
`/plugins/plugin-N` entries and complete settings subtrees remain available
for revert.

The panel process is stopped for the entire rewrite and started afterwards.
This is not optional: unlinking a plugin id from a live panel is safe, but
removing a panel is not. xfce4-panel tears down every plugin still attached to
the departing panel, and a plugin's remove path resets its own
`/plugins/plugin-N` subtree. Moving systray, pulseaudio and clock away from
that panel while it is live would race xfconf property delivery and could wipe
the settings the move is meant to preserve.

xfce4-panel also saves its layout when it exits, so the installer waits until
the process is gone before writing; otherwise the exit save can overwrite the
new layout. `xfce4-panel -r` restarts only an already-running instance, so the
bring-back is a plain detached launch. An `ERR`/`EXIT` relaunch trap is armed
while the panel is stopped, preventing a mid-rewrite failure from leaving the
desktop without a panel.

Three related rules are load-bearing. The unlink behaviour and the `uint` type
were established by observation on a live session. The id-allocation rule is
a correctness argument rather than a diagnosed failure, retained because
violating it could destroy somebody else's plugin.

**Plugins are unlinked, never deleted.** An unreferenced plugin entry and its
whole settings subtree survive a panel restart, so revert only has to put the
id back into an array -- there is no need to recreate the plugin or guess the
GValue type of each setting.

**New plugin ids are allocated from the whole id space.** Taking `max + 1` over
the ids *referenced by panels* is unsafe precisely because this script leaves
plugins unreferenced: an entry can sit above the referenced maximum, get
overwritten, and then be deleted outright by revert because it was recorded as
ours. `all_plugin_ids` reads every `/plugins/plugin-N` key, and allocation also
refuses any id whose entry already exists.

**`autohide-behavior` is `uint`, not `int`.** xfce4-panel reads it with
`xfconf_channel_get_uint`. Writing it as `int` replaces the property's GValue
type, the typed read then falls back to `0`, and the stored setting is ignored.
`size`, `length`, `icon-size`, `mode` and `style` are also `uint`;
`plugin-ids` values are `int`.

A plugin type string must match the basename of a `.desktop` file in
`/usr/share/xfce4/panel/plugins/`. The installer asserts that match for the
dock because xfce4-panel silently drops an entry whose type it cannot resolve.

The types and geometry below were checked against Xfce 4.18.4 source and live
property or window measurements. The dock geometry, CSS behaviour, clock
fonts, ibus result and calendar result called out below were also reviewed on
the live desktop; source-derived limits are identified as such.

### Dock centring

The two expanding separators do not centre the dock on the screen. They centre
it in the space left over between the fixed-width widgets on either side. On
the measured 1920-pixel panel, whiskermenu occupies 48 pixels on the left and
the indicator group occupies 263 pixels on the right. The 212-pixel dock
starts at x=746, putting its centre at x=852 rather than the screen centre at
960.

The offset is

```text
(rightFixed - leftFixed) / 2
```

and is independent of screen resolution because only widget widths appear in
it. With the measured widths, both resolutions have the same expected offset:

| Panel width | Centre of leftover space | Screen centre | Offset |
| ---: | ---: | ---: | ---: |
| 1920 | `(48 + (1920 - 263)) / 2 = 852.5` | `960` | `107.5` |
| 2560 | `(48 + (2560 - 263)) / 2 = 1172.5` | `1280` | `107.5` |

Changing the resolution therefore does not remove or amplify the offset. Its
size changes when the systray icon count or another fixed-width widget
changes.

The offset is deliberately not fixed. CSS cannot move panel contents: the
panel allocates its children from xfconf and ignores CSS box properties.
Measured on the live panel, `margin-left` on the dock, `padding-left` on the
panel and `min-height` on the panel each changed nothing.
`background-color` on `.xfce4-panel`, by contrast, measurably worked. Only
paint properties reach the panel.

The obvious dock-specific CSS approach is architecturally dead, not merely a
selector mistake. `docklike.desktop` sets `X-XFCE-Internal=false`, so docklike
runs in a separate `wrapper-2.0` process. The widget named `docklike-<id>`
lives inside a `GtkPlug` in that wrapper; the panel process holds only the
corresponding `GtkSocket`. A margin inside the plug cannot push the panel's
separators because the socket determines the plug's size.

Two structural alternatives were measured or considered. Reordering the
plugins so the systray sits left of the dock produced a dock centre of x=971
against the true centre at 960 -- 11 pixels off instead of roughly 103 -- but
put the indicators at the bottom left and departed from the Vagrant layout. A
separate floating centred panel would be exact, but would recreate the
two-panel arrangement that this installer deliberately merged away. The
owner chose to accept the roughly 103-pixel offset, so the Vagrant plugin
order stands. The coordinate snapshot above puts the centre at x=852, or 108
pixels left; the 103-pixel figure is the measured decision-point description,
not a value derived from the rounded table inputs.

### Hiding the ibus indicator

The `EN` indicator is not an Xfce panel plugin. It is `ibus-daemon --xim`
registering a legacy XEmbed tray icon named exactly `ibus panel`, including
the space. XEmbed is why its menu opened at screen coordinates 0,0 rather than
above the icon.

The first attempt used the systray plugin's `hidden-legacy-items` property.
That did not hide the item; it only collapsed it behind a `‹` expander arrow.
The icon remained reachable, still opened its menu in the wrong place, and
the arrow itself became a new annoyance.

The working fix, verified live, is:

```sh
gsettings set org.freedesktop.ibus.panel show-icon-on-systray false
```

The icon and expander both disappear, and `ibus-ui-gtk3` stops running. ibus
stays installed and continues to provide XIM. The similarly named
`org.freedesktop.ibus.panel show` key was already `0` (`Do not show`) while
the icon still appeared, so it is not the control despite its name.

The previous `show-icon-on-systray` value is recorded once in
`$state_dir/ibus-tray.bak` and restored by revert. This is the only gsettings
key the installer touches outside Tilix's dconf path.

`xfce4-xkb-plugin` was considered and rejected. This box has exactly one
layout: `XKBLAYOUT="us"`, no variant or options, and the ibus
`preload-engines` value is `['xkb:us::eng']`. A second switcher would still
show `EN` but have nothing to switch to, while also racing ibus for XKB state.
Revisit that decision if a second layout is added.

### Calendar limits in GTK3

The reference calendar cannot be reproduced fully with GTK 3.24 CSS.
`GtkCalendar` exposes exactly one CSS node, `calendar`
(`gtk/gtkcalendar.c:681-683`). Its header, arrows, weekday row and day cells
are not child nodes. They are painted in a cairo loop while transient classes
are applied to that one style context: `.header`
(`gtk/gtkcalendar.c:2217-2223`), `.button` for the arrows, `.highlight` for
weekday and week-number regions (`gtk/gtkcalendar.c:2333-2340`), and `.view`
for the whole widget (`gtk/gtkcalendar.c:2791-2804`). The selectors must
therefore be forms such as `calendar.header`, not `calendar header`.

Per-day rounded pills like those in the reference are impossible. The days
are painted in a 6 by 7 cairo loop and have no CSS nodes. Only the selected
day gets `gtk_render_background` over its rectangle
(`gtk/gtkcalendar.c:2571-2594`), so `calendar:selected` can colour that one
day. Marked days set `:active`, and out-of-month days set `:indeterminate`,
but those states affect only text colour and font: there is no background
render branch for them (`gtk/gtkcalendar.c:2628-2660`). There is no separate
state for today.

Blur is also impossible because xfwm4 has no blur backend. Even translucency
is not guaranteed: the clock popup is a plain undecorated `GtkWindow` and
never requests an RGBA visual (`plugins/clock/clock.c:1413-1437`).

Finally, the popup has no widget name, style class or unique ancestor, so CSS
cannot scope rules to that calendar alone. The calendar rules are global and
restyle every GTK3 calendar on the box. That is an accepted tradeoff, not an
oversight: the desktop is uniformly dark already, so a consistent calendar is
defensible.

The result was reviewed on a live session and kept.

## Xfce version requirements

Nothing here needs Xfce newer than 4.18. Every setting is an xfconf channel
value or a dconf key, and both interfaces are stable from 4.16 to 4.20. The
sole exception is docklike, above.

That matters on a machine whose job is hosting Chrome Remote Desktop. CRD's
Linux host never mirrors the physical session -- it always creates its own
virtual one, which is why `xvfb` and `xserver-xorg-video-dummy` are hard
dependencies of the `chrome-remote-desktop` package -- and inside it runs
whatever `~/.chrome-remote-desktop-session` names. The CRD desktop is therefore
chosen independently of the local login session, and its Xfce version is
irrelevant to CRD. Upstream guidance is in fact to use a *different*,
lightweight desktop for CRD than for local login, because two graphical
sessions for one user conflict ([GNOME/gdm#580][gdm]).

[gdm]: https://gitlab.gnome.org/GNOME/gdm/-/issues/580

## Undo

`xfce.sh` snapshots the previous value of every setting it manages, plus the
Tilix database and `gtk.css`, into `~/.local/state/xfce-nightowl` before the
first change. `./xfce.sh revert` restores them; `./xfce.sh status` shows
current versus wanted for each setting.

Each artifact is captured once, so a second run cannot record values that were
just applied over the originals. The guards are per artifact rather than one
check on the directory, so a snapshot taken before this script learned to
manage something new still gains it -- otherwise revert would silently skip
that part and still report success.

Capture-once has one sharp edge, and an older snapshot on this very repo hit
it. Before the single-panel rewrite, autohide was the only panel property the
script wrote, and it was recorded on its own in `panel-autohide.bak`. The
rewrite folded autohide into `panel-props.bak` -- but on a machine the older
version had already run against, the `panel-props` row was captured *after*
that earlier write, so it recorded the installer's own value as if it were the
user's. Replaying it would have restored `autohide-behavior=0` over a panel
that was originally set to hide intelligently, with nothing left to recover
the real value from.

`migrate_legacy_state` resolves this before anything is replayed: the legacy
file predates the bad capture, so it wins, and only then is it removed. It
runs from both `backup` and `restore_panels`, because `revert` does not go
through `backup`. A legacy row can also read `UNSET` -- the normal case for a
top panel, which has no `autohide-behavior` property at all -- and that is
carried through as a real unset rather than becoming the literal string
`UNSET` in a typed write.

**Known limitation.** Panel restore still replays each panel's whole
`plugin-ids` array from the snapshot. A plugin added afterwards disappears on
revert, while existing plugins that were moved or reordered return to their
snapshot arrangement. Recorded arrays are filtered to plugin ids that still
exist before they are replayed, so a plugin deleted by hand after the snapshot
is not resurrected as a dangling reference. That is a real case rather than a
hypothetical safeguard: it happened on the author's box.

Revert also recreates panels named in `panels-removed.bak` and restores
`panel-props.bak` and `plugin-props.bak` key by key. It uses
`docklike-rc.state` to restore the docklike file from `docklike-rc.bak` when
the recorded state was `present`, or deletes the file when it was `absent`.
It deletes only plugin ids listed in `panels-added.bak`; user-owned plugin
entries are never deletion candidates. Only the `plugin-ids` arrays are
restored wholesale; panel and plugin properties are restored key by key.

`restore_ibus_hide` restores the value recorded in `ibus-tray.bak`; no systray
plugin property is changed.

Re-run `./xfce.sh backup` against a clean desktop (or delete
`~/.local/state/xfce-nightowl` and re-snapshot) after deliberately changing
your panel, so the baseline matches what you actually want back.

`restore_rofi` first replays `rofi-keys.bak`. It then walks `rofi.state`,
deleting each file recorded as `created` and restoring each file recorded as
`existed` from its copy under `$state_dir`. Like the rest of revert, it leaves
the distro's rofi package installed.

Revert deliberately leaves distro packages, the Nerd Font and any dock
installed -- those are additive, and removing them is an apt decision rather
than a settings one.
