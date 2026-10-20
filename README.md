# Dotfiles

A modular Bash installer and a shared shell profile for development machines.

`install.sh` detects the operating system and the CPU architecture. It then
installs the tools of a declarative package registry through one adapter per
operating system. A second run changes nothing when every tool is present. The
`--dry-run` option prints every command and changes nothing.

The repository follows an allowlist model: only reviewed declarative
configuration and scripts are tracked. Credentials, authentication databases,
environment files, session history, caches, logs, and machine-specific state
remain local.

## Installation

Run the installer of the latest release. You do not need a clone:

```bash
curl -fsSL https://github.com/DocksDocks/dotfiles/releases/latest/download/install.sh | bash
```

Do a dry-run first. It prints every command and changes nothing. The words
after `--` go to the installer, so every command of [Usage](#usage) works:

```bash
curl -fsSL https://github.com/DocksDocks/dotfiles/releases/latest/download/install.sh | bash -s -- --dry-run
curl -fsSL https://github.com/DocksDocks/dotfiles/releases/latest/download/install.sh | bash -s -- --dry-run packages gh docker
```

Without curl, use wget:

```bash
wget -qO- https://github.com/DocksDocks/dotfiles/releases/latest/download/install.sh | bash
```

To read the script before it runs, download it first:

```bash
mkdir dotfiles-release && cd dotfiles-release
curl -fsSLO https://github.com/DocksDocks/dotfiles/releases/latest/download/install.sh
less install.sh
bash install.sh --dry-run
bash install.sh
```

The `install.sh` of a release is a small bootstrap script
([`release/bootstrap.sh`](release/bootstrap.sh)). It contains the tag of its
release and the SHA-256 of the release archive `dotfiles-<tag>.tar.gz`. It:

1. downloads that archive over HTTPS into `~/.cache/dotfiles-install/release/`;
2. stops with an integrity error when the SHA-256 of the download is
   different, before it unpacks anything;
3. unpacks the archive into `~/.cache/dotfiles-install/release/dotfiles-<tag>/`;
4. runs the `install.sh` of the archive with your arguments. In `curl | bash`,
   the prompts read the terminal, not the pipe.

Thus the bootstrap of release `vX.Y.Z` always installs exactly `vX.Y.Z`, never
a branch. The unpacked release stays in `~/.cache/dotfiles-install/release/`;
the installer never deletes it. Nothing uses it after the run, because the
shell profile is a copy (`~/.docks_profile`). A release is not a Git clone, so
the summary shows the Git hooks as not applicable.

### Verify a release

Each release has three assets: `install.sh`, `dotfiles-<tag>.tar.gz`, and
`SHA256SUMS`, which has the SHA-256 of the two other files. Each asset has a
GitHub artifact attestation. It proves that the release workflow of this
repository built the file. To verify the assets before you run them:

```bash
curl -fsSLO https://github.com/DocksDocks/dotfiles/releases/latest/download/SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS
gh attestation verify install.sh --repo DocksDocks/dotfiles
```

On macOS, use `shasum -a 256 --check --ignore-missing SHA256SUMS`. Download all
files from the same release: when a new release comes out between two
downloads, the `latest` URLs give files of different releases. To prevent
this, use the URL of a tag:
`https://github.com/DocksDocks/dotfiles/releases/download/vX.Y.Z/<file>`.

The SHA-256 check of `SHA256SUMS` finds a damaged download. The attestation
check also finds a file that the release workflow did not make.

## Contents

| Path | Purpose |
| --- | --- |
| [`install.sh`](install.sh) | Entry point: argument parsing, guards, and command dispatch |
| [`lib/`](lib/) | Core API, platform detection, package registry, result summary, and shell wiring |
| [`lib/os/`](lib/os/) | One adapter per operating system (`ubuntu.sh`, `macos.sh`) and the rootless Docker tool for Ubuntu |
| [`lib/tools/`](lib/tools/) | Cross-platform tool installers (uv, Python, Node.js, Bun, pnpm, omp, docks-kit, Composer) |
| [`shell/`](shell/) | Shared interactive shell profile, with Linux and macOS parts |
| [`.githooks/`](.githooks/) | Version-controlled safeguards for staged commits |
| [`release/bootstrap.sh`](release/bootstrap.sh) | Template of the one-line installer that each release publishes as `install.sh` |
| [`release.sh`](release.sh) | Starts the manual release workflow for the next version |
| [`.github/workflows/release.yml`](.github/workflows/release.yml) | Manual release workflow: tests, builds, attests, and publishes the release assets |
| [`.github/dependabot.yml`](.github/dependabot.yml) | Weekly updates of the pinned GitHub Actions |
| [`xfce4/`](xfce4/) | Night Owl Xfce desktop assets, rationale, and undo contract |
| [`xfce.sh`](xfce.sh) | Separate Xfce desktop tool |

## Supported platforms

| Platform | Architectures | Package manager |
| --- | --- | --- |
| Ubuntu 26.04 or later | amd64, arm64 | apt, vendor apt repositories, vendor `.deb` files |
| macOS | arm64 (Apple Silicon), Intel | Homebrew formulae and casks |

The installer stops with an error on other Linux distributions, on Ubuntu
releases before 26.04, and on other architectures.

Intel Macs: the official Homebrew installer no longer installs on Intel
processors. When a `brew` command is already present, the installer uses it.
When no `brew` is present, the installer reports every Homebrew item as
unsupported and prints its download link. The tools that use their own vendor
installer (uv, Python, Node.js, Bun, pnpm, omp, docks-kit) do not need
Homebrew.

Apple Silicon in a Rosetta 2 terminal: the installer restarts itself as native
arm64 code, because Homebrew refuses to run in `/opt/homebrew` under Rosetta.

`install.sh`, the `lib/` files, the shell profile, the release bootstrap, and
the pre-commit hook use only Bash 3.2 syntax, so the Bash that macOS ships is
sufficient. `xfce.sh` is the exception: it requires Bash 4 and a running Xfce
desktop.

## Usage

The [Installation](#installation) one-liner runs the installer of a release.
For development, and to use the Git hooks, clone the repository. Run the
installer with `--dry-run` first, and read the commands that it prints:

```bash
git clone https://github.com/DocksDocks/dotfiles.git
cd dotfiles
./install.sh --dry-run
```

When the plan is correct, run the same command without `--dry-run`:

```bash
./install.sh
```

Do not run the installer as root. It asks for the sudo password once, when a
step needs root.

```text
./install.sh [--dry-run|-n] [all | packages [id...] | shell | hooks | list]
./install.sh --help
```

| Command | Effect |
| --- | --- |
| `all` (default) | Enables the Git hooks (not applicable outside a clone), prepares the operating system, installs all packages, wires the shell profile, and prints the summary |
| `packages [id...]` | Prepares the operating system and installs all packages, or only the given ids in registry order, then prints the summary |
| `shell` | Wires the shell profile into the rc files and prints the summary |
| `hooks` | Sets `core.hooksPath` of this clone to `.githooks`; fails outside a clone |
| `list` | Prints the registry for this platform and changes nothing |

Examples:

```bash
./install.sh --dry-run packages gh docker
./install.sh list
./install.sh shell
```

An unknown id stops the run before any change.

Operating system preparation: on Ubuntu, the installer installs
`ca-certificates`, `curl`, and `unzip`. On macOS, it installs Homebrew when no
`brew` is present (Apple Silicon only).

Test seam: the environment variables `DOTFILES_OS` (`ubuntu` or `macos`) and
`DOTFILES_ARCH` (`amd64` or `arm64`) replace the detected platform. The
installer accepts them only with `--dry-run` or with the `shell` command. With
any other command it stops with an error.

Rootless Docker needs a real login session of your user. Run the installer
from a desktop terminal or an SSH login, not through `sudo` or `su`. Without a
session (`XDG_RUNTIME_DIR` is not set), the `docker-rootless` item fails and
the summary shows its link.

## Packages

The registry in `lib/registry.sh` lists the packages in install order. A `-` in
a method column means that the package is not supported on that platform; the
summary then prints the download link. `n/a` means that the package does not
apply to that platform.

| Id | Ubuntu method | macOS method | Notes |
| --- | --- | --- | --- |
| `git` | apt `git` | formula `git` | |
| `gh` | apt repository `github-cli` | formula `gh` | GitHub CLI |
| `btop` | apt `btop` | formula `btop` | |
| `php` | apt `php-*` metapackages | formula `php` | PHP CLI and common extensions. On Ubuntu 26.04 the metapackages install `php8.5-*`; a later Ubuntu release moves them to its default PHP |
| `composer` | tool `composer` | formula `composer` | Ubuntu: official installer with signature check, into `~/.local/bin` |
| `uv` | tool `uv` | tool `uv` | Official installer, into `~/.local/bin` |
| `python` | tool `python` | tool `python` | Latest stable CPython through uv, as the default `python3` |
| `node` | tool `node` | tool `node` | Node.js LTS through nvm, in `~/.nvm` |
| `bun` | tool `bun` | tool `bun` | Official installer, into `~/.bun` |
| `pnpm` | tool `pnpm` | tool `pnpm` | Official installer, into `PNPM_HOME` |
| `pnpm-store` | tool `pnpm_store` | tool `pnpm_store` | Sets the pnpm global virtual store |
| `omp` | tool `omp` | tool `omp` | Official installer in binary mode (`--binary`), into `~/.local/bin`. Never through bun |
| `docks-kit` | tool `docks_kit` | tool `docks_kit` | `bun install -g docks-kit` |
| `docks-kit-sync` | tool `docks_kit_sync` | tool `docks_kit_sync` | Runs `docks-kit sync omp` on every run |
| `docker` | apt repository `docker` | cask `docker-desktop` | Ubuntu: Docker Engine for rootless mode. macOS: Docker Desktop |
| `docker-rootless` | tool `docker_rootless` | n/a | Ubuntu: rootless daemon for the current user. Needs a login session |
| `tailscale` | apt repository `tailscale` | cask `tailscale-app` | Ubuntu: the key stays at the vendor path `/usr/share/keyrings/tailscale-archive-keyring.gpg` |
| `chrome` | `.deb` `chrome` | cask `google-chrome` | |
| `discord` | `.deb` `discord` | cask `discord` | Ubuntu: amd64 only |
| `github-desktop` | n/a | cask `github` | macOS only. GitHub publishes no Linux build, so Ubuntu skips it without a link |
| `vlc` | apt `vlc` | cask `vlc` | |
| `rustdesk` | `.deb` `rustdesk` | cask `rustdesk` | |
| `parsec` | `.deb` `parsec` | cask `parsec` | Ubuntu: amd64 only |

Method summary:

- `apt`: packages from the Ubuntu archive.
- `apt_repo`: packages from a vendor apt repository. The installer adds the
  vendor key and source first.
- `deb`: a vendor `.deb` file, downloaded to the cache and installed with
  `apt-get`.
- `formula` and `cask`: Homebrew.
- `tool`: a `tool_<name>_present` and `tool_<name>_install` function pair in
  `lib/tools/` or `lib/os/`.

## Behaviour rules

- A present tool is skipped. The installer never upgrades a tool. On Ubuntu, a
  command that is already on `PATH` (for example from a snap) also counts as
  present for the packages that name one.
- The scripts never delete or move a file. They contain no `rm` and no `mv`.
- Before the installer changes an existing file, it copies the file to
  `<file>.backup.<timestamp>`. A system file under `/etc` gets the name
  `<file>.backup.<timestamp>.bak`, because apt ignores `.bak` files silently.
  One timestamp applies to the whole run.
- Downloads go to `~/.cache/dotfiles-install`. A new download overwrites the
  file of the same name. The installer never empties this directory.
- The installer downloads each vendor installer script to the cache and then
  runs it. It never pipes a download into a shell.
- Vendor installers do not edit shell rc files. The installer sets the vendor
  options that stop such edits. Only the shell profile block below changes rc
  files.
- One failure does not stop the run. The installer records the failure and
  continues with the next package.
- The exit status is 1 when any item failed, and 0 otherwise.
- The run ends with a summary. It lists the installed items (planned items in
  a dry-run), the unsupported items, and the failed items. Present items,
  not-applicable items, and routine syncs (`docks-kit sync omp`, which runs on
  every run) show only as one count line each; `./install.sh list` shows every
  package. Failed and unsupported items show their download link. When nothing
  is new, the summary says `Nothing new to install.`
- On a terminal, the output uses colors: green for installed, cyan for
  planned, dim for present, yellow for unsupported, and red for failed. Set
  `NO_COLOR=1` to turn the colors off.
- During the run, unchanged items share one `✓ Already present:` line that
  grows (and wraps before the terminal edge) until an item needs work. An item
  that needs work gets its own `==>` header and output. Not-applicable items
  show as `<id> (n/a)` on that line. The routine `docks-kit sync omp` joins the
  line as `docks-kit-sync (synced)` and prints its own output only when the
  output reports a warning, a skipped step, or an error. The full output of the
  last sync stays in `~/.cache/dotfiles-install/docks-kit-sync.log`.
- When Tern (Stencil Labs) is missing, the run ends with its download link,
  <https://build.stencil.so/tern>, and the waitlist, <https://stencil.so/tern>.
  Tern is invite only, so the installer cannot download it. Tern counts as
  present when `tern` is on `PATH`, when `~/.local/bin/tern` exists, when the
  desktop entry `so.stencil.tern` exists (Linux), or when `Tern.app` is in an
  Applications folder (macOS).

## Shell profile

The `shell` command (and `all`) does two things:

1. It writes `~/.docks_profile`. The installer builds this file from
   `shell/profile.sh` and puts `shell/profile.linux.sh` or
   `shell/profile.macos.sh` in place of the `# @os-profile@` line. The file is
   a copy, so it keeps working when the clone moves or is deleted.
2. It appends one block that sources `~/.docks_profile` to each rc file of the
   platform:

| Platform | rc files |
| --- | --- |
| Ubuntu | `~/.bashrc` |
| macOS | `~/.zshrc` and `~/.bash_profile` |

The block starts with `# >>> docks profile >>>` and ends with
`# <<< docks profile <<<`. When an rc file already contains the start marker,
the installer does not change that file.

The profile sets the environment of the installed tools, for example `PATH`,
`NVM_DIR`, `BUN_INSTALL`, and `PNPM_HOME`. After a change to `shell/` (for
example after a `git pull`), run `./install.sh shell`. It replaces a changed
`~/.docks_profile` without a backup, because the repository is the source of
the file. Do not edit `~/.docks_profile` by hand; edit the files in `shell/`
instead.

To unlink the profile, delete the block from the rc file. A backup of the rc
file from before the first wiring is next to it, as
`<rc file>.backup.<timestamp>`.

The profile loads `~/.config/secrets.env` when that file is present. Keep
tokens and other private values in that file. It is not part of this
repository and must never be tracked.

The installer warns when an rc file sets `NVM_DIR`, `PNPM_HOME`,
`BUN_INSTALL`, `DOCKER_HOST`, or `ANDROID_HOME` outside the block. These are
manual duplicates of the profile. Remove them by hand; the installer does not
edit them.

## After the installation

Open a new terminal, so that the shell profile is active. Then do these steps
by hand:

1. Connect Tailscale: `sudo tailscale up`.
2. Sign in to the desktop applications (Chrome, Discord, GitHub Desktop,
   RustDesk, Parsec, Tailscale, Docker Desktop on macOS).
3. Ubuntu: make sure that Docker runs in rootless mode.
   `docker info --format '{{.SecurityOptions}}'` must contain `name=rootless`.
4. Authenticate the GitHub CLI: `gh auth login`.

## omp configuration

This repository does not contain the omp configuration. docks-kit owns it. The
`docks-kit-sync` package runs `docks-kit sync omp` on every run. To update the
omp configuration without a full run, run:

```bash
docks-kit sync omp
```

## Xfce desktop

`xfce.sh` is a separate tool with its own lifecycle. It is deliberately not
reachable through `install.sh`. `install.sh` installs tools and wires the shell
profile on Ubuntu and macOS. The desktop script changes desktop settings, needs
sudo, and only makes sense on a machine that already runs Xfce.

```bash
./xfce.sh
```

It snapshots every setting it touches before the first change. `./xfce.sh
status` compares current against wanted, and `./xfce.sh revert` restores the
snapshot. See [`xfce4/README.md`](xfce4/README.md).

## Security model

Tracked files must never contain:

- API keys, access tokens, passwords, private keys, or OAuth material;
- application databases or credential stores;
- `.env` or `secrets.yml` files;
- session transcripts, prompts containing private data, logs, or caches;
- absolute machine-specific paths or host-specific configuration.

Authentication is performed separately on each machine after the installation.
Local authentication procedures and account details are intentionally outside
this repository.

The installer sets this clone's `core.hooksPath` to `.githooks`. Its pre-commit
hook scans the exact staged blobs and rejects:

- sensitive filenames and runtime directories;
- private-key blocks and common provider token formats;
- assigned passwords, secrets, keys, and authentication tokens;
- credentials embedded in URLs;
- email addresses and absolute user-home paths;
- binary files and Git submodules, which require deliberate review before this
  allowlisted repository can support them.

The hook never prints the detected value. It reports only the category and file
path. It is a local guard, while GitHub secret scanning and push protection
provide an independent remote guard. Like every client-side pre-commit hook, Git
can bypass it with `--no-verify`; do not use that option to publish this
repository.

Before committing:

```bash
git status --short
git diff --cached
```

Stage explicit paths instead of using `git add .`.

## Releases

Only a person starts a release. Push the commits to `main` first, then run
[`release.sh`](release.sh) from the clone:

```bash
./release.sh --dry-run        # show the next version, start nothing
./release.sh                  # next patch version: v1.2.3 -> v1.2.4
./release.sh minor            # v1.2.3 -> v1.3.0 (also: major, or vX.Y.Z)
```

The script needs the GitHub CLI (`gh auth login`). It stops when the clone is
not on `main`, has uncommitted changes, or differs from `origin/main`, because
the release is built from the commit on GitHub. It reads the latest `vX.Y.Z`
tag, asks for a confirmation (`--yes` skips it), starts the
[`Release`](.github/workflows/release.yml) workflow, follows the run, and
prints the release URL. It never creates or pushes a tag itself.

Without the script, start the workflow from the Actions tab
(**Release → Run workflow**) or with
`gh workflow run release.yml --ref main -f version=vX.Y.Z`.

The workflow has two jobs:

1. **Test and build** has read-only access. It:
   1. accepts only a `vMAJOR.MINOR.PATCH` version, a run on `main`, and a
      version whose tag does not exist yet;
   2. runs shellcheck and the [tests](#tests);
   3. makes `dotfiles-<version>.tar.gz` with `git archive` from the tested
      commit (not the source archive that GitHub generates, because its bytes
      can change);
   4. puts the version and the SHA-256 of the archive into
      [`release/bootstrap.sh`](release/bootstrap.sh) and saves the result as
      `install.sh`;
   5. writes `SHA256SUMS` for `install.sh` and the archive.
2. **Attest and publish** has the write permissions and runs no repository
   code. It checks the assets against `SHA256SUMS`, makes a build provenance
   attestation for each of the three files, creates the tag on the tested
   commit, and publishes the release with the three files as assets.

The publish job uses the environment `release`. In Settings → Environments →
`release`, you can require a reviewer before each release and limit the
environment to the `main` branch.

Dependabot ([`.github/dependabot.yml`](.github/dependabot.yml)) opens a weekly
pull request when a pinned action has a new version. It updates the commit SHA
and the version comment together.

Enable immutable releases in the repository settings: Settings, section
"Releases", **Enable release immutability**. Then nobody can change the assets
or move the tag of a published release. The setting applies only to releases
that you publish after you enable it. Never move or delete a published tag: the
`install.sh` of that release contains the SHA-256 of its archive.

For tests, the environment variable `DOTFILES_RELEASE_URL` replaces the URL of
the release assets (for example a `file://` directory). The SHA-256 check
still applies.

## Adding another tool

1. Add a row to the heredoc in `registry_rows` in `lib/registry.sh`. The
   columns are `id|label|bin|ubuntu spec|macos spec|link`. Put the row at the
   position where the tool must install. Use `-` for an unsupported platform
   and `n/a` for a platform where the tool does not apply.
2. Use an existing method (`apt`, `apt_repo`, `deb`, `formula`, `cask`) when
   one fits. Otherwise add a new method pair `method_<m>_present` and
   `method_<m>_install` to the adapter, or add a `tool <name>` spec and a
   `tool_<name>_present` and `tool_<name>_install` pair in
   `lib/tools/<name>.sh`.
3. Take URLs, keys, and flags from the current official vendor documentation.
4. Keep the present check read-only and quiet. Make every install step go
   through `run`, `run_sudo`, or `download`, so that `--dry-run` stays correct.
5. Run `shellcheck -x install.sh lib/*.sh lib/os/*.sh lib/tools/*.sh shell/*.sh`
   and the tests below.
6. Review the complete staged diff before publishing.

## Tests

| Test | Checks |
| --- | --- |
| `tests/install-dry-run.sh` | Dry runs of the installer on each platform and architecture override |
| `tests/shell-profile.sh` | The rc block wiring and the shell profile |
| `tests/bootstrap.sh` | The release bootstrap: an archive from the working tree, the `file` and the `curl \| bash` forms, an integrity failure, and the unrendered template |

Run each test from the repository root, for example:

```bash
bash tests/install-dry-run.sh
```
