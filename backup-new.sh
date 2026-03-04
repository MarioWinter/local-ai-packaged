#!/bin/bash

# ==========================================
# Optimiertes Backup-Skript v2.1
# Fokus auf essentielle Daten
# ==========================================

# Konfiguration
BACKUP_ROOT="/home/dev/backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
PROJECT_DIR="/home/dev/local-ai-packaged"
COMPOSE_PROJECT="localai"
PROFILE="cpu"
MAX_BACKUPS=2

# Logging
LOG_FILE="${BACKUP_ROOT}/backup.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=========================================="
echo "Backup gestartet: $(date)"
echo "=========================================="

# Prüfe Mindest-Speicherplatz von 10GB
FREE=$(df --output=avail -BG / | tail -n1 | sed 's/G//')
if [ "$FREE" -lt 10 ]; then
    echo "❌ Abbruch: Zu wenig Speicherplatz frei (${FREE}GB). Minimum: 10GB"
    exit 1
fi

# Backup-Verzeichnis erstellen
mkdir -p "$BACKUP_DIR"
cd "$PROJECT_DIR"

# Funktion zur Prüfung ob Volume existiert
volume_exists() {
    docker volume ls -f name="${COMPOSE_PROJECT}_${1}" --format "{{.Name}}" | grep -q "^${COMPOSE_PROJECT}_${1}$"
}

# Funktion für erfolgreiche Backups
log_success() {
    local item=$1
    local size=$2
    echo "  ✓ $item gesichert${size:+ ($size)}"
}

# Funktion für Warnungen
log_warning() {
    local item=$1
    echo "  ⚠ $item nicht gefunden oder leer, überspringe"
}

# ==========================================
# 1. Container stoppen
# ==========================================
echo ""
echo "🛑 Stoppe Container..."
docker compose -p "$COMPOSE_PROJECT" -f docker-compose.yml --profile "$PROFILE" down
sleep 15

# ==========================================
# 2. PostgreSQL Dump (KRITISCH!)
# ==========================================
echo ""
echo "🗄️  Erstelle PostgreSQL Backup..."
docker compose -p "$COMPOSE_PROJECT" -f docker-compose.yml up -d postgres
sleep 20

# Warte bis PostgreSQL bereit ist
echo "  Warte auf PostgreSQL..."
for i in {1..30}; do
    if docker exec postgres pg_isready -U postgres > /dev/null 2>&1; then
        echo "  PostgreSQL ist bereit"
        break
    fi
    sleep 2
done

# Erstelle vollständigen Dump (alle DBs inkl. Rollen)
docker exec postgres pg_dumpall -U postgres > "$BACKUP_DIR/postgres_dump.sql"

if [ $? -eq 0 ] && [ -s "$BACKUP_DIR/postgres_dump.sql" ]; then
    SIZE=$(du -h "$BACKUP_DIR/postgres_dump.sql" | cut -f1)
    log_success "PostgreSQL Dump (pg_dumpall)" "$SIZE"
else
    echo "  ❌ FEHLER: PostgreSQL Dump fehlgeschlagen oder leer"
fi

docker compose -p "$COMPOSE_PROJECT" -f docker-compose.yml stop postgres
docker compose -p "$COMPOSE_PROJECT" -f docker-compose.yml rm -f postgres

# ==========================================
# 3. Essentielle Named Volumes
# ==========================================
echo ""
echo "💾 Sichere essentielle Docker Volumes..."

ESSENTIAL_VOLUMES=(
    "n8n_data"                    # Workflows, Credentials, Executions
    "langfuse_postgres_data"      # Langfuse Datenbank (für zukünftige Nutzung)
)

