# Dotfiles

A Bash installer and a shared shell profile for development machines on Ubuntu
and macOS.

`install.sh` detects the operating system and the CPU architecture. Then it
installs the packages of a registry through one adapter per operating system.
A second run changes nothing when every package is present. The `--dry-run`
option prints every command and changes nothing.

The repository tracks only reviewed configuration and scripts. Credentials,
environment files, caches, logs, and machine-specific state stay local.

## Installation

Run the installer of the latest release. You do not need a clone:

```bash
curl -fsSL https://github.com/DocksDocks/dotfiles/releases/latest/download/install.sh | bash
```

Do a dry run first. The words after `--` go to the installer, so every command
of [Usage](#usage) works:

```bash
curl -fsSL https://github.com/DocksDocks/dotfiles/releases/latest/download/install.sh | bash -s -- --dry-run
curl -fsSL https://github.com/DocksDocks/dotfiles/releases/latest/download/install.sh | bash -s -- --dry-run packages gh docker
```

The `install.sh` of a release is a small bootstrap script
([`release/bootstrap.sh`](release/bootstrap.sh)). It contains the tag of its
release and the SHA-256 of the archive `dotfiles-<tag>.tar.gz`. It downloads
the archive into `~/.cache/dotfiles-install/release/` and checks the SHA-256
before it unpacks anything. Then it runs the `install.sh` of the archive with
your arguments. Thus release `vX.Y.Z` always installs exactly `vX.Y.Z`.

A release is not a Git clone, so the summary shows the Git hooks as not
applicable.

### Verify a release

Each release has three assets: `install.sh`, `dotfiles-<tag>.tar.gz`, and
`SHA256SUMS`. Each asset has a GitHub artifact attestation, which proves that
the release workflow of this repository built the file. Download the files from
the URL of one tag, because the `latest` URLs can change between two downloads:

```bash
base=https://github.com/DocksDocks/dotfiles/releases/download/vX.Y.Z
curl -fsSL -O "$base/install.sh" -O "$base/SHA256SUMS"
sha256sum --check --ignore-missing SHA256SUMS
gh attestation verify install.sh --repo DocksDocks/dotfiles
```

On macOS, use `shasum -a 256 --check --ignore-missing SHA256SUMS`.

## Contents

| Path | Purpose |
| --- | --- |
| [`install.sh`](install.sh) | Entry point: arguments, guards, and command dispatch |
| [`lib/`](lib/) | Core functions, platform detection, package registry, summary, and shell wiring |
| [`lib/os/`](lib/os/) | One adapter per operating system, and the rootless Docker tool for Ubuntu |
| [`lib/tools/`](lib/tools/) | Cross-platform tool installers |
| [`shell/`](shell/) | Shared shell profile, with Linux and macOS parts |
| [`.githooks/`](.githooks/) | Pre-commit hook |
| [`release/bootstrap.sh`](release/bootstrap.sh) | Template of the `install.sh` that each release publishes |
| [`release.sh`](release.sh) | Starts the release workflow |
| [`.github/`](.github/) | Release workflow and Dependabot configuration |
| [`xfce.sh`](xfce.sh), [`xfce4/`](xfce4/) | Separate Xfce desktop tool and its assets |
| [`tests/`](tests/) | Tests |

## Supported platforms

| Platform | Architectures | Package manager |
| --- | --- | --- |
| Ubuntu 26.04 or later | amd64, arm64 | apt, vendor apt repositories, vendor `.deb` files |
| macOS | arm64 (Apple Silicon), Intel | Homebrew formulae and casks |

On other platforms, the installer stops with an error.

- **Intel Macs:** the official Homebrew installer does not support Intel. The
  installer uses a `brew` that is already present. Without `brew`, it reports
  each Homebrew item as unsupported. The tools with their own vendor installer
  (uv, Python, Node.js, Bun, pnpm, omp, docks-kit) do not need Homebrew.
- **Rosetta 2 terminal on Apple Silicon:** the installer restarts itself as
  native arm64 code, because Homebrew does not run under Rosetta.
- **Bash:** all scripts run on Bash 3.2, the Bash that macOS ships. `xfce.sh`
  is the exception: it needs Bash 4 and a running Xfce desktop.

## Usage

Clone the repository to work on it or to use the Git hooks. Run the installer
with `--dry-run` first, and read the commands that it prints:

```bash
git clone https://github.com/DocksDocks/dotfiles.git
cd dotfiles
./install.sh --dry-run
./install.sh
```

Do not run the installer as root. It asks for the sudo password once, when a
step needs root.

```text
./install.sh [--dry-run|-n] [all | packages [id...] | shell | hooks | list]
```

| Command | Effect |
| --- | --- |
| `all` (default) | Enables the Git hooks, installs all packages, wires the shell profile, and prints the summary |
| `packages [id...]` | Installs all packages, or only the given ids in registry order, and prints the summary |
| `shell` | Wires the shell profile into the rc files |
| `hooks` | Sets `core.hooksPath` of this clone to `.githooks` |
| `list` | Prints the registry for this platform |

An unknown id stops the run before any change. Before it installs packages,
the installer prepares the system. On Ubuntu, it installs `ca-certificates`,
`curl`, and `unzip`. On Apple Silicon, it installs Homebrew when `brew` is
missing.

For tests, `DOTFILES_OS` (`ubuntu` or `macos`) and `DOTFILES_ARCH` (`amd64` or
`arm64`) replace the detected platform. The installer accepts them only with
`--dry-run` or with the `shell` command.

Rootless Docker needs a login session of your user. Run the installer from a
desktop terminal or an SSH login, not through `sudo` or `su`.

## Packages

`lib/registry.sh` lists the packages in install order. A `-` means that the
platform is not supported, and the summary prints the download link. `n/a`
means that the package does not apply to the platform.

| Id | Ubuntu method | macOS method | Notes |
| --- | --- | --- | --- |
| `git` | apt `git` | formula `git` | |
| `gh` | apt repository `github-cli` | formula `gh` | GitHub CLI |
| `btop` | apt `btop` | formula `btop` | |
| `php` | apt `php-*` metapackages | formula `php` | PHP CLI and common extensions (`php8.5-*` on Ubuntu 26.04) |
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
| `docker` | apt repository `docker` | cask `docker-desktop` | Ubuntu: Docker Engine for rootless mode |
| `docker-rootless` | tool `docker_rootless` | n/a | Ubuntu: rootless daemon for the current user |
| `tailscale` | apt repository `tailscale` | cask `tailscale-app` | |
| `chrome` | `.deb` `chrome` | cask `google-chrome` | |
| `discord` | `.deb` `discord` | cask `discord` | Ubuntu: amd64 only |
| `github-desktop` | n/a | cask `github` | GitHub publishes no Linux build |
| `vlc` | apt `vlc` | cask `vlc` | |
| `rustdesk` | `.deb` `rustdesk` | cask `rustdesk` | |
| `parsec` | `.deb` `parsec` | cask `parsec` | Ubuntu: amd64 only |

Methods: `apt` installs from the Ubuntu archive. `apt_repo` first adds the
vendor key and apt source. `deb` downloads a vendor `.deb` file. `formula` and
`cask` use Homebrew. `tool` calls a `tool_<name>_present` and
`tool_<name>_install` pair in `lib/tools/` or `lib/os/`.

## Installer behavior

- The installer skips a present package and never upgrades one. On Ubuntu, a
  command that is already on `PATH` (for example from a snap) also counts as
  present.
- The scripts never delete or move a file. Before a change to an existing
  file, the installer copies it to `<file>.backup.<timestamp>`. Under `/etc`,
  the copy gets an extra `.bak`, because apt ignores `.bak` files.
- Downloads, vendor installer scripts included, go to
  `~/.cache/dotfiles-install`. The installer never pipes a download into a
  shell.
- Vendor installers do not edit rc files. Only the profile block changes them.
- One failure does not stop the run. The exit status is 1 when any item
  failed.
- The summary lists new, unsupported, and failed items, with a download link
  for each unsupported or failed item. Present items and routine syncs show as
  counts. `NO_COLOR=1` turns the colors off.
- The output of the last `docks-kit sync omp` stays in
  `~/.cache/dotfiles-install/docks-kit-sync.log`. The run shows it only when it
  reports a warning, a skipped step, or an error.
- When Tern (Stencil Labs) is missing, the run ends with its download link,
  <https://build.stencil.so/tern>, and the waitlist,
  <https://stencil.so/tern>. Tern is invite only, so the installer cannot
  install it.

## Shell profile

The `shell` command (and `all`) writes `~/.docks_profile` from
`shell/profile.sh` and the Linux or macOS part. The file is a copy, so it keeps
working when the clone moves. Then the command appends one block that sources
the file to each rc file: `~/.bashrc` on Ubuntu, `~/.zshrc` and
`~/.bash_profile` on macOS. The block is between `# >>> docks profile >>>` and
`# <<< docks profile <<<`. The installer does not change an rc file that
already has the block.

The profile sets `PATH`, `NVM_DIR`, `BUN_INSTALL`, `PNPM_HOME`, and other tool
variables. It also loads `~/.config/secrets.env` when that file exists. Keep
tokens in that file, never in the repository.

- After a change to `shell/`, run `./install.sh shell`. It replaces
  `~/.docks_profile` without a backup. Do not edit that file by hand.
- To unlink the profile, delete the block from the rc file.
- The installer warns when an rc file sets `NVM_DIR`, `PNPM_HOME`,
  `BUN_INSTALL`, `DOCKER_HOST`, or `ANDROID_HOME` outside the block. Remove
  these duplicates by hand.

## After the installation

Open a new terminal, so that the shell profile is active. Then:

1. Connect Tailscale: `sudo tailscale up`.
2. Sign in to the desktop applications.
3. Ubuntu: make sure that Docker runs in rootless mode.
   `docker info --format '{{.SecurityOptions}}'` must contain `name=rootless`.
4. Authenticate the GitHub CLI: `gh auth login`.

## omp configuration

docks-kit owns the omp configuration, not this repository. The
`docks-kit-sync` package runs `docks-kit sync omp` on every run. To update the
configuration without a full run, run `docks-kit sync omp`.

## Xfce desktop

`xfce.sh` is a separate tool, and `install.sh` never calls it. It changes the
settings of a running Xfce desktop and needs sudo. It saves every setting that
it touches before the first change.

```bash
./xfce.sh           # apply
./xfce.sh status    # compare the current settings with the wanted settings
./xfce.sh revert    # restore the saved settings
```

See [`xfce4/README.md`](xfce4/README.md).

## Security

Tracked files never contain secrets, credential stores, `.env` files, session
data, logs, caches, or machine-specific paths. Each machine signs in to its
accounts after the installation.

The pre-commit hook in `.githooks/` scans the staged files. It rejects:

- sensitive file names and runtime directories;
- private keys, common token formats, and assigned secrets;
- credentials in URLs;
- email addresses and absolute home paths;
- binary files and Git submodules.

The hook reports the category and the path, never the value. GitHub secret
scanning and push protection are a second guard on the remote. Do not use
`git commit --no-verify` in this repository.

## Releases

A person starts every release. Push the commits to `main`, then run
[`release.sh`](release.sh):

```bash
./release.sh --dry-run        # show the next version, start nothing
./release.sh                  # next patch version: v1.2.3 -> v1.2.4
./release.sh minor            # v1.2.3 -> v1.3.0 (also: major, or vX.Y.Z)
```

The script needs the GitHub CLI (`gh auth login`). It stops when the clone is
not on `main`, has uncommitted changes, or differs from `origin/main`. It asks
for a confirmation (`--yes` skips it), starts the
[`Release`](.github/workflows/release.yml) workflow, follows the run, and
prints the release URL. It never creates a tag itself. Without the script, run
`gh workflow run release.yml --ref main -f version=vX.Y.Z`.

The workflow has two jobs:

1. **Test and build** has read-only permissions. It checks the version, runs
   shellcheck and the [tests](#tests), and builds the archive with
   `git archive`. It writes the version and the archive SHA-256 into
   [`release/bootstrap.sh`](release/bootstrap.sh) to make `install.sh`, and
   writes `SHA256SUMS`.
2. **Attest and publish** has write permissions and runs no repository code.
   It checks the assets against `SHA256SUMS`, attests each asset, tags the
   tested commit, and publishes the release.

Rules for releases:

- Never move or delete a published tag. The `install.sh` of a release contains
  the SHA-256 of its archive. To fix a release, publish a new version.
- Enable release immutability (Settings → Releases), so that nobody can change
  a published release.
- The publish job uses the `release` environment. There you can require a
  reviewer for each release.
- Dependabot updates the pinned actions every week.
- For tests, `DOTFILES_RELEASE_URL` replaces the URL of the release assets, for
  example with a `file://` directory. The SHA-256 check still applies.

## Adding a package

Follow [Adding a package](AGENTS.md#adding-a-package) in `AGENTS.md`.

## Tests

Run each test from the repository root, for example
`bash tests/install-dry-run.sh`.

| Test | Checks |
| --- | --- |
| `tests/install-dry-run.sh` | Dry runs of the installer on each platform and architecture override |
| `tests/shell-profile.sh` | The rc block and the shell profile |
| `tests/bootstrap.sh` | The release bootstrap: a local archive, the `file` and `curl \| bash` forms, an integrity failure, and the unrendered template |
