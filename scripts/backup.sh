#!/bin/bash
# scripts/backup.sh — Backup de Oracle + storage de Laravel
# Ejecutar desde sgd-infra/ vía cron
set -e

BACKUP_DIR="${BACKUP_DIR:-/home/deploy/backups}"
DATE=$(date +%Y%m%d_%H%M%S)
mkdir -p "$BACKUP_DIR"

echo "=== Backup SGD $(date) ==="

# 1. Oracle — export con expdp (data pump)
echo "Exportando Oracle..."
docker compose exec -T oracle-xe expdp ${DB_USERNAME:-SGD_MR7}/${DB_PASSWORD:-sgd123}@localhost/XEPDB1 \
    directory=DATA_PUMP_DIR dumpfile=sgd_backup_${DATE}.dmp logfile=sgd_backup_${DATE}.log

# Copiar el dump del contenedor al host
docker compose cp oracle-xe:/opt/oracle/admin/XE/dpdump/sgd_backup_${DATE}.dmp "$BACKUP_DIR/"
docker compose exec -T oracle-xe rm /opt/oracle/admin/XE/dpdump/sgd_backup_${DATE}.dmp
docker compose exec -T oracle-xe rm /opt/oracle/admin/XE/dpdump/sgd_backup_${DATE}.log 2>/dev/null || true

# 2. Storage de Laravel (uploads, logs, sesiones)
echo "Comprimiendo storage de Laravel..."
tar czf "$BACKUP_DIR/laravel_storage_${DATE}.tar.gz" -C "${LARAVEL_PATH:-../SDG-Back-api}" storage/

# 3. Data de OSAI (checkpoints, estado)
echo "Comprimiendo data de OSAI..."
docker compose exec -T osai tar czf - /app/data > "$BACKUP_DIR/osai_data_${DATE}.tar.gz"

# 4. Limpiar backups antiguos (mantener 7 días)
echo "Limpiando backups antiguos..."
find "$BACKUP_DIR" -name "*.dmp" -mtime +7 -delete
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +7 -delete

echo ""
echo "=== Backup completado: $BACKUP_DIR ==="
ls -lh "$BACKUP_DIR"/*${DATE}* 2>/dev/null
