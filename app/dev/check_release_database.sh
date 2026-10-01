#!/usr/bin/env bash
# Only a freshly created private database; never accepts a database URL.
set -Eeuo pipefail
[[ ($# == 1 || $# == 2) && $1 == /tmp/anime-release-check.*/package && -x $1/bin/anime ]] || exit 2
minio_bin=''
if [[ $# == 2 ]]; then [[ -x $2 ]] || exit 2; minio_bin=$(realpath "$2"); fi
package=$(realpath "$1")
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
pg=/usr/lib/postgresql/18/bin
dir=$(mktemp -d /tmp/anime-release-db.XXXXXXXX)
chmod 700 "$dir"
started=false
server_pid=''
minio_pid=''
cleanup() {
  result=$?
  trap - EXIT
  if [[ -n $server_pid ]]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    for _ in {1..900}; do
      kill -0 "$server_pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$server_pid" 2>/dev/null; then
      kill -KILL "$server_pid" 2>/dev/null || true
      result=1
    fi
    wait "$server_pid" 2>/dev/null || true
    [[ $(<"$dir/server.log") == *'"message":"Application stopped"'* ]] || result=1
  fi
  if [[ $started == true ]]; then
    "$pg/pg_ctl" -D "$dir/data" -m fast -w stop >"$dir/stop.log" 2>&1 || result=1
  fi
  if [[ -n $minio_pid ]]; then
    kill -TERM "$minio_pid" 2>/dev/null || true
    for _ in {1..50}; do kill -0 "$minio_pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$minio_pid" 2>/dev/null; then kill -KILL "$minio_pid" 2>/dev/null || true; result=1; fi
    wait "$minio_pid" 2>/dev/null || true
  fi
  printf 'Release database check exit %s; evidence: %s\n' "$result" "$dir"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[[ -z $(ss -H -ltn '( sport = :59434 or sport = :49137 or sport = :49568 or sport = :59438 or sport = :59439 )') ]] || exit 2
unset PGSERVICE PGSERVICEFILE PGOPTIONS PGHOST PGHOSTADDR PGDATABASE PGUSER
unset RELEASE_SYS_CONFIG RELEASE_VM_ARGS ERL_AFLAGS
export PGPASSWORD=$(openssl rand -hex 24)
"$pg/initdb" -D "$dir/data" -U postgres --locale=C.UTF-8 --encoding=UTF8 \
  --auth-local=trust --auth-host=scram-sha-256 --pwfile=<(printf '%s\n' "$PGPASSWORD") >"$dir/init.log" 2>&1
started=true
"$pg/pg_ctl" -D "$dir/data" -l "$dir/postgres.log" -o "-h 127.0.0.1 -p 59434 -k ''" -w start >"$dir/start.log" 2>&1
"$pg/createdb" -h 127.0.0.1 -p 59434 -U postgres anime_release_test
sql() { "$pg/psql" -X -w -h 127.0.0.1 -p 59434 -U postgres -d anime_release_test -At -v ON_ERROR_STOP=1 -c "$1"; }
[[ $(sql 'SHOW data_directory') == "$dir/data" ]] || exit 1
sql "CREATE ROLE release_migrator LOGIN PASSWORD '$PGPASSWORD' NOSUPERUSER NOCREATEDB NOCREATEROLE; ALTER DATABASE anime_release_test OWNER TO release_migrator" >"$dir/role.log"
[[ $(sql "SELECT rolsuper OR rolcreatedb OR rolcreaterole FROM pg_roles WHERE rolname='release_migrator'") == f ]] || exit 1
export PATH=/usr/bin:/bin ERL_FLAGS='+S 2:2' APP_ENV=dev NODE_ROLE=web
export RELEASE_COOKIE=SyntheticReleaseDatabaseCookieOnly123456789 RELEASE_DISTRIBUTION=none
export RELEASE_TMP="$dir/runtime" PHX_SERVER=false PHX_HOST=localhost PORT=4100 METRICS_PORT=9568
mkdir -m 700 "$RELEASE_TMP"
export SECRET_KEY_BASE=SyntheticReleaseDatabaseKeyOnly123456789012345678901234567890123456789
export LIVE_VIEW_SIGNING_SALT=SyntheticReleaseDatabaseSaltOnly123456789
# Deliberately unusable ordinary connection. Commands must use only migration URL.
export DATABASE_URL=ecto://nobody:synthetic@127.0.0.1:59499/not_used DATABASE_SSL=false POOL_SIZE=2
export MIGRATION_DATABASE_URL="ecto://release_migrator:$PGPASSWORD@127.0.0.1:59434/anime_release_test"
export MINIO_ENDPOINT=http://127.0.0.1:9000 MINIO_PUBLIC_URL=http://localhost:9000
export MINIO_ACCESS_KEY_ID=synthetic MINIO_SECRET_ACCESS_KEY=synthetic MINIO_REGION=us-east-1
export MAIL_ADAPTER=local TZ=UTC TRUSTED_PROXIES='' LOG_LEVEL=info
check() { "$package/bin/anime" eval "$2" >"$dir/$1.log" 2>&1; }
check missing-url 'System.delete_env("MIGRATION_DATABASE_URL"); try do Anime.Release.migrate(); raise "accepted missing URL" rescue e in ArgumentError -> true = String.contains?(Exception.message(e), "MIGRATION_DATABASE_URL") end'
check up '47 = length(Anime.Release.migrate()); nil = Process.whereis(Anime.Supervisor); nil = Process.whereis(Anime.Release.MigrationRepo)'
[[ $(sql 'SELECT count(*) FROM schema_migrations') == 47 ]] || exit 1
"$pg/pg_dump" -h 127.0.0.1 -p 59434 -U postgres -d anime_release_test --schema-only --no-owner --no-privileges --restrict-key=ReleaseCheck >"$dir/first.sql"
check noop '[] = Anime.Release.migrate()'
target=$(sql 'SELECT version FROM schema_migrations ORDER BY version DESC OFFSET 1 LIMIT 1')
[[ $target =~ ^[0-9]+$ ]] || exit 1
check down-one "1 = length(Anime.Release.rollback(Anime.Repo, $target))"
[[ $(sql 'SELECT count(*) FROM schema_migrations') == 46 ]] || exit 1
check restore-one '1 = length(Anime.Release.migrate())'
check down '47 = length(Anime.Release.rollback(Anime.Repo, 0))'
[[ $(sql "SELECT string_agg(tablename, ',' ORDER BY tablename) FROM pg_tables WHERE schemaname='public'") == schema_migrations ]] || exit 1
check up-again '47 = length(Anime.Release.migrate())'
"$pg/pg_dump" -h 127.0.0.1 -p 59434 -U postgres -d anime_release_test --schema-only --no-owner --no-privileges --restrict-key=ReleaseCheck >"$dir/second.sql"
cmp "$dir/first.sql" "$dir/second.sql"
printf '%s\n' '47 migrations: release up/no-op/target rollback/restore/full down/up and identical schema passed; application not started.'

# Separate ordinary role: existing tables only, no DDL and no ownership.
sql "CREATE ROLE release_app LOGIN PASSWORD '$PGPASSWORD' NOSUPERUSER NOCREATEDB NOCREATEROLE;
GRANT CONNECT ON DATABASE anime_release_test TO release_app;
GRANT USAGE ON SCHEMA public TO release_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO release_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO release_app" >"$dir/app-role.log"
[[ $(sql "SELECT has_schema_privilege('release_app', 'public', 'CREATE')") == f ]] || exit 1
export DATABASE_URL="ecto://release_app:$PGPASSWORD@127.0.0.1:59434/anime_release_test"
unset MIGRATION_DATABASE_URL ADMIN_EMAIL ADMIN_NICK ADMIN_PASSWORD
check seed-missing 'try do Anime.Release.seed(); raise "accepted missing credentials" rescue e in ArgumentError -> true = String.contains?(Exception.message(e), "ADMIN_EMAIL") end; nil = Process.whereis(Anime.Repo)'
export ADMIN_EMAIL=release-owner@example.com ADMIN_NICK=release_owner
export ADMIN_PASSWORD="Release!$(openssl rand -hex 24)"
check seed-first '{:ok, :created} = Anime.Release.seed(); nil = Process.whereis(Anime.Supervisor); nil = Process.whereis(Anime.Repo); nil = Process.whereis(Anime.PubSub)'
[[ $(sql 'SELECT count(*) FROM users WHERE must_change_password AND email_confirmed_at IS NOT NULL') == 1 ]] || exit 1
[[ $(sql 'SELECT count(*) FROM roles') == 5 ]] || exit 1
[[ $(sql 'SELECT count(*) FROM permissions') == 99 ]] || exit 1
# An operator's revoked grant must not silently reappear after repeat seed.
sql "DELETE FROM role_permissions WHERE id=(SELECT rp.id FROM role_permissions rp JOIN roles r ON r.id=rp.role_id WHERE r.code='admin' ORDER BY rp.id LIMIT 1)" >"$dir/revoke.log"
snapshot() { sql "SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM $1 t"; }
for table in users roles permissions role_permissions settings audit_logs; do snapshot "$table"; done >"$dir/seed-first.json"
check seed-repeat '{:ok, :already_exists} = Anime.Release.seed()'
for table in users roles permissions role_permissions settings audit_logs; do snapshot "$table"; done >"$dir/seed-repeat.json"
cmp "$dir/seed-first.json" "$dir/seed-repeat.json"
unset ADMIN_EMAIL ADMIN_NICK ADMIN_PASSWORD
check oban-drain 'Code.eval_file("dev/oban_drain_smoke.exs")'

# Only our foreground process; refuse occupied ports, never stop another server.
export PORT=49137 METRICS_PORT=49568 MINIO_ENDPOINT=http://127.0.0.1:59498 MINIO_PUBLIC_URL=http://127.0.0.1:59498
[[ -z $(ss -H -ltn '( sport = :49137 or sport = :49568 )') ]] || exit 1
start_seconds=$SECONDS
"$package/bin/server" >"$dir/server.log" 2>&1 &
server_pid=$!
until curl --silent --fail --max-time 1 -H 'X-Forwarded-Proto: https' http://127.0.0.1:49137/healthz >"$dir/health.txt"; do
  kill -0 "$server_pid" 2>/dev/null || exit 1
  (( SECONDS - start_seconds < 15 )) || exit 1
  sleep 0.1
done
[[ $(<"$dir/health.txt") == ok ]] || exit 1
printf 'Health response within %ss\n' "$((SECONDS - start_seconds))" >"$dir/boot-time.log"
curl --silent --fail --max-time 5 -H 'X-Forwarded-Proto: https' http://127.0.0.1:49137/login >"$dir/login.html"
[[ $(<"$dir/login.html") == *'<form'* ]] || exit 1
ready_status=$(curl --silent --max-time 15 -o "$dir/ready.json" -w '%{http_code}' -H 'X-Forwarded-Proto: https' http://127.0.0.1:49137/readyz)
[[ $ready_status == 503 ]] || exit 1
[[ $(<"$dir/ready.json") == '{"failed":["storage"],"ready":false}' ]] || exit 1
printf '%s\n' 'Seed twice preserved rows and revoked grant; ordinary non-DDL role; health/login passed; readiness correctly refuses missing storage.'

if [[ -n $minio_bin ]]; then
  stop_app() {
    local begin=$SECONDS withdrawn=false
    kill -TERM "$server_pid"
    for _ in {1..30}; do
      if ready shutdown-withdrawal 503 '{"failed":["shutdown"],"ready":false}'; then withdrawn=true; break; fi
      sleep 0.1
    done
    [[ $withdrawn == true ]] || return 1
    for _ in {1..900}; do kill -0 "$server_pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$server_pid" 2>/dev/null; then return 1; fi
    wait "$server_pid"
    server_pid=''
    (( SECONDS - begin >= 10 && SECONDS - begin <= 90 )) || return 1
    [[ $(<"$dir/server.log") == *'"message":"Application stopped"'* ]]
  }
  start_app() {
    "$package/bin/server" >>"$dir/server.log" 2>&1 &
    server_pid=$!
    for _ in {1..150}; do
      kill -0 "$server_pid" 2>/dev/null || return 1
      if curl -sf --max-time 1 http://127.0.0.1:49137/healthz >"$dir/health.txt"; then break; fi
      sleep 0.1
    done
    [[ $(<"$dir/health.txt") == ok ]]
  }
  start_storage() {
    env -i PATH=/usr/bin:/bin HOME="$dir" MINIO_ROOT_USER="$MINIO_ACCESS_KEY_ID" \
      MINIO_ROOT_PASSWORD="$valid_storage_secret" MINIO_BROWSER=off \
      MINIO_API_STALE_UPLOADS_EXPIRY=24h MINIO_API_STALE_UPLOADS_CLEANUP_INTERVAL=6h \
      "$minio_bin" server "$dir/minio-data" --address 127.0.0.1:59438 --console-address 127.0.0.1:59439 >>"$dir/minio.log" 2>&1 &
    minio_pid=$!
    for _ in {1..100}; do
      kill -0 "$minio_pid" 2>/dev/null || return 1
      if curl -sf --max-time 1 http://127.0.0.1:59438/minio/health/live >/dev/null; then return 0; fi
      sleep 0.1
    done
    return 1
  }
  ready() {
    local label=$1 expected=$2 body=$3 status
    status=$(curl -s --max-time 15 -D "$dir/$label.headers" -o "$dir/$label.json" -w '%{http_code}' http://127.0.0.1:49137/readyz)
    [[ $status == "$expected" && $(<"$dir/$label.json") == "$body" ]] || return 1
    grep -qi '^cache-control:.*no-store' "$dir/$label.headers"
    [[ $(curl -sf --max-time 2 http://127.0.0.1:49137/healthz) == ok ]]
    printf 'PASS: %s (ready=%s, health=200)\n' "$label" "$status"
  }
  stop_app
  export MINIO_ENDPOINT=http://127.0.0.1:59438 MINIO_PUBLIC_URL=http://127.0.0.1:59438
  export MINIO_ACCESS_KEY_ID="probe$(openssl rand -hex 8)"
  valid_storage_secret=$(openssl rand -hex 32)
  export MINIO_SECRET_ACCESS_KEY="$valid_storage_secret"
  start_storage
  check storage-setup '{:ok, names} = Anime.Release.storage_setup(); 5 = length(names)'
  start_app
  ready 1-storage-ready 200 '{"failed":[],"ready":true}'
  kill -TERM "$minio_pid"
  wait "$minio_pid"
  minio_pid=''
  sleep 11 # Storage readiness caches success and failure for ten seconds.
  ready 2-storage-outage 503 '{"failed":["storage"],"ready":false}'
  start_storage
  sleep 11
  ready 3-storage-recovered 200 '{"failed":[],"ready":true}'
  stop_app
  export MINIO_SECRET_ACCESS_KEY="WrongSyntheticKey$(openssl rand -hex 16)"
  start_app
  ready 4-invalid-storage-key 503 '{"failed":["storage"],"ready":false}'
  stop_app
  export MINIO_SECRET_ACCESS_KEY="$valid_storage_secret"
  start_app
  ready restored-key 200 '{"failed":[],"ready":true}'
  "$pg/pg_ctl" -D "$dir/data" -m fast -w stop >"$dir/db-outage.log" 2>&1
  started=false
  ready 5-database-outage 503 '{"failed":["database","migrations"],"ready":false}'
  shutdown_start=$SECONDS
  stop_app
  printf 'PASS: shutdown with database offline in %ss (web budget 90s)\n' "$((SECONDS - shutdown_start))"
  started=true
  "$pg/pg_ctl" -D "$dir/data" -l "$dir/postgres.log" -o "-h 127.0.0.1 -p 59434 -k ''" -w start >"$dir/db-recovery.log" 2>&1
  start_app
  recovered=false
  for _ in {1..10}; do
    if ready database-recovered 200 '{"failed":[],"ready":true}'; then recovered=true; break; fi
    sleep 1
  done
  [[ $recovered == true ]]
fi