for VOLUME in "${ESSENTIAL_VOLUMES[@]}"; do
    if volume_exists "$VOLUME"; then
        echo "  📦 Backup von Volume: $VOLUME"
        docker run --rm \
            -v "${COMPOSE_PROJECT}_${VOLUME}:/data:ro" \
            -v "$BACKUP_DIR":/backup \
            alpine tar czf "/backup/${VOLUME}.tar.gz" -C /data .
        
        if [ $? -eq 0 ]; then
            SIZE=$(du -h "$BACKUP_DIR/${VOLUME}.tar.gz" | cut -f1)
            log_success "$VOLUME" "$SIZE"
        else
            echo "    ❌ FEHLER beim Sichern von $VOLUME"
        fi
    else
        log_warning "$VOLUME (Volume existiert nicht)"
    fi
done

# ==========================================
# 4. Konfigurationsdateien (KRITISCH!)
# ==========================================
echo ""
echo "📄 Sichere Konfigurationsdateien..."

# Hauptkonfigurationsdateien
MAIN_CONFIGS=(
    "docker-compose.yml"
    "docker-compose.override.private.yml"
    "docker-compose.override.public.yml"
    "docker-compose.override.public.supabase.yml"
    ".env"
    ".env.example"
    "Caddyfile"
    "start_services.py"
    "restore.sh"
    "n8n_pipe.py"
    "Local_RAG_AI_Agent_n8n_Workflow.json"
)

for CONFIG in "${MAIN_CONFIGS[@]}"; do
    if [ -f "./$CONFIG" ]; then
        cp "./$CONFIG" "$BACKUP_DIR/"
        log_success "$CONFIG"
    else
        log_warning "$CONFIG"
    fi
done

# ==========================================
# 5. Verzeichnisse mit Konfigurationen
# ==========================================
echo ""
echo "📁 Sichere Konfigurationsverzeichnisse..."

# n8n/backup Verzeichnis
if [ -d "./n8n/backup" ]; then
    tar czf "$BACKUP_DIR/n8n_backup.tar.gz" -C . n8n/backup
    SIZE=$(du -h "$BACKUP_DIR/n8n_backup.tar.gz" | cut -f1)
    log_success "n8n/backup" "$SIZE"
else
    log_warning "n8n/backup Verzeichnis"
fi

# n8n-tool-workflows (falls vorhanden)
if [ -d "./n8n-tool-workflows" ] && [ "$(ls -A ./n8n-tool-workflows)" ]; then
    tar czf "$BACKUP_DIR/n8n_tool_workflows.tar.gz" -C . n8n-tool-workflows
    SIZE=$(du -h "$BACKUP_DIR/n8n_tool_workflows.tar.gz" | cut -f1)
    log_success "n8n-tool-workflows" "$SIZE"
else
    log_warning "n8n-tool-workflows"
fi

# Caddy-Addon
if [ -d "./caddy-addon" ] && [ "$(ls -A ./caddy-addon)" ]; then
    tar czf "$BACKUP_DIR/caddy-addon.tar.gz" -C . caddy-addon
    SIZE=$(du -h "$BACKUP_DIR/caddy-addon.tar.gz" | cut -f1)
    log_success "caddy-addon" "$SIZE"
else
    log_warning "caddy-addon"
fi

# SearXNG Konfiguration
if [ -d "./searxng" ]; then
    tar czf "$BACKUP_DIR/searxng_config.tar.gz" -C . searxng
    SIZE=$(du -h "$BACKUP_DIR/searxng_config.tar.gz" | cut -f1)
    log_success "searxng Konfiguration" "$SIZE"
else
    log_warning "searxng Konfiguration"
fi

# Neo4j (bind-mount Daten)
if [ -d "./neo4j" ]; then
    # Nur Config und wichtige Daten, keine Logs
    tar czf "$BACKUP_DIR/neo4j.tar.gz" \
        --exclude='./neo4j/logs/*' \
        -C . neo4j
    SIZE=$(du -h "$BACKUP_DIR/neo4j.tar.gz" | cut -f1)
    log_success "neo4j (ohne Logs)" "$SIZE"
else
    log_warning "neo4j"
fi

