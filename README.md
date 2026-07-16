# Dotfiles

Portable, public-safe configuration for command-line development tools.

The repository follows an allowlist model: only reviewed declarative
configuration is tracked. Credentials, authentication databases, environment
files, session history, caches, logs, and machine-specific state remain local.

## Contents

| Directory | Purpose |
| --- | --- |
| [`omp/`](omp/) | Oh My Pi configuration, model-routing rationale, installation, and sources |

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

The installer copies explicitly listed files rather than linking or copying
entire application directories. Existing managed files are backed up before
replacement when their contents differ.

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
