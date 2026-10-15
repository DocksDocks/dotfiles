# shellcheck shell=bash
# Rootless Docker on Ubuntu: the docker_rootless tool and the check for
# packages that conflict with Docker Engine from Docker's apt repository.
# Sourced by lib/os/ubuntu.sh. Uses the core API and apt_pkg_installed.
# Guide: https://docs.docker.com/engine/security/rootless/

DOCKER_ROOTLESS_HELP_URL='https://docs.docker.com/engine/security/rootless/troubleshoot/'

# Conflicting packages -------------------------------------------------------

# Prints the installed packages that conflict with docker-ce, separated by
# spaces. The list comes from the Docker Engine install guide for Ubuntu.
docker_installed_conflicts() {
  local pkg found=''

  for pkg in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
    if apt_pkg_installed "$pkg"; then
      found="$found $pkg"
    fi
  done
  printf '%s\n' "${found# }"
}

# The installer does not remove packages. apt-get would remove the
# conflicting packages without a question because of "-y", so stop before.
docker_check_conflicts() {
  local found

  found="$(docker_installed_conflicts)" || return 1
  [ -n "$found" ] || return 0
  warn "these packages conflict with Docker Engine: $found"
  warn "remove them, then run the installer again: sudo apt-get remove $found"
  return 1
}

# Checks ----------------------------------------------------------------------

# Returns 0 when the user unit docker.service is enabled and the CLI context
# "rootless" exists. Quiet and read-only.
docker_rootless_service_ready() {
  local state

  have systemctl || return 1
  have docker || return 1
  state="$(systemctl --user is-enabled docker.service 2>/dev/null)" || return 1
  [ "$state" = enabled ] || return 1
  docker context inspect rootless >/dev/null 2>&1
}

# Returns 0 when systemd keeps the user manager running without a login, so
# the rootless daemon starts at boot. Quiet and read-only.
docker_linger_enabled() {
  local user state

  have loginctl || return 1
  user="$(id -un)" || return 1
  state="$(loginctl show-user "$user" -p Linger --value 2>/dev/null)" || return 1
  [ "$state" = yes ]
}

# The setup tool needs the runtime directory of a real login session.
# sudo and su do not create one.
docker_check_session() {
  local user="$1" dir="${XDG_RUNTIME_DIR:-}"

  if [ -n "$dir" ] && [ -d "$dir" ]; then
    return 0
  fi
  warn 'XDG_RUNTIME_DIR is not set or is not a directory.'
  warn "Rootless Docker needs a real login session of $user: a desktop session, 'ssh $user@localhost' or 'machinectl shell $user@'."
  warn "It does not work under sudo or su. Log in as $user, then run the installer again."
  return 1
}

# Returns 0 when <file> has an entry for the user name <user> or the UID <uid>.
docker_has_subid_entry() {
  local file="$1" user="$2" uid="$3" line

  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$user":* | "$uid":*) return 0 ;;
    esac
  done <"$file"
  return 1
}

# The installer does not edit /etc/subuid or /etc/subgid. It prints the
# command that the setup tool suggests.
docker_check_subids() {
  local user="$1" uid file rc=0

  uid="$(id -u)" || return 1
  for file in /etc/subuid /etc/subgid; do
    if ! docker_has_subid_entry "$file" "$user" "$uid"; then
      warn "$file has no entry for $user. Rootless Docker needs at least 65536 subordinate IDs."
      warn "Make sure that no other entry in $file uses 100000-165535, then run:"
      warn "  sudo sh -c 'echo \"$user:100000:65536\" >> $file'"
      rc=1
    fi
  done
  return "$rc"
}

# Returns 0 when the rootful docker.service or docker.socket is enabled or
# active. Quiet and read-only.
docker_rootful_enabled() {
  local unit state

  have systemctl || return 1
  for unit in docker.service docker.socket; do
    state="$(systemctl is-enabled "$unit" 2>/dev/null)" || state=''
    case "$state" in
      enabled | enabled-runtime) return 0 ;;
    esac
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# The rootless guide disables the rootful daemon first. The installer does
# not remove /var/run/docker.sock.
docker_disable_rootful() {
  docker_rootful_enabled || return 0
  log 'Disable the rootful Docker daemon, as the rootless guide tells.'
  run_sudo systemctl disable --now docker.service docker.socket || return 1
}

docker_explain_setup_failure() {
  local user="$1"

  warn 'dockerd-rootless-setuptool.sh install failed. Read its output above.'
  if [ -S /var/run/docker.sock ] && [ -w /var/run/docker.sock ]; then
    warn "The tool stops when rootful Docker (/var/run/docker.sock) is running and $user can write to it."
    warn "The installer does not remove the socket. Stop rootful Docker and remove /var/run/docker.sock, or remove $user from the docker group. Then run the installer again."
  fi
  warn "Help: $DOCKER_ROOTLESS_HELP_URL"
}

# Runs the official setup tool as the current user. The minimal PATH keeps
# user tool paths (nvm, bun) out of the generated unit file.
docker_rootless_setup() {
  local user="$1"

  docker_check_session "$user" || return 1
  docker_check_subids "$user" || return 1
  docker_disable_rootful || return 1
  if ! run env PATH=/usr/bin:/bin:/usr/sbin:/sbin dockerd-rootless-setuptool.sh install; then
    docker_explain_setup_failure "$user"
    return 1
  fi
  run systemctl --user enable docker.service || return 1
}

# Tool: docker_rootless --------------------------------------------------------

tool_docker_rootless_present() {
  docker_rootless_service_ready || return 1
  docker_linger_enabled
}

# A ready service skips the setup tool: each run of the tool switches the
# CLI back to the "rootless" context.
tool_docker_rootless_install() {
  local user

  require_cmd dockerd-rootless-setuptool.sh docker || return 1
  user="$(id -un)" || return 1
  if ! docker_rootless_service_ready; then
    docker_rootless_setup "$user" || return 1
  fi
  if ! docker_linger_enabled; then
    run_sudo loginctl enable-linger "$user" || return 1
  fi
}