# Shared Verzeichnis
if [ -d "./shared" ] && [ "$(ls -A ./shared)" ]; then
    tar czf "$BACKUP_DIR/shared.tar.gz" -C . shared
    SIZE=$(du -h "$BACKUP_DIR/shared.tar.gz" | cut -f1)
    log_success "shared" "$SIZE"
else
    log_warning "shared"
fi

# Flowise Home-Verzeichnis (falls genutzt)
if [ -d "$HOME/.flowise" ] && [ "$(ls -A $HOME/.flowise)" ]; then
    tar czf "$BACKUP_DIR/flowise_home.tar.gz" -C "$HOME" .flowise
    SIZE=$(du -h "$BACKUP_DIR/flowise_home.tar.gz" | cut -f1)
    log_success "~/.flowise" "$SIZE"
else
    log_warning "~/.flowise (nicht genutzt)"
fi

# ==========================================
# 6. Supabase Konfiguration
# ==========================================
echo ""
echo "🔧 Sichere Supabase Konfiguration..."

if [ -d "./supabase/docker" ]; then
    # Nur die .env Datei von Supabase, nicht die ganzen Daten
    if [ -f "./supabase/docker/.env" ]; then
        mkdir -p "$BACKUP_DIR/supabase_config"
        cp "./supabase/docker/.env" "$BACKUP_DIR/supabase_config/"
        log_success "Supabase .env"
    fi
    
    # Falls es custom configs gibt
    if [ -f "./supabase/docker/docker-compose.yml" ]; then
        cp "./supabase/docker/docker-compose.yml" "$BACKUP_DIR/supabase_config/" 2>/dev/null
    fi
else
    log_warning "Supabase Konfiguration"
fi

# ==========================================
# 7. Backup-Info erstellen
# ==========================================
cat > "$BACKUP_DIR/backup_info.txt" << EOF
╔════════════════════════════════════════════════════════════════╗
║                     BACKUP INFORMATIONEN                       ║
╚════════════════════════════════════════════════════════════════╝

Erstellt am: $(date '+%d.%m.%Y um %H:%M:%S Uhr')
Hostname: $(hostname)
Docker Compose Projekt: $COMPOSE_PROJECT
Profil: $PROFILE
Script Version: 2.1 (optimiert für dein Setup)

────────────────────────────────────────────────────────────────
GESICHERTE KOMPONENTEN (KRITISCH FÜR RESTORE):
────────────────────────────────────────────────────────────────

✓ PostgreSQL Dump (pg_dumpall)
  → Alle Datenbanken inkl. n8n, Langfuse, Rollen, Berechtigungen
  
✓ n8n_data Volume
  → Workflows, Credentials, Execution History
  
✓ langfuse_postgres_data Volume
  → Langfuse Datenbank (für zukünftige Nutzung bereit)

✓ Alle docker-compose.yml Dateien
  → docker-compose.yml
  → docker-compose.override.*.yml (alle Varianten)
  
✓ Umgebungsvariablen
  → .env (Hauptkonfiguration)
  → .env.example
  
✓ Netzwerk & Proxy
  → Caddyfile (Reverse Proxy Config)
  → caddy-addon (Custom Configs)
  
✓ Python Start-Skript
  → start_services.py (Orchestrierung)
  
✓ Workflow-Definitionen
  → n8n/backup Verzeichnis
  → n8n-tool-workflows
  → Local_RAG_AI_Agent_n8n_Workflow.json
  
✓ Service-Konfigurationen
  → SearXNG Config (settings.yml)
  → Neo4j Config (ohne Logs)
  → Shared Daten
  → Flowise Home (~/.flowise falls genutzt)
  
✓ Supabase Konfiguration
  → .env und docker-compose.yml aus supabase/docker

────────────────────────────────────────────────────────────────
NICHT GESICHERT (können neu generiert/geladen werden):
────────────────────────────────────────────────────────────────

