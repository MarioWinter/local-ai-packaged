#!/usr/bin/env bash
set -euo pipefail

KEEP_IMAGES=5
REPOS=(ghcr.io/mariowinter/merch-miner/backend ghcr.io/mariowinter/merch-miner/frontend)

log() { echo "[$(date -u +%F' '%H:%M:%S)] $*"; }

log "disk before: $(df -h / | awk 'NR==2 {print $5}')"
for repo in "${REPOS[@]}"; do
  docker images "$repo" --format '{{.CreatedAt}}|{{.Tag}}' | grep -v '|latest$' | sort -r \
    | tail -n +$((KEEP_IMAGES + 1)) | cut -d'|' -f2 \
    | while read -r tag; do docker rmi "$repo:$tag" > /dev/null 2>&1 && log "removed $repo:$tag" || true; done
done
docker image prune -f > /dev/null
docker builder prune -f --filter until=168h > /dev/null
log "disk after: $(df -h / | awk 'NR==2 {print $5}')"
