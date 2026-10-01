#!/usr/bin/env bash
# Local evidence, not a staging/production acceptance or a deployment command.
# Never sources .env and never rolls back a caller-provided database.
set -Eeuo pipefail

if [[ ${1:-} == --help ]]; then
  printf '%s\n' 'Usage: bash dev/check_queue1_local.sh' \
    'Requires installed dependencies, PostgreSQL 18, Elixir/Mix and Node.' \
    'Creates its own temporary cluster on 127.0.0.1:59433; never uses DATABASE_URL.' \
    'QUEUE1_CHECK_PORT and QUEUE1_PG_BINDIR may override the port and PostgreSQL binaries.' \
    'Stops its cluster on exit; preserves database, logs and schema snapshots in /tmp.' \
    'Runs full migration up/down/up, seed idempotency, per-module coverage, asset build/deploy and security.' \
    'Optional QUEUE1_BASE_COVERAGE plus QUEUE1_BASE_REVISION enable the 1pp regression gate.' \
    'Does not prove browser, SMTP/MinIO, cluster, CI, release or staging acceptance.'
  exit 0
fi
[[ $# == 0 ]] || { printf '%s\n' 'Unexpected arguments; use --help.' >&2; exit 2; }
[[ ${APP_ENV:-dev} != prod && ${APP_ENV:-dev} != staging ]] || {
  printf '%s\n' 'Refusing a staging/production environment.' >&2; exit 2;
}

check_port=${QUEUE1_CHECK_PORT:-59433}
[[ $check_port =~ ^[1-9][0-9]{3,4}$ ]] && (( check_port <= 65535 )) || {
  printf '%s\n' 'QUEUE1_CHECK_PORT must be a port from 1024 to 65535.' >&2; exit 2;
}
(( check_port >= 1024 )) || exit 2
pg_bin=${QUEUE1_PG_BINDIR:-/usr/lib/postgresql/18/bin}
for binary in initdb pg_ctl createdb psql pg_dump; do
  [[ -x $pg_bin/$binary ]] || { printf 'Missing PostgreSQL binary: %s\n' "$binary" >&2; exit 2; }
done
for binary in mix elixir node openssl; do
  command -v "$binary" >/dev/null || { printf 'Missing command: %s\n' "$binary" >&2; exit 2; }
done
[[ $("$pg_bin/pg_ctl" --version) == *' 18.'* ]] || {
  printf '%s\n' 'This check requires PostgreSQL 18.' >&2; exit 2;
}

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
check_dir=$(mktemp -d /tmp/anime-queue1-check.XXXXXXXX)
chmod 700 "$check_dir"
cluster_started=false
cleanup() {
  local result=$?
  trap - EXIT
  if [[ $cluster_started == true ]]; then
    if ! "$pg_bin/pg_ctl" -D "$check_dir/data" -m fast -w stop >>"$check_dir/postgres-control.log" 2>&1; then
      printf '%s\n' 'Could not stop the temporary cluster; see postgres-control.log.' >&2
      result=1
    fi
  fi
  printf 'Exit status: %s. Evidence and temporary data preserved: %s\n' "$result" "$check_dir"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Explicit connection settings, independent of the shell's PostgreSQL/app environment.
unset PGHOST PGHOSTADDR PGPORT PGDATABASE PGUSER PGPASSWORD PGSERVICE PGSERVICEFILE PGOPTIONS
unset DATABASE_URL TEST_DATABASE_URL MIX_TEST_PARTITION ADMIN_EMAIL ADMIN_NICK ADMIN_PASSWORD
export MIX_ENV=test PHX_SERVER=false APP_ENV=dev
export ELIXIR_ERL_OPTIONS='+S 4:4'
export PGPASSWORD
PGPASSWORD=$(openssl rand -hex 24)
export TEST_DATABASE_URL="ecto://postgres:${PGPASSWORD}@127.0.0.1:${check_port}/anime_test"
export QUEUE1_CHECK_DATA_DIR="$check_dir/data"

step() {
  local name=$1
  shift
  printf '\n[%s]\n' "$name"
  "$@" >"$check_dir/$name.log" 2>&1 || {
    printf 'FAILED: %s (see %s/%s.log)\n' "$name" "$check_dir" "$name" >&2
    return 1
  }
  printf 'PASS: %s\n' "$name"
}
sql() {
  "$pg_bin/psql" -X -w -h 127.0.0.1 -p "$check_port" -U postgres -d anime_test \
    -v ON_ERROR_STOP=1 -Atc "$1"
}
schema() {
  "$pg_bin/pg_dump" -w -h 127.0.0.1 -p "$check_port" -U postgres -d anime_test \
    --schema-only --no-owner --no-privileges --restrict-key=Queue1SchemaCheck
}

step format mix format --check-formatted
step compile-dev env MIX_ENV=dev mix compile --warnings-as-errors
step compile-test mix compile --warnings-as-errors
step initdb "$pg_bin/initdb" -D "$check_dir/data" -U postgres --encoding=UTF8 \
  --locale=C.UTF-8 --auth-local=trust --auth-host=scram-sha-256 --pwfile=<(printf '%s\n' "$PGPASSWORD")
# Set before pg_ctl: even an interrupted/timeout start is cleaned up only at this new directory.
cluster_started=true
step start-db "$pg_bin/pg_ctl" -D "$check_dir/data" -l "$check_dir/postgres.log" \
  -o "-h 127.0.0.1 -p $check_port -k ''" -w start
step create-db "$pg_bin/createdb" -w -h 127.0.0.1 -p "$check_port" -U postgres anime_test
[[ $(sql 'SHOW data_directory') == "$check_dir/data" ]] || exit 1

step migrate-first mix ecto.migrate
migration_count=$(sql 'SELECT count(*) FROM schema_migrations')
(( migration_count > 0 )) || exit 1
schema >"$check_dir/schema-first.sql"
step seed-first mix run --no-compile dev/seed_smoke.exs
step rollback-all mix ecto.rollback --all
[[ $(sql 'SELECT count(*) FROM schema_migrations') == 0 ]] || exit 1
[[ $(sql "SELECT string_agg(tablename, ',' ORDER BY tablename) FROM pg_tables WHERE schemaname='public'") == schema_migrations ]] || exit 1
[[ $(sql "SELECT count(*) FROM pg_extension WHERE extname IN ('citext', 'pg_trgm')") == 0 ]] || exit 1
[[ $(sql "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public'") == 0 ]] || exit 1
[[ $(sql "SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname='public' AND t.typtype='e'") == 0 ]] || exit 1
step migrate-second mix ecto.migrate
[[ $(sql 'SELECT count(*) FROM schema_migrations') == "$migration_count" ]] || exit 1
schema >"$check_dir/schema-second.sql"
step schema-equivalence cmp "$check_dir/schema-first.sql" "$check_dir/schema-second.sql"
step migrate-idempotent mix ecto.migrate
schema >"$check_dir/schema-third.sql"
step schema-idempotent cmp "$check_dir/schema-second.sql" "$check_dir/schema-third.sql"
printf '%s migrations: up / full down / up / no-op passed.\n' "$migration_count"

# Finish independent checks even if a test, coverage threshold or external audit fails.
failed=0
step tests-coverage mix test --cover --warnings-as-errors --seed 100105 || failed=1
# Keep this run's report when a later run replaces app/cover.
if [[ -d cover ]]; then
  cp -R cover "$check_dir/cover"
fi
step seed-second mix run --no-compile dev/seed_smoke.exs || failed=1
step assets mix assets.build || failed=1
step assets-deploy mix assets.deploy || failed=1
step js-table node test/js/admin_table_test.mjs || failed=1
step js-shell node test/js/admin_shell_test.mjs || failed=1
step js-header node test/js/public_header_test.mjs || failed=1
step runtime-preflight elixir dev/runtime_preflight_smoke.exs || failed=1
step stdout-logging mix run --no-compile --no-start dev/logging_smoke.exs || failed=1
step coverage-gates elixir dev/coverage_gate_smoke.exs || failed=1
step security mix security.check || failed=1
printf '\nThese local checks do not close queue 1 or authorize deployment.\n'
exit "$failed"