✗ ollama_storage (Modelle können neu heruntergeladen werden)
✗ qdrant_storage (noch nicht genutzt)
✗ open-webui (noch nicht genutzt)
✗ flowise Volume (noch nicht genutzt)
✗ valkey-data (Redis Cache, wird neu generiert)
✗ caddy-data & caddy-config (SSL-Zertifikate werden neu erstellt)
✗ langfuse_clickhouse_data & _logs (Analytics/Logs)
✗ langfuse_minio_data (S3-kompatible Storage für Langfuse)
✗ Supabase Volumes (zu groß, nur Config gesichert)

────────────────────────────────────────────────────────────────
RESTORE-ANLEITUNG:
────────────────────────────────────────────────────────────────

1. Projekt-Verzeichnis vorbereiten:
   cd /home/dev/local-ai-packaged
   
2. Backup entpacken:
   tar xzf ${TIMESTAMP}.tar.gz
   cd ${TIMESTAMP}

3. Konfigurationsdateien zurückspielen:
   cp *.yml ../.
   cp .env* ../.
   cp Caddyfile ../.
   cp *.py ../.
   cp *.sh ../.
   
4. Verzeichnisse wiederherstellen:
   cd ..
   tar xzf ${TIMESTAMP}/n8n_backup.tar.gz
   tar xzf ${TIMESTAMP}/caddy-addon.tar.gz
   tar xzf ${TIMESTAMP}/searxng_config.tar.gz
   tar xzf ${TIMESTAMP}/neo4j.tar.gz
   # etc.

5. Supabase Repository klonen (falls nicht vorhanden):
   # Wird automatisch von start_services.py gemacht
   
6. Volumes wiederherstellen:
   # n8n_data
   docker volume create n8n_data
   docker run --rm -v n8n_data:/data -v ${TIMESTAMP}:/backup alpine \\
     tar xzf /backup/n8n_data.tar.gz -C /data
   
   # langfuse_postgres_data (falls genutzt)
   docker volume create ${COMPOSE_PROJECT}_langfuse_postgres_data
   docker run --rm -v ${COMPOSE_PROJECT}_langfuse_postgres_data:/data \\
     -v ${TIMESTAMP}:/backup alpine \\
     tar xzf /backup/langfuse_postgres_data.tar.gz -C /data

7. Container starten:
   python3 start_services.py --profile cpu

8. PostgreSQL Dump einspielen (nach Start):
   # Warte bis PostgreSQL läuft (ca. 30 Sekunden)
   docker exec -i postgres psql -U postgres < ${TIMESTAMP}/postgres_dump.sql

9. Services prüfen:
   docker ps
   docker logs n8n
   docker logs postgres

────────────────────────────────────────────────────────────────
HINWEISE:
────────────────────────────────────────────────────────────────

• Ollama Modelle nach Restore neu laden:
  docker exec ollama ollama pull qwen2.5:7b-instruct-q4_K_M
  docker exec ollama ollama pull nomic-embed-text

