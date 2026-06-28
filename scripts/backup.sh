#!/bin/bash
# scripts/backup.sh — Backup de Oracle + storage Laravel + data OSAI
# Ejecutar desde sgd-infra/ vía cron
set -e

# Cargar .env si existe
if [ -f .env ]; then
    set -a; source .env; set +a
fi

# Detectar compose activo
if [ -f docker-compose.dockploy.yml ]; then
  COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.dockploy.yml}"
else
  COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
fi
export COMPOSE_FILE

BACKUP_DIR="${BACKUP_DIR:-/home/deploy/backups}"
DATE=$(date +%Y%m%d_%H%M%S)
mkdir -p "$BACKUP_DIR"

echo "=== Backup SGD $(date) ==="
echo "Usando compose file: $COMPOSE_FILE"

# ============================================
# 1. Oracle — export con expdp (data pump)
# ============================================
echo ""
echo "--- Oracle ---"

# Obtener ruta real de DATA_PUMP_DIR (tiene sufijo aleatorio por BD)
DP_SQL="/tmp/get_dpdir_$$.sql"
cat > "$DP_SQL" << 'SQLEOF'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT directory_path FROM dba_directories WHERE directory_name = 'DATA_PUMP_DIR';
EXIT
SQLEOF
docker compose cp "$DP_SQL" oracle-xe:/tmp/get_dpdir.sql
rm -f "$DP_SQL"

DPDIR=$(docker compose exec -T oracle-xe sqlplus -S SYSTEM/StrongPassword123!@localhost/XEPDB1 @/tmp/get_dpdir.sql 2>/dev/null | grep -E '^/' | head -1 | xargs)
docker compose exec -T --user root oracle-xe rm -f /tmp/get_dpdir.sql 2>/dev/null || true

if [ -z "$DPDIR" ]; then
    echo "ERROR: No se pudo obtener DATA_PUMP_DIR"
    exit 1
fi
echo "DATA_PUMP_DIR: $DPDIR"

DUMPFILE="sgd_backup_${DATE}.dmp"
LOGFILE="sgd_backup_${DATE}.log"

echo "Exportando con expdp (esquema ${DB_USERNAME:-SGD_MR7})..."
docker compose exec -T oracle-xe expdp "\"${DB_USERNAME:-SGD_MR7}/${DB_PASSWORD:-sgd123}@localhost/XEPDB1\"" \
    directory=DATA_PUMP_DIR dumpfile="$DUMPFILE" logfile="$LOGFILE" \
    schemas="${DB_USERNAME:-SGD_MR7}" reuse_dumpfiles=y 2>&1 || {
    echo "ERROR: expdp falló."
    exit 1
}

# Copiar dump al host
echo "Copiando dump al host..."
docker compose cp "oracle-xe:$DPDIR/$DUMPFILE" "$BACKUP_DIR/"
docker compose cp "oracle-xe:$DPDIR/$LOGFILE" "$BACKUP_DIR/" 2>/dev/null || true

# Limpiar dentro del contenedor
docker compose exec -T --user root oracle-xe rm -f "$DPDIR/$DUMPFILE" "$DPDIR/$LOGFILE" 2>/dev/null || true

echo "Oracle backup: $(ls -lh "$BACKUP_DIR/$DUMPFILE" | awk '{print $5}')"

# ============================================
# 2. Storage de Laravel (uploads, logs, sesiones)
# ============================================
echo ""
echo "--- Laravel storage ---"
LARAVEL_DIR="${LARAVEL_PATH:-../SDG-Back-api}"
LARAVEL_BACKUP="laravel_storage_${DATE}.tar.gz"

if [ -d "$LARAVEL_DIR/storage" ]; then
    tar czf "$BACKUP_DIR/$LARAVEL_BACKUP" -C "$LARAVEL_DIR" storage/ 2>/dev/null
    echo "Laravel backup: $(ls -lh "$BACKUP_DIR/$LARAVEL_BACKUP" | awk '{print $5}')"
else
    echo "WARN: $LARAVEL_DIR/storage no existe, omitiendo."
fi

# ============================================
# 3. Data de OSAI (checkpoints, estado)
# ============================================
echo ""
echo "--- OSAI data ---"
OSAI_BACKUP="osai_data_${DATE}.tar.gz"

if docker compose ps osai 2>/dev/null | grep -q 'Up'; then
    docker compose exec -T osai tar czf - /app/data 2>/dev/null > "$BACKUP_DIR/$OSAI_BACKUP" || {
        echo "WARN: OSAI backup falló, continuando..."
    }
    echo "OSAI backup: $(ls -lh "$BACKUP_DIR/$OSAI_BACKUP" | awk '{print $5}')"
else
    echo "WARN: OSAI no está corriendo, omitiendo."
fi

# ============================================
# 4. Limpiar backups antiguos (>7 días)
# ============================================
echo ""
echo "--- Limpieza ---"
DELETED=0
for f in "$BACKUP_DIR"/*.dmp "$BACKUP_DIR"/*.tar.gz "$BACKUP_DIR"/*.log; do
    [ -f "$f" ] || continue
    if [ $(stat -c %Y "$f") -lt $(date -d '7 days ago' +%s) ]; then
        rm -f "$f"
        echo "Eliminado: $(basename "$f")"
        DELETED=$((DELETED + 1))
    fi
done
echo "$DELETED archivos antiguos eliminados."

# ============================================
echo ""
echo "=== Backup SGD completado: $(date) ==="
echo "Destino: $BACKUP_DIR"
ls -lh "$BACKUP_DIR"/*${DATE}* 2>/dev/null || echo "(sin archivos nuevos)"
