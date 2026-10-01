#!/usr/bin/env bash
# New isolated MinIO only. No pre-existing endpoint, data directory or credentials accepted.
set -Eeuo pipefail
[[ ($# == 2 || $# == 3 || $# == 4) && -x $1 && $2 == /tmp/anime-release-check.*/package && -x $2/bin/anime ]] || exit 2
nginx_bin=''
mc_bin=''
tls=${STORAGE_TEST_TLS:-0}
[[ $tls == 0 || ($tls == 1 && $# == 3) ]] || exit 2
if [[ $# -ge 3 ]]; then [[ -x $3 ]] || exit 2; nginx_bin=$(realpath "$3"); fi
if [[ $# == 4 ]]; then [[ -x $4 ]] || exit 2; mc_bin=$(realpath "$4"); fi
minio_bin=$(realpath "$1")
package=$(realpath "$2")
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
app_dir=$PWD
dir=$(mktemp -d /tmp/anime-storage-check.XXXXXXXX)
chmod 700 "$dir"
pid=''
nginx_pid=''
cleanup() {
  result=$?
  trap - EXIT
  if [[ -n $nginx_pid ]]; then
    kill -TERM "$nginx_pid" 2>/dev/null || true
    for _ in {1..50}; do kill -0 "$nginx_pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$nginx_pid" 2>/dev/null; then kill -KILL "$nginx_pid" 2>/dev/null || true; result=1; fi
    wait "$nginx_pid" 2>/dev/null || true
  fi
  if [[ -n $pid ]]; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in {1..50}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; result=1; fi
    wait "$pid" 2>/dev/null || true
  fi
  printf 'Storage check exit %s; evidence: %s\n' "$result" "$dir"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
[[ -z $(ss -H -ltn '( sport = :59438 or sport = :59439 or sport = :59440 or sport = :59441 )') ]] || exit 2
# env -i prevents unrelated MINIO_* settings from joining replication/KMS/etc.
export MINIO_ACCESS_KEY_ID="probe$(openssl rand -hex 8)"
export MINIO_SECRET_ACCESS_KEY=$(openssl rand -hex 32)
env -i PATH=/usr/bin:/bin HOME="$dir" MINIO_ROOT_USER="$MINIO_ACCESS_KEY_ID" \
  MINIO_ROOT_PASSWORD="$MINIO_SECRET_ACCESS_KEY" MINIO_BROWSER=off \
  MINIO_API_STALE_UPLOADS_EXPIRY=24h MINIO_API_STALE_UPLOADS_CLEANUP_INTERVAL=6h \
  "$minio_bin" server "$dir/data" --address 127.0.0.1:59438 --console-address 127.0.0.1:59439 >"$dir/minio.log" 2>&1 &
pid=$!
for _ in {1..100}; do
  kill -0 "$pid" 2>/dev/null || exit 1
  if curl -sf --max-time 1 http://127.0.0.1:59438/minio/health/live >/dev/null; then break; fi
  sleep 0.1
done
curl -sf --max-time 1 http://127.0.0.1:59438/minio/health/live >/dev/null
mkdir -m 700 "$dir/runtime"
probe='storage_smoke.exs'
if [[ -n $nginx_bin ]]; then
  if [[ $tls == 1 ]]; then
    bash dev/storage_tls_fixture.sh "$dir" >"$dir/cert-setup.log" 2>&1
  fi
  node dev/storage_proxy_config.mjs "$dir" "$tls"
  "$nginx_bin" -p "$dir" -c "$dir/nginx.conf" -t >"$dir/nginx-check.log" 2>&1
  "$nginx_bin" -p "$dir" -c "$dir/nginx.conf" -g 'daemon off;' >"$dir/nginx.log" 2>&1 &
  nginx_pid=$!
  for _ in {1..100}; do
    kill -0 "$nginx_pid" 2>/dev/null || exit 1
    if curl -s --max-time 1 http://127.0.0.1:59440/ >/dev/null; then break; fi
    sleep 0.1
  done
  probe='storage_proxy_smoke.exs'
  if [[ $tls == 1 ]]; then probe='storage_tls_smoke.exs'; fi
fi
if [[ -n $mc_bin ]]; then
  node dev/storage_iam_fixture.mjs "$dir" "$mc_bin" >"$dir/iam-setup.log" 2>&1
  probe='storage_iam_smoke.exs'
fi
env -i PATH=/usr/bin:/bin LANG=C.UTF-8 ERL_FLAGS='+S 2:2' RELEASE_DISTRIBUTION=none \
  STORAGE_FIXTURE_DIR="$dir" \
  RELEASE_COOKIE=SyntheticStorageProbeCookie123456789 RELEASE_TMP="$dir/runtime" \
  APP_ENV=dev NODE_ROLE=web PHX_SERVER=false PHX_HOST=localhost PORT=4100 METRICS_PORT=9568 \
  SECRET_KEY_BASE=SyntheticStorageKey123456789012345678901234567890123456789012345678901 \
  LIVE_VIEW_SIGNING_SALT=SyntheticStorageSalt1234567890123456789 \
  DATABASE_URL=ecto://unused:synthetic@127.0.0.1:59499/unused DATABASE_SSL=false \
  MINIO_ENDPOINT=http://127.0.0.1:59438 MINIO_PUBLIC_URL=http://127.0.0.1:59438 \
  MINIO_REGION=us-east-1 MINIO_ACCESS_KEY_ID="$MINIO_ACCESS_KEY_ID" MINIO_SECRET_ACCESS_KEY="$MINIO_SECRET_ACCESS_KEY" \
  "$package/bin/anime" eval "Code.eval_file(\"$app_dir/dev/$probe\")" >"$dir/check.log" 2>&1
printf '%s\n' 'Real isolated MinIO checks passed; no application or database started.'