• Caddy erstellt SSL-Zertifikate automatisch neu (Let's Encrypt)

• SearXNG Secret Key muss nicht neu generiert werden (in Config)

• Neo4j Daten ohne Logs gesichert (Logs zu groß und nicht kritisch)

• Langfuse: Falls du es später nutzt, sind Postgres-Daten bereits
  gesichert. ClickHouse & MinIO können neu initialisiert werden.

────────────────────────────────────────────────────────────────
SUPPORT:
────────────────────────────────────────────────────────────────

Bei Problemen:
1. Logs prüfen: ${BACKUP_ROOT}/backup.log
2. Container-Logs: docker logs <container-name>
3. Disk-Space: df -h

EOF

# ==========================================
# 8. Container neu starten
# ==========================================
echo ""
echo "🚀 Starte Container neu..."

if [ -f "start_services.py" ]; then
    python3 start_services.py --profile "$PROFILE"
else
    docker compose -p "$COMPOSE_PROJECT" -f docker-compose.yml --profile "$PROFILE" up -d
fi

sleep 25

# Prüfe laufende Container
RUNNING_CONTAINERS=$(docker ps --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" --format "{{.Names}}" | wc -l)
echo "  ℹ️  Anzahl laufender Container: $RUNNING_CONTAINERS"

# Zeige wichtigste Container
echo ""
echo "  Kritische Container-Status:"
docker ps --filter "name=n8n" --format "  ✓ {{.Names}} ({{.Status}})" 2>/dev/null || echo "  ⚠ n8n nicht gefunden"
docker ps --filter "name=postgres" --format "  ✓ {{.Names}} ({{.Status}})" 2>/dev/null || echo "  ⚠ postgres nicht gefunden"
docker ps --filter "name=caddy" --format "  ✓ {{.Names}} ({{.Status}})" 2>/dev/null || echo "  ⚠ caddy nicht gefunden"

# ==========================================
# 9. Backup komprimieren
# ==========================================
echo ""
echo "🗜️  Komprimiere Backup..."
cd "$BACKUP_ROOT"

tar czf "${TIMESTAMP}.tar.gz" "$TIMESTAMP"

if [ $? -eq 0 ]; then
    rm -rf "$TIMESTAMP"
    log_success "Backup komprimiert"
else
    echo "  ❌ FEHLER beim Komprimieren"
    exit 1
fi

# ==========================================
# 10. Alte Backups rotieren
# ==========================================
echo ""
echo "🧹 Räume alte Backups auf..."

BACKUP_COUNT=$(ls -1 "${BACKUP_ROOT}"/*.tar.gz 2>/dev/null | wc -l)

if [ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]; then
    ls -t "${BACKUP_ROOT}"/*.tar.gz | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm
    DELETED=$((BACKUP_COUNT - MAX_BACKUPS))
    echo "  ✓ $DELETED alte(s) Backup(s) gelöscht (behalte $MAX_BACKUPS)"
else
    echo "  ℹ️  Keine alten Backups zu löschen ($BACKUP_COUNT/$MAX_BACKUPS vorhanden)"
fi

# Bereinige hängengebliebene Ordner
ORPHANED=$(find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -name "20*" -mtime +0 2>/dev/null | wc -l)
if [ "$ORPHANED" -gt 0 ]; then
    find "$BACKUP_ROOT" -maxdepth 1 -mindepth 1 -type d -name "20*" -mtime +0 -exec rm -rf {} \; 2>/dev/null
    echo "  ✓ $ORPHANED hängengebliebene(s) Verzeichnis(se) bereinigt"
fi

# ==========================================
# 11. Abschluss und Zusammenfassung
# ==========================================
BACKUP_SIZE=$(du -h "${BACKUP_ROOT}/${TIMESTAMP}.tar.gz" 2>/dev/null | cut -f1)
TOTAL_BACKUPS=$(ls -1 "${BACKUP_ROOT}"/*.tar.gz 2>/dev/null | wc -l)
TOTAL_SIZE=$(du -sh "${BACKUP_ROOT}" | cut -f1)

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║           ✅ BACKUP ERFOLGREICH ABGESCHLOSSEN                  ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "  📦 Dateiname:      ${TIMESTAMP}.tar.gz"
echo "  📊 Backup-Größe:   ${BACKUP_SIZE}"
echo "  📁 Speicherort:    ${BACKUP_ROOT}/${TIMESTAMP}.tar.gz"
echo "  🔢 Gesamt Backups: ${TOTAL_BACKUPS}/${MAX_BACKUPS} (max)"
echo "  💾 Gesamtgröße:    ${TOTAL_SIZE}"
echo ""
echo "  📄 Detaillierte Infos: ${BACKUP_DIR}/backup_info.txt"
echo "       (nach Extraktion des .tar.gz verfügbar)"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Backup beendet: $(date '+%d.%m.%Y um %H:%M:%S Uhr')"
echo "════════════════════════════════════════════════════════════════"
