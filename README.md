# Dotfiles

Portable, public-safe configuration for command-line development tools.

The repository follows an allowlist model: only reviewed declarative
configuration is tracked. Credentials, authentication databases, environment
files, session history, caches, logs, and machine-specific state remain local.

## Contents

| Directory | Purpose |
| --- | --- |
| [`.githooks/`](.githooks/) | Version-controlled safeguards for staged commits |
| [`omp/`](omp/) | Oh My Pi settings and MCP policy, model-routing rationale, installation, and sources |

## Install

Clone the repository and run the installer from its root:

```bash
git clone https://github.com/DocksDocks/dotfiles.git
cd dotfiles
./install.sh
```

Install only one configuration:

```bash
./install.sh omp
```

Enable only the repository safeguards:

```bash
./install.sh hooks
```

The installer copies explicitly listed files rather than linking or copying
entire application directories. For OMP, it installs the tracked settings and
MCP denylist. Existing managed files are backed up before replacement when
their contents differ.

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
3. Add an explicit installation function and target to `install.sh`.
4. Extend `.gitignore` for the tool's credentials and runtime state.
5. Review the complete staged diff before publishing.
