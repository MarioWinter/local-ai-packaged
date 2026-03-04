#!/bin/bash

if [ -z "$1" ]; then
    echo "Verwendung: ./restore.sh <backup-timestamp>"
    echo "Beispiel: ./restore.sh 20251111_040000"
    exit 1
fi

BACKUP_ROOT="/home/dev/backups"
BACKUP_FILE="${BACKUP_ROOT}/${1}.tar.gz"
PROJECT_DIR="/home/dev/local-ai-packaged"

if [ ! -f "$BACKUP_FILE" ]; then
    echo "Backup nicht gefunden: $BACKUP_FILE"
    exit 1
fi

echo "Restore von: $BACKUP_FILE"
cd "$PROJECT_DIR"

# Container stoppen
docker compose down

# Backup entpacken
TEMP_DIR="${BACKUP_ROOT}/restore_temp"
mkdir -p "$TEMP_DIR"
tar xzf "$BACKUP_FILE" -C "$TEMP_DIR"

# PostgreSQL wiederherstellen
echo "Stelle PostgreSQL wieder her..."
docker compose up -d postgres
sleep 5
docker exec -i postgres psql -U postgres < "${TEMP_DIR}/${1}/postgres_dump.sql"
docker compose stop postgres

# Volumes wiederherstellen
for VOLUME in n8n_data ollama_storage qdrant_storage open-webui flowise valkey-data langfuse_postgres_data langfuse_clickhouse_logs langfuse_minio_data caddy-data caddy-config; do
    if [ -f "${TEMP_DIR}/${1}/${VOLUME}.tar.gz" ]; then
        echo "Stelle Volume wieder her: $VOLUME"
        docker run --rm \
            -v "local-ai-packaged_${VOLUME}:/data" \
            -v "${TEMP_DIR}/${1}":/backup \
            alpine sh -c "rm -rf /data/* /data/..?* /data/.[!.]* 2>/dev/null; tar xzf /backup/${VOLUME}.tar.gz -C /data"
    fi
done

# Bind-Mounts wiederherstellen
if [ -f "${TEMP_DIR}/${1}/neo4j.tar.gz" ]; then
    tar xzf "${TEMP_DIR}/${1}/neo4j.tar.gz" -C .
fi

# Container starten
docker compose up -d

# Aufräumen
rm -rf "$TEMP_DIR"

echo "Restore abgeschlossen!"
