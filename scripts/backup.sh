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

# Una sola ejecución a la vez: dos corridas simultáneas generan los mismos nombres de archivo
# y el tar del storage falla (pasó el 27 y 28/09/2026 con una entrada duplicada en el cron de root).
exec 9>"$BACKUP_DIR/.backup.lock"
if ! flock -n 9; then
    echo "=== Backup SGD omitido $(date): ya hay otro backup en curso ==="
    exit 0
fi

echo "=== Backup SGD $(date) ==="
echo "Usando compose file: $COMPOSE_FILE"

# ============================================
# 1. Oracle — export con expdp (data pump)
# ============================================
echo ""
echo "--- Oracle ---"

# Password del usuario SYSTEM de Oracle desde entorno (no hardcodeada)
SYSTEM_PASSWORD="${ORACLE_SYSTEM_PASSWORD:-}"
if [ -z "$SYSTEM_PASSWORD" ]; then
    echo "ERROR: Falta ORACLE_SYSTEM_PASSWORD en .env (password del usuario SYSTEM de Oracle)"
    exit 1
fi

# Obtener ruta real de DATA_PUMP_DIR (tiene sufijo aleatorio por BD)
DP_SQL="/tmp/get_dpdir_$$.sql"
cat > "$DP_SQL" << SQLEOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT directory_path FROM dba_directories WHERE directory_name = 'DATA_PUMP_DIR';
EXIT
SQLEOF
docker compose cp "$DP_SQL" oracle-xe:/tmp/get_dpdir.sql
rm -f "$DP_SQL"

DPDIR=$(docker compose exec -T oracle-xe sqlplus -S "SYSTEM/${SYSTEM_PASSWORD}@localhost/XEPDB1" @/tmp/get_dpdir.sql 2>/dev/null | grep -E '^/' | head -1 | xargs)
docker compose exec -T --user root oracle-xe rm -f /tmp/get_dpdir.sql 2>/dev/null || true

if [ -z "$DPDIR" ]; then
    echo "ERROR: No se pudo obtener DATA_PUMP_DIR"
    exit 1
fi
echo "DATA_PUMP_DIR: $DPDIR"

# Auto-reparación: refrescar el directorio dedicado SGD_DUMP con el path actual
# y garantizar permisos de SGD_MR7 (sobrevive a recreaciones del contenedor / cambios de GUID)
FIX_SQL="/tmp/fix_sgd_dump_$$.sql"
cat > "$FIX_SQL" << FIXEOF
CREATE OR REPLACE DIRECTORY SGD_DUMP AS '${DPDIR}';
GRANT READ, WRITE ON DIRECTORY SGD_DUMP TO ${DB_USERNAME:-SGD_MR7};
EXIT
FIXEOF
docker compose cp "$FIX_SQL" oracle-xe:/tmp/fix_sgd_dump.sql
docker compose exec -T oracle-xe sqlplus -S "SYSTEM/${SYSTEM_PASSWORD}@localhost/XEPDB1" @/tmp/fix_sgd_dump.sql > /dev/null 2>&1 || echo "WARN: no se pudo refrescar SGD_DUMP"
docker compose exec -T --user root oracle-xe rm -f /tmp/fix_sgd_dump.sql 2>/dev/null || true
rm -f "$FIX_SQL"

DUMPFILE="sgd_backup_${DATE}.dmp"
LOGFILE="sgd_backup_${DATE}.log"

echo "Exportando con expdp (esquema ${DB_USERNAME:-SGD_MR7})..."
docker compose exec -T oracle-xe expdp "\"${DB_USERNAME:-SGD_MR7}/${DB_PASSWORD:-sgd123}@localhost/XEPDB1\"" \
    directory=SGD_DUMP dumpfile="$DUMPFILE" logfile="$LOGFILE" \
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
# 2. Storage de Laravel (volumen real app_storage)
# ============================================
echo ""
echo "--- Laravel storage ---"
LARAVEL_BACKUP="laravel_storage_${DATE}.tar.gz"

# El volumen app_storage se monta ENCIMA de /var/www/html/storage: hay que
# leerlo desde dentro del contenedor, no desde el bind del host (que solo
# tiene el esqueleto versionado). Se excluyen los logs: son rotables y
# representan ~99% del tamaño, pero no hacen falta para restaurar.
if docker compose ps app 2>/dev/null | grep -q 'Up'; then
    docker compose exec -T app tar czf - \
        --exclude='./logs/*' \
        -C /var/www/html/storage . 2>/dev/null > "$BACKUP_DIR/$LARAVEL_BACKUP" || {
        echo "ERROR: backup de storage falló."
        exit 1
    }
    echo "Laravel backup: $(ls -lh "$BACKUP_DIR/$LARAVEL_BACKUP" | awk '{print $5}')"
else
    echo "ERROR: el contenedor app no está corriendo, no se puede respaldar el storage."
    exit 1
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
# 4. Copia offsite cifrada (restic → object storage S3-compatible)
# ============================================
echo ""
echo "--- Offsite (restic) ---"

if [ -z "${RESTIC_REPOSITORY:-}" ] || [ -z "${RESTIC_PASSWORD:-}" ]; then
    echo "WARN: faltan RESTIC_REPOSITORY / RESTIC_PASSWORD en .env — no hay copia offsite."
    OFFSITE_OK=0
else
    if restic backup "$BACKUP_DIR" \
        --tag sgd --tag automated \
        --exclude "*.log" \
        --host sgd-vps 2>&1 | tail -5; then
        echo "Offsite OK"
        OFFSITE_OK=1

        # Retención remota: 7 diarios, 4 semanales, 6 mensuales.
        restic forget --tag sgd \
            --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
            --prune 2>&1 | tail -3
    else
        echo "ERROR: restic backup falló."
        OFFSITE_OK=0
    fi
fi

# ============================================
# 5. Limpiar backups antiguos (>7 días)
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

# Alerta si el offsite falló
if [ "${OFFSITE_OK:-0}" -ne 1 ]; then
    TOKEN="${TELEGRAM_BOT_TOKEN:-8706852433:AAF6KVl9fzbehgmJrClbntquTwAdXen7r_U}"
    CHAT="${TELEGRAM_CHAT_ID:-5096050646}"
    if [ -n "$TOKEN" ] && [ -n "$CHAT" ]; then
        curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
            -d "chat_id=$CHAT" \
            -d "text=⚠️ *SGD BACKUP*: copia offsite NO completada. Revisar logs." \
            -d "parse_mode=Markdown" > /dev/null 2>&1
    fi
fi
