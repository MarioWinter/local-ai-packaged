#!/usr/bin/env bash
set -euo pipefail

RUN_DIR=${1:-$(ls -1d /srv/backups/2* | tail -n 1)}
CONTAINER=restore-test
VOLUME=restore-test-data
SCHEMAS=(merch_miner public)
IMAGE=$(docker inspect -f '{{.Config.Image}}' supabase-db)
REPORT="$RUN_DIR/RESTORE_TEST"

[ -f "$RUN_DIR/COMPLETE" ] || { echo "no complete backup in $RUN_DIR"; exit 1; }

cleanup() {
  docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
  docker volume rm "$VOLUME" > /dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

count_rows() {
  local container=$1
  local schema_list
  schema_list=$(printf "'%s'," "${SCHEMAS[@]}")
  docker exec -i "$container" psql -U postgres -d postgres -tA <<SQL | sort
select format('select %L || ''|'' || count(*) from %I.%I', n.nspname || '.' || c.relname, n.nspname, c.relname)
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relkind = 'r' and n.nspname in (${schema_list%,})
\gexec
SQL
}

echo "restore test of $RUN_DIR with $IMAGE"
docker run -d --name "$CONTAINER" --network none -e POSTGRES_PASSWORD=restore-test \
  -v "$VOLUME":/var/lib/postgresql/data "$IMAGE" > /dev/null
until docker exec "$CONTAINER" pg_isready -U postgres -h localhost > /dev/null 2>&1; do sleep 2; done
sleep 5

docker exec "$CONTAINER" psql -U postgres -d postgres -q -c \
  "create schema if not exists merch_miner; create extension if not exists vector schema merch_miner; create extension if not exists pg_trgm schema merch_miner; create extension if not exists unaccent schema merch_miner;"
docker cp "$RUN_DIR/db/supabase-postgres.dump" "$CONTAINER":/tmp/restore.dump

SCHEMA_ARGS=()
for schema in "${SCHEMAS[@]}"; do SCHEMA_ARGS+=(-n "$schema"); done
docker exec "$CONTAINER" pg_restore -U postgres -d postgres -j 4 --no-owner --no-privileges \
  "${SCHEMA_ARGS[@]}" /tmp/restore.dump 2> "$RUN_DIR/restore-errors.log" || true

count_rows supabase-db > "$RUN_DIR/rows-live.txt"
count_rows "$CONTAINER" > "$RUN_DIR/rows-restored.txt"

join -t'|' -a1 -e MISSING -o 0,1.2,2.2 "$RUN_DIR/rows-live.txt" "$RUN_DIR/rows-restored.txt" \
  | awk -F'|' '
      { tables++; live += $2; restored += ($3 == "MISSING" ? 0 : $3) }
      $3 == "MISSING" || ($2 > 0 && $3 == 0) || ($2 - $3) > 0.01 * $2 + 100 { bad++; print "MISMATCH " $0 }
      END { printf "tables=%d live_rows=%d restored_rows=%d mismatches=%d\n", tables, live, restored, bad + 0 }
    ' | tee "$REPORT"
echo "restore errors: $(grep -c 'error:' "$RUN_DIR/restore-errors.log" || true)" | tee -a "$REPORT"
