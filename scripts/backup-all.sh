#!/usr/bin/env bash
set -euo pipefail

BACKUP_ROOT=/srv/backups
KEEP_RUNS=3
STAMP=$(date -u +%Y%m%d-%H%M%S)
TARGET="$BACKUP_ROOT/$STAMP"
DOCKER_VOLUMES=/var/lib/docker/volumes
CONFIG_VOLUMES=(
  n8n_data
  localai_db-config
  localai_langfuse_minio_data
  localai_langfuse_clickhouse_data
  localai_caddy-data
  localai_caddy-config
  localai_valkey-data
  local-ai-packaged_vane-data
  merch-miner_caddy_data
  merch-miner_caddy_config
)

tar_live() { ionice -c3 nice -n 19 tar --warning=no-file-changed --warning=no-file-removed "$@" || [ $? -eq 1 ]; }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
fail() { log "FAILED: $*"; touch "$TARGET/FAILED"; exit 1; }
trap 'fail "line $LINENO"' ERR

mkdir -p "$TARGET/db" "$TARGET/volumes" "$TARGET/config"
log "backup to $TARGET"

log "supabase-db globals"
docker exec supabase-db pg_dumpall -U postgres --globals-only > "$TARGET/db/supabase-globals.sql"
for db in postgres _supabase; do
  log "supabase-db $db"
  docker exec supabase-db pg_dump -U postgres -d "$db" -Fc -Z 6 > "$TARGET/db/supabase-$db.dump"
done
log "langfuse postgres"
docker exec localai-postgres-1 pg_dump -U postgres -d postgres -Fc -Z 6 > "$TARGET/db/langfuse-postgres.dump"

verify_dump() { docker exec -i "$1" pg_restore --list < "$2" > /dev/null || fail "unreadable $2"; }
verify_dump supabase-db "$TARGET/db/supabase-postgres.dump"
verify_dump supabase-db "$TARGET/db/supabase-_supabase.dump"
verify_dump localai-postgres-1 "$TARGET/db/langfuse-postgres.dump"

for volume in "${CONFIG_VOLUMES[@]}"; do
  log "volume $volume"
  tar_live -C "$DOCKER_VOLUMES/$volume/_data" -czf "$TARGET/volumes/$volume.tgz" .
done

log "config local-ai-packaged"
tar_live -C /srv -czf "$TARGET/config/local-ai-packaged.tgz" \
  --exclude=local-ai-packaged/supabase/docker/volumes/db/data local-ai-packaged
log "config merch-miner"
tar_live -C /srv -czf "$TARGET/config/merch-miner.tgz" \
  --exclude=merch-miner/backups --exclude=node_modules merch-miner

log "media"
PREVIOUS_MEDIA=$(ls -1d "$BACKUP_ROOT"/*/media 2>/dev/null | grep -v "$STAMP" | tail -n 1 || true)
LINK_DEST=()
[ -n "$PREVIOUS_MEDIA" ] && LINK_DEST=(--link-dest="$PREVIOUS_MEDIA")
ionice -c3 nice -n 19 rsync -a "${LINK_DEST[@]}" "$DOCKER_VOLUMES/merch-miner_media_volume/_data/" "$TARGET/media/"

(cd "$TARGET" && find db volumes config -type f -exec sha256sum {} + > SHA256SUMS)
du -sh "$TARGET"/* > "$TARGET/SIZES"
touch "$TARGET/COMPLETE"
log "done: $(du -sh "$TARGET" | cut -f1)"

ls -1d "$BACKUP_ROOT"/2* | head -n -"$KEEP_RUNS" | while read -r old_run; do
  log "remove old run $old_run"
  rm -rf "$old_run"
done
