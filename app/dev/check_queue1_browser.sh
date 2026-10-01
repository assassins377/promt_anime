#!/usr/bin/env bash
# Interactive UI acceptance only. Own temporary DB; no .env, real mail or user data.
set -Eeuo pipefail
[[ $# == 0 ]] || exit 2
[[ ${APP_ENV:-dev} != prod && ${APP_ENV:-dev} != staging ]] || exit 2
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
pg_bin=/usr/lib/postgresql/18/bin
ui_dir=$(mktemp -d /tmp/anime-queue1-browser.XXXXXXXX)
cluster_started=false
cleanup() {
  local result=$?
  trap - EXIT
  if [[ $cluster_started == true ]]; then
    "$pg_bin/pg_ctl" -D "$ui_dir/data" -m fast -w stop >>"$ui_dir/control.log" 2>&1 || result=1
  fi
  printf 'UI server stopped. Evidence retained: %s (exit %s)\n' "$ui_dir" "$result"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
unset DATABASE_URL TEST_DATABASE_URL MIX_TEST_PARTITION ADMIN_EMAIL ADMIN_NICK ADMIN_PASSWORD
unset PGHOST PGHOSTADDR PGPORT PGDATABASE PGUSER PGPASSWORD PGSERVICE PGSERVICEFILE PGOPTIONS
export MIX_ENV=test PHX_SERVER=false APP_ENV=dev ELIXIR_ERL_OPTIONS='+S 4:4'
export PGPASSWORD
PGPASSWORD=$(openssl rand -hex 24)
export TEST_DATABASE_URL="ecto://postgres:${PGPASSWORD}@127.0.0.1:59434/anime_ui_test"
"$pg_bin/initdb" -D "$ui_dir/data" -U postgres --encoding=UTF8 --locale=C.UTF-8 \
  --auth-local=trust --auth-host=scram-sha-256 --pwfile=<(printf '%s\n' "$PGPASSWORD") >"$ui_dir/initdb.log" 2>&1
cluster_started=true
"$pg_bin/pg_ctl" -D "$ui_dir/data" -l "$ui_dir/postgres.log" \
  -o "-h 127.0.0.1 -p 59434 -k $ui_dir" -w start >"$ui_dir/control.log" 2>&1
"$pg_bin/createdb" -w -h 127.0.0.1 -p 59434 -U postgres anime_ui_test
mix ecto.migrate >"$ui_dir/migrations.log" 2>&1
printf 'UI evidence: %s\n' "$ui_dir"
printf 'Only synthetic accounts at http://localhost:4002; IEx controls this test VM only.\n'
printf 'Stop cleanly with System.stop() in IEx.\n'
iex --dot-iex /dev/null -S mix run --no-start dev/admin_ui_smoke.exs
