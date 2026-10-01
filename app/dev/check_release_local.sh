#!/usr/bin/env bash
# Build and inspect a self-contained package. Never start Anime or a database.
set -Eeuo pipefail
if [[ ${1:-} == --help ]]; then
  printf '%s\n' 'Usage: bash dev/check_release_local.sh' \
    'Builds MIX_ENV=prod into a new /tmp/anime-release-check.XXXXXXXX/package.' \
    'Checks bundled assets/runtime and release eval with synthetic dev settings.' \
    'Never starts the application, runs migrations, deploys, or reads .env.'
  exit 0
fi
[[ $# == 0 ]] || exit 2
[[ ${APP_ENV:-dev} != prod && ${APP_ENV:-dev} != staging ]] || exit 2
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
check_dir=$(mktemp -d /tmp/anime-release-check.XXXXXXXX)
chmod 700 "$check_dir"
trap 'printf "Release check exit %s; evidence: %s\n" "$?" "$check_dir"' EXIT
unset DATABASE_URL TEST_DATABASE_URL ADMIN_EMAIL ADMIN_NICK ADMIN_PASSWORD
unset SECRET_KEY_BASE LIVE_VIEW_SIGNING_SALT RELEASE_COOKIE MIX_BUILD_PATH
export MIX_ENV=prod ELIXIR_ERL_OPTIONS='+S 4:4'
step() {
  local name=$1
  shift
  printf '[%s]\n' "$name"
  "$@" >"$check_dir/$name.log" 2>&1 || {
    printf 'FAILED: %s (see %s/%s.log)\n' "$name" "$check_dir" "$name" >&2
    return 1
  }
  printf 'PASS: %s\n' "$name"
}
step compile mix compile --warnings-as-errors
step assets mix assets.deploy
step release mix release anime --path "$check_dir/package"
step package-preflight elixir dev/release_package_smoke.exs "$check_dir/package"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  printf 'package=%s\n' "$check_dir/package" >> "$GITHUB_OUTPUT"
fi
printf '%s\n' 'Package checked; no application boot, database, MinIO, SMTP, container or staging acceptance.'
