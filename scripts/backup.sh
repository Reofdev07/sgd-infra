#!/bin/bash
# scripts/backup.sh — Backup de Postgres (pg_dump -Fc) + storage Laravel + data OSAI
# Ejecutar desde sgd-infra/ vía cron
set -e

# Trabajar siempre desde sgd-infra/ (lanzado desde otra carpeta no encontraba el compose ni el .env
# y reportaba todo caído).
cd "$(dirname "$0")/.." || exit 1

# Cargar .env si existe (ENV_FILE permite otro archivo; lo usa scripts/tests/postgres-scripts.test.sh)
ENV_FILE="${ENV_FILE:-.env}"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
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
# 1. Base de datos — Postgres con pg_dump (formato custom, se restaura con pg_restore)
# ============================================
echo ""
echo "--- Base de datos (Postgres) ---"
if [ "${BACKUP_DRY_RUN:-0}" = "1" ]; then
    # Modo seco (scripts/tests/postgres-scripts.test.sh): solo informa el método, no toca contenedores.
    echo "metodo=pg_dump"
    exit 0
fi
DUMPFILE="sgd_backup_${DATE}.pgdump"
echo "Exportando con pg_dump -Fc (base ${POSTGRES_DB:-sgd})..."
docker compose exec -T postgres pg_dump -U "${POSTGRES_USER:-sgd}" -d "${POSTGRES_DB:-sgd}" -Fc > "$BACKUP_DIR/$DUMPFILE" || {
    echo "ERROR: pg_dump falló."
    rm -f "$BACKUP_DIR/$DUMPFILE"
    exit 1
}
echo "Postgres backup: $(ls -lh "$BACKUP_DIR/$DUMPFILE" | awk '{print $5}')"

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
for f in "$BACKUP_DIR"/*.pgdump "$BACKUP_DIR"/*.tar.gz "$BACKUP_DIR"/*.log; do
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
    # SGD-096: solo desde .env (backup.sh ya lo carga completo al inicio).
    TOKEN="${TELEGRAM_BOT_TOKEN:-}"
    CHAT="${TELEGRAM_CHAT_ID:-}"
    if [ -z "$TOKEN" ] || [ -z "$CHAT" ]; then
        echo "AVISO: faltan TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID en .env; alerta de offsite no enviada."
    else
        curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
            -d "chat_id=$CHAT" \
            -d "text=⚠️ *SGD BACKUP*: copia offsite NO completada. Revisar logs." \
            -d "parse_mode=Markdown" > /dev/null 2>&1
    fi
fi
