# Dotfiles

Portable, public-safe configuration for command-line development tools.

The repository follows an allowlist model: only reviewed declarative
configuration is tracked. Credentials, authentication databases, environment
files, session history, caches, logs, and machine-specific state remain local.

## Contents

| Directory | Purpose |
| --- | --- |
| [`.githooks/`](.githooks/) | Version-controlled safeguards for staged commits |
| [`omp/`](omp/) | OMP settings, pi-intercom broker configuration, remote-pi relay discovery, minimal global context, MCP policy, installation, and rationale |
| [`xfce4/`](xfce4/) | Night Owl Xfce desktop assets, rationale, and undo contract |

## Install

Clone the repository and run the installer from its root:

```bash
git clone https://github.com/DocksDocks/dotfiles.git
cd dotfiles
./install.sh
```

The plain `./install.sh` command runs the `all` target. It already installs the
`remote-pi` plugin and configures the relay. A relay problem prints a notice and
never blocks the rest of the install.

Install only one configuration:

```bash
./install.sh omp
```

Install the `pi-intercom` npm plugin and provision its broker configuration
(`bun` must be on `PATH` because it runs the broker):

```bash
./install.sh intercom
```

Run only the `remote-pi` installation and relay configuration:

```bash
./install.sh remote
```

The `remote` target supports Linux and macOS. It requires `curl` and uses
Tailscale for relay discovery. On macOS, the installer also checks the Tailscale
application bundle when `PATH` does not provide the CLI.

Without `curl`, the installer cannot probe any relay. The `remote` target
therefore fails.

When the Tailscale CLI is absent, the installer detects the operating system
with `uname`. It prints a warning that names the matching install command. The
warning states that missing configuration makes `remote-pi` use the public
community relay. The installer leaves the relay configuration unchanged. It
continues successfully. It does not fail.

On Linux, the warning prints this command:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

On macOS, the warning prints the same script command. That script opens the Mac
App Store page. The warning also names `brew install --cask tailscale` as an
alternative.

When Tailscale is present but no relay answers, the target checks for existing
configuration. It keeps an existing file and continues successfully. If no file
exists, the target fails.

Without configuration, `remote-pi` would use the public community relay. The
installer refuses this silent substitution.

The `intercom` target is strict and fails when a prerequisite or the npm plugin
install fails. The default `all` target installs the plugin when `omp` and `bun`
are present, but warns and continues with hooks and tracked configuration when
the plugin cannot be installed.

Enable only the repository safeguards:

```bash
./install.sh hooks
```

The installer copies explicitly listed files rather than linking or copying
entire application directories. For OMP, `AGENTS.md` and `mcp.json` remain
managed files that are replaced (with a backup when their contents differ);
`config.yml` is recursively overlaid so repository mappings merge into the
destination while destination-only mapping keys remain. `omp/intercom.json` is
installed as `$HOME/.pi/agent/intercom/config.json`, or as
`$PI_CODING_AGENT_DIR/intercom/config.json` when that variable is set. This is
the pi-intercom runtime directory, not a path under `$HOME/.omp`. Existing
managed files are backed up before a changed result replaces them. This
repository does not store the relay URL. The installer discovers it at install
time.

`install.sh` and the pre-commit hook run on Linux and on macOS. Both use only
Bash 3.2 syntax and the tools that each base system provides, so the Bash 3.2
that macOS ships is sufficient. `xfce.sh` is the exception: it requires Bash 4
and a running Xfce desktop.

## Xfce desktop

`xfce.sh` is a separate tool with its own lifecycle. It is deliberately not
reachable through `install.sh`, which only manages tracked configuration files:
the desktop script installs distro packages, needs sudo, and only makes sense
on a machine already running Xfce.

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

Authentication is performed separately on each machine after configuration is
installed. See each tool directory for its public configuration rationale; local
authentication procedures and account details are intentionally outside this
repository.

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

## Adding another tool

1. Add a top-level directory containing only reviewed, portable files.
2. Add an intent-based README explaining non-obvious choices and citing primary
   sources.
3. Add an explicit installation function and target to `install.sh`, if the
   tool is configuration only. A tool that installs distro packages or needs
   sudo ships its own script instead, as `xfce.sh` does, so that `install.sh`
   stays safe to run on any machine.
4. Extend `.gitignore` for the tool's credentials and runtime state.
5. Review the complete staged diff before publishing.
