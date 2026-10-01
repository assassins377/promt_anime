#!/usr/bin/env bash
# Provider-neutral candidate job for the implemented queue-1 slice only.
# No git initialization, remote writes, website startup or deployment.
set -Eeuo pipefail
if [[ ${1:-} == --help ]]; then
  printf '%s\n' 'Usage: QUEUE1_BASE_COVERAGE=/artifact/coverage.json QUEUE1_BASE_REVISION=<sha> bash dev/check_queue1_ci.sh' \
    'Requires a clean committed Git checkout, a trusted successful baseline from the default branch,' \
    'preinstalled tools from .tool-versions, Node, PostgreSQL 18 binaries and timeout.' \
    '20-minute limit; local build only. Does not constitute the full future CI of anime.md.'
  exit 0
fi
[[ $# == 0 ]] || { printf '%s\n' 'Unexpected arguments.' >&2; exit 2; }
[[ ${APP_ENV:-dev} != prod && ${APP_ENV:-dev} != staging ]] || exit 2
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

command -v timeout >/dev/null
git rev-parse --verify HEAD >/dev/null 2>&1 || {
  printf '%s\n' 'No committed Git checkout; use check_queue1_local.sh for local evidence.' >&2
  exit 2
}
[[ -z $(git status --porcelain --untracked-files=all) ]] || {
  printf '%s\n' 'CI requires a clean checkout, including untracked files.' >&2; exit 2;
}
[[ ${QUEUE1_BASE_COVERAGE:-} == /* && -f ${QUEUE1_BASE_COVERAGE:-} &&
   ${QUEUE1_BASE_REVISION:-} =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || {
  printf '%s\n' 'A trusted baseline artifact and its exact default-branch revision are required.' >&2
  exit 2
}
export ELIXIR_ERL_OPTIONS='+S 4:4' MIX_ENV=test APP_ENV=dev PHX_SERVER=false
unset DATABASE_URL TEST_DATABASE_URL ADMIN_EMAIL ADMIN_NICK ADMIN_PASSWORD

# The baseline must come from the CI service's successful default-branch job,
# not a file supplied by the pull request. The JSON gate verifies its identity.
# Bootstrap a new default branch with the local runner, not a fabricated report.
exec timeout --signal=TERM --kill-after=30s 20m bash -c '
  set -Eeuo pipefail
  before=$(sha256sum mix.lock)
  mix deps.get --check-locked
  [[ $(sha256sum mix.lock) == "$before" ]]
  bash dev/check_queue1_local.sh
  bash dev/check_release_local.sh
  [[ -z $(git status --porcelain --untracked-files=all) ]]
'
