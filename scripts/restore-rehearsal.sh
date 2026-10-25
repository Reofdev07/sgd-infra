#!/bin/bash
# scripts/restore-rehearsal.sh — Simulacro de restauración (SGD-094)
#
# Restaura el dump de backup.sh en la base TEMPORAL sgd_restore_test del mismo servidor Postgres, compara el
# conteo exacto de filas tabla por tabla con la base real y borra la temporal. No modifica la base de producción.
# Uso: bash scripts/restore-rehearsal.sh [ruta/al/sgd_backup_AAAAMMDD_HHMMSS.pgdump]   (por defecto el más reciente)
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; source "${ENV_FILE:-.env}"; set +a

if [ -f docker-compose.dockploy.yml ]; then
  COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.dockploy.yml}"
else
  COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
fi
export COMPOSE_FILE

BACKUP_DIR="${BACKUP_DIR:-/home/deploy/backups}"

PG_USER="${POSTGRES_USER:-sgd}"
PG_DB="${POSTGRES_DB:-sgd}"
# Nombre fijo: es la ÚNICA base que este script crea y borra.
TEST_DB="sgd_restore_test"
[ "$PG_DB" != "$TEST_DB" ] || { echo "ERROR: la base de origen no puede ser $TEST_DB"; exit 1; }
DUMP_PATH="${1:-$(ls -1t "$BACKUP_DIR"/sgd_backup_*.pgdump | head -1)}"
[ -f "$DUMP_PATH" ] || { echo "ERROR: no existe $DUMP_PATH"; exit 1; }

psql_at() { docker compose exec -T postgres psql -U "$PG_USER" -d "$1" -At -v ON_ERROR_STOP=1 -c "$2"; }
# Filas exactas por tabla del esquema public: «tabla|filas».
conteos() {
    psql_at "$1" "SELECT table_name || '|' || (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM public.%I', table_name), false, true, '')))[1]::text
                  FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE' ORDER BY 1"
}

echo "=== Simulacro de restauración $(date) ==="
echo "Dump: $(basename "$DUMP_PATH") ($(du -h "$DUMP_PATH" | cut -f1)) → base temporal $TEST_DB"
trap 'echo "--- Limpieza ---"; docker compose exec -T postgres dropdb -U "$PG_USER" --if-exists "$TEST_DB" && echo "Base $TEST_DB eliminada"' EXIT

docker compose exec -T postgres dropdb -U "$PG_USER" --if-exists "$TEST_DB"
docker compose exec -T postgres createdb -U "$PG_USER" "$TEST_DB"
echo "--- pg_restore ---"
START=$(date +%s)
docker compose exec -T postgres pg_restore -U "$PG_USER" -d "$TEST_DB" --no-owner < "$DUMP_PATH" 2>&1 | tail -5 || true
echo "pg_restore terminó en $(( $(date +%s) - START )) s"

echo "--- Comparación de filas (exacta, tabla por tabla) ---"
PROD=$(mktemp); REST=$(mktemp)
conteos "$PG_DB" > "$PROD"
conteos "$TEST_DB" > "$REST"
awk -F'|' 'NR == FNR { r[$1] = $2; next }
    { total_src += $2
      if (!($1 in r)) { faltan++; print "FALTA  " $1 " (" $2 " filas en producción)"; next }
      total_dst += r[$1]
      if (r[$1] == $2) iguales++; else { distintas++; print "DIFIERE " $1 ": producción=" $2 " restaurado=" r[$1] } }
    END { printf "RESUMEN tablas_iguales=%d tablas_distintas=%d tablas_faltantes=%d filas_produccion=%d filas_restauradas=%d\n", iguales, distintas, faltan, total_src, total_dst }' "$REST" "$PROD"
rm -f "$PROD" "$REST"
echo "(Diferencias pequeñas en tablas con actividad desde la hora del dump son esperables.)"
