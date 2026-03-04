# Konfiguration
BACKUP_ROOT="/home/dev/backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
PROJECT_DIR="/home/dev/local-ai-packaged"
COMPOSE_PROJECT="localai"  # Dein Projektname aus -p localai
PROFILE="cpu"  # Dein genutztes Profil
MAX_BACKUPS=1  # Behalte nur die letzten 1  Backups

# Logging
LOG_FILE="${BACKUP_ROOT}/backup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "Backup gestartet: $(date)"
echo "=========================================="

# Prüfe Mindest-Freiheit von 20GB
FREE=$(df --output=avail -BG / | tail -n1 | sed 's/G//')
if [ "$FREE" -lt 20 ]; then
    echo "Abbruch: Zu wenig Speicherplatz frei (${FREE}GB). Backup wird nicht gestartet."
    exit 1
fi

# Backup-Verzeichnis erstellen
mkdir -p "$BACKUP_DIR"
cd "$PROJECT_DIR"

# 1. Container stoppen mit deinem down-Befehl
echo "Stoppe Container mit down..."
docker compose -p localai -f docker-compose.yml --profile cpu down
sleep 30

# 2. PostgreSQL Dump (starte nur Postgres temporär)
echo "Erstelle PostgreSQL Backup..."
docker compose -p localai -f docker-compose.yml up -d postgres
sleep 30
docker exec postgres pg_dumpall -U postgres > "$BACKUP_DIR/postgres_dump.sql"
docker compose -p localai -f docker-compose.yml stop postgres
docker compose -p localai -f docker-compose.yml rm -f postgres

# 3. ClickHouse Backup
echo "Erstelle ClickHouse Backup..."
docker run --rm \
    -v ${COMPOSE_PROJECT}_langfuse_clickhouse_data:/data:ro \
    -v "$BACKUP_DIR":/backup \
    alpine tar czf /backup/clickhouse_data.tar.gz -C /data .

# 4. Named Volumes sichern
VOLUMES=(
    "n8n_data"
    "ollama_storage"
    "qdrant_storage"
    "open-webui"
    "flowise"
    "valkey-data"
    "langfuse_postgres_data"
    "langfuse_clickhouse_logs"
    "langfuse_minio_data"
    "caddy-data"
    "caddy-config"
)

echo "Sichere Docker Volumes..."
for VOLUME in "${VOLUMES[@]}"; do
    echo "  - Backup von Volume: $VOLUME"
    docker run --rm \
        -v "${COMPOSE_PROJECT}_${VOLUME}:/data:ro" \
        -v "$BACKUP_DIR":/backup \
        alpine tar czf "/backup/${VOLUME}.tar.gz" -C /data . 2>/dev/null
    
    # Falls Volume nicht existiert oder leer ist
    if [ $? -ne 0 ]; then
        echo "    Warnung: Volume $VOLUME konnte nicht gesichert werden"
    fi
done

# 5. Bind-Mount Verzeichnisse sichern
echo "Sichere Bind-Mount Verzeichnisse..."
if [ -d "./neo4j" ]; then
    tar czf "$BACKUP_DIR/neo4j.tar.gz" -C . neo4j
fi

if [ -d "./searxng" ]; then
    tar czf "$BACKUP_DIR/searxng.tar.gz" -C . searxng
fi

if [ -d "./n8n/backup" ]; then
    tar czf "$BACKUP_DIR/n8n_backup.tar.gz" -C . n8n/backup
fi

if [ -d "./shared" ]; then
    tar czf "$BACKUP_DIR/shared.tar.gz" -C . shared
fi

if [ -d "$HOME/.flowise" ]; then
    tar czf "$BACKUP_DIR/flowise_home.tar.gz" -C "$HOME" .flowise
fi

if [ -f "./Caddyfile" ]; then
    cp ./Caddyfile "$BACKUP_DIR/"
fi

if [ -d "./caddy-addon" ]; then
    tar czf "$BACKUP_DIR/caddy-addon.tar.gz" -C . caddy-addon
fi

# 6. Supabase sichern
if [ -d "./supabase" ]; then
    tar czf "$BACKUP_DIR/supabase.tar.gz" -C . supabase
fi

# 7. Konfigurationsdateien sichern
echo "Sichere Konfigurationsdateien..."
cp docker-compose.yml "$BACKUP_DIR/"
if [ -f ".env" ]; then
    cp .env "$BACKUP_DIR/"
fi

# 8. Python Start-Skript sichern
if [ -f "start_services.py" ]; then
    cp start_services.py "$BACKUP_DIR/"
fi

# 9. Container mit deinem Python-Skript neu starten
echo "Starte Container mit Python-Skript neu..."
if [ -f "start_services.py" ]; then
    python3 start_services.py --profile cpu
else
    echo "WARNUNG: start_services.py nicht gefunden, starte mit docker compose..."
    docker compose -p localai -f docker-compose.yml --profile cpu up -d
fi

# Warte bis Container laufen
sleep 30

# Prüfe ob Container laufen
RUNNING_CONTAINERS=$(docker ps --filter "label=com.docker.compose.project=localai" --format "{{.Names}}" | wc -l)
echo "Anzahl laufender Container: $RUNNING_CONTAINERS"

# 10. Backup komprimieren
echo "Komprimiere gesamtes Backup..."
cd "$BACKUP_ROOT"
tar czf "${TIMESTAMP}.tar.gz" "$TIMESTAMP"
rm -rf "$TIMESTAMP"


# 11. Alte Backups rotieren und hängen­gebliebene Ordner löschen
echo "Räume alte Backups auf..."
ls -t "${BACKUP_ROOT}"/*.tar.gz | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm

echo "Bereinige alte Backup-Ordner..."
find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -name "20*" -mtime +1 -exec rm -rf {} \;

# Backup-Größe anzeigen
BACKUP_SIZE=$(du -h "${BACKUP_ROOT}/${TIMESTAMP}.tar.gz" | cut -f1)
echo "Backup abgeschlossen: ${TIMESTAMP}.tar.gz (${BACKUP_SIZE})"
echo "Gespeichert in: ${BACKUP_ROOT}/${TIMESTAMP}.tar.gz"
echo "=========================================="
echo "Backup beendet: $(date)"
echo "=========================================="
