# shellcheck shell=bash
# Tool: Composer through the official installer, with the signature check
# from https://getcomposer.org/doc/faqs/how-to-install-composer-programmatically.md
# The registry uses this tool on Ubuntu only (macOS uses the brew formula).

# Print the SHA-384 of <file>, computed by php as the Composer docs show.
# The path goes in as an argument, not as PHP source.
composer_file_hash() {
  php -r "echo hash_file('sha384', \$argv[1]);" "$1"
}

# True when the SHA-384 of <setup file> equals the hash in <sig file>.
composer_verify_installer() {
  local setup_file="$1" sig_file="$2" expected actual

  expected="$(tr -d '[:space:]' <"$sig_file")" || return 1
  actual="$(composer_file_hash "$setup_file")" || return 1
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    warn "Composer installer signature does not match ($sig_file); do not install"
    return 1
  fi
}

tool_composer_present() {
  have composer
}

tool_composer_install() {
  local bin_dir setup_file sig_file

  require_cmd php php || return 1
  bin_dir="$(local_bin_dir)"
  sig_file="$(cache_file composer-installer.sig)"
  setup_file="$(cache_file composer-setup.php)"
  # The signature changes with each installer release, so fetch it each run.
  download https://composer.github.io/installer.sig "$sig_file" || return 1
  download https://getcomposer.org/installer "$setup_file" || return 1
  if [ "$DRY_RUN" = 1 ]; then
    log "[dry-run] compare the SHA-384 of $setup_file with $sig_file"
  else
    composer_verify_installer "$setup_file" "$sig_file" || return 1
  fi
  # The Composer installer stops when the install directory does not exist.
  run mkdir -p "$bin_dir" || return 1
  run php "$setup_file" --quiet "--install-dir=$bin_dir" --filename=composer || return 1
  path_prepend "$bin_dir"
}
