# dotfiles repository rules

These rules apply to every agent that works in this repository. `README.md`
describes the installer, the package registry, and the shell profile.

## Safety

- The scripts never delete or move a file. Do not add `rm`, `mv`, or
  `find -delete` to `install.sh`, `lib/`, or `shell/`.
- Before code replaces or changes an existing file, it calls `backup_file` (or
  `backup_file_sudo`). That function copies the file to
  `<file>.backup.<RUN_TIMESTAMP>` (`backup_file_sudo` adds `.bak`, which apt
  ignores silently). One timestamp applies to the whole run. The exception is
  `~/.docks_profile`: the installer generates it from `shell/`, so it replaces
  the file without a backup.
- `install.sh` reads `$HOME` exactly once and validates it into `USER_HOME`.
  All other installer code uses `USER_HOME`. The `shell/*.sh` profile files are
  the exception: they run in the interactive shell of the user and use `$HOME`.
- User-level installs go under `USER_HOME` (`~/.local/bin`, `~/.bun`, `~/.nvm`,
  `PNPM_HOME`). Never copy a binary into `/usr/bin` by hand.
- Vendor installers must not edit shell rc files. Set the vendor option that
  stops the edit. Only `lib/shell.sh` changes rc files.
- Every change goes through `run`, `run_sudo`, or `download`, so that
  `--dry-run` prints the command and changes nothing.
- In your own shell commands, never write `$HOME`, `${HOME}`, or `~`. Write the
  literal absolute path. Each shell call starts a new shell, and a wrong home
  value can damage the wrong directory.
- Never run `./install.sh` without `--dry-run` unless the user asks for it.
  Never run `sudo`, `apt`, `brew`, or a vendor installer to test a change.
- Never run `rm -r`, `rm -rf`, `find -delete`, `git clean`, or
  `git reset --hard`.
- Tracked files never contain secrets or absolute user-home paths. The
  pre-commit hook rejects them. In prose and examples, write `~` or `$HOME`.

## Bash compatibility

The installer and the profile must run on Bash 3.2, the Bash that macOS ships.
Do not use `declare -A`, `mapfile`, `readarray`, `${x,,}`, `${x^^}`, `[[ -v ]]`,
`local -n`, `;&`, `;;&`, `|&`, `&>>`, negative array indexes,
`printf '%(...)T'`, or `coproc`. Under `set -u`, expand an array that can be
empty as `${arr[@]+"${arr[@]}"}`.

The dispatcher calls every `*_present` and `*_install` function inside an `if`
test, so `set -e` does not apply inside them. Chain each step with
`|| return 1`.

`xfce.sh` is the exception: it requires Bash 4.

## Lint

All shell code is clean under `shellcheck -x`. Do not add a blanket disable. A
targeted `# shellcheck disable=SCxxxx` comment needs a one-line reason.

## Releases

`README.md` (sections Installation and Releases) describes the release flow.

- A person starts every release: `.github/workflows/release.yml` has only the
  `workflow_dispatch` trigger. Do not add a push, tag, or schedule trigger.
- Never move or delete a published tag. The `install.sh` asset of a release
  contains the SHA-256 of its archive. To fix a release, publish a new version.
- The build job keeps read-only permissions. Only the publish job has write
  permissions, and it runs no repository code.
- `release/bootstrap.sh` must keep the SHA-256 check: it never unpacks or runs
  an archive whose SHA-256 is different from the embedded value. It downloads
  only over HTTPS (the `DOTFILES_RELEASE_URL` test seam also accepts a
  `file://` URL), never from a branch, and never uses `rm` or `mv`.
- Every action in `.github/workflows/` stays pinned to a full commit SHA, with
  the version in a comment. Dependabot updates the pins. Keep the
  `permissions` to the minimum, and pass inputs to `run:` steps only through
  `env:`.
- Run `tests/bootstrap.sh` after a change to `release/bootstrap.sh` or to the
  layout of the repository.

## Vendor sources

Take every URL, key, repository line, package name, and installer flag from the
official vendor documentation. Verify it against the current documentation
before you add or change it. Do not copy it from memory or from a third-party
guide.

## Idempotency

A present tool is skipped. The installer never upgrades a tool. Each
`*_present` check is read-only, prints nothing on stdout, and also works in
dry-run mode. A second run on a complete machine changes nothing.

## Adding a package

1. Add a row to the heredoc in `registry_rows` in `lib/registry.sh`:
   `id|label|bin|ubuntu spec|macos spec|link`. The row position is the install
   order. Write `-` for an unsupported platform and `n/a` for a platform where
   the package does not apply.
2. Use an existing method (`apt`, `apt_repo`, `deb`, `formula`, `cask`) when one
   fits. Otherwise add a `method_<m>_present` and `method_<m>_install` pair to
   the adapter in `lib/os/`, or write a `tool <name>` spec and add a
   `tool_<name>_present` and `tool_<name>_install` pair in
   `lib/tools/<name>.sh`.
3. An install function returns 0 on success, 1 on failure, `RC_UNSUPPORTED`
   (3) when the platform or the architecture is not supported, and
   `RC_SYNCED` (4) when a step that runs on every run (such as
   `docks-kit sync omp`) finished. The summary does not count a sync as new.
4. Run `shellcheck -x` on the changed files, `tests/install-dry-run.sh`, and
   `tests/shell-profile.sh`.
5. Update the package table in `README.md`.
