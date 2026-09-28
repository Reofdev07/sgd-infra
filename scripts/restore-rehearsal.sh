#!/bin/bash
# scripts/restore-rehearsal.sh — Simulacro de restauración de Oracle (SGD-094)
#
# Importa un dump de backup.sh en un esquema TEMPORAL (SGD_RESTORE_TEST) del mismo Oracle,
# compara el conteo exacto de filas tabla por tabla con el esquema real y borra el temporal.
# No modifica el esquema de producción. Uso:
#   bash scripts/restore-rehearsal.sh [ruta/al/sgd_backup_AAAAMMDD_HHMMSS.dmp]   (por defecto el más reciente)
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; source .env; set +a

if [ -f docker-compose.dockploy.yml ]; then
  COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.dockploy.yml}"
else
  COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
fi
export COMPOSE_FILE

SOURCE_SCHEMA="${DB_USERNAME:-SGD_MR7}"
# Nombre fijo: es el ÚNICO esquema que este script crea y borra.
TEST_SCHEMA="SGD_RESTORE_TEST"
if [ "${SOURCE_SCHEMA^^}" = "$TEST_SCHEMA" ]; then
    echo "ERROR: el esquema de origen no puede ser $TEST_SCHEMA"; exit 1
fi

BACKUP_DIR="${BACKUP_DIR:-/home/deploy/backups}"
DUMP_PATH="${1:-$(ls -1t "$BACKUP_DIR"/sgd_backup_*.dmp | head -1)}"
DUMP_FILE="$(basename "$DUMP_PATH")"
[ -f "$DUMP_PATH" ] || { echo "ERROR: no existe $DUMP_PATH"; exit 1; }

: "${ORACLE_SYSTEM_PASSWORD:?Falta ORACLE_SYSTEM_PASSWORD en .env}"
CONNECT="SYSTEM/${ORACLE_SYSTEM_PASSWORD}@localhost/XEPDB1"

# Ejecuta SQL como SYSTEM (el script SQL viaja por archivo, la contraseña nunca se imprime).
run_sql() {
    local tmp; tmp=$(mktemp)
    { echo "SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 300 SERVEROUTPUT ON"; echo "WHENEVER SQLERROR EXIT FAILURE"; cat; echo "EXIT"; } > "$tmp"
    docker compose cp "$tmp" oracle-xe:/tmp/rehearsal.sql >/dev/null
    rm -f "$tmp"
    docker compose exec -T oracle-xe sqlplus -S "$CONNECT" @/tmp/rehearsal.sql
}

drop_test_schema() {
    run_sql <<SQL
DECLARE n NUMBER;
BEGIN
  SELECT COUNT(*) INTO n FROM dba_users WHERE username = '${TEST_SCHEMA}';
  IF n > 0 THEN EXECUTE IMMEDIATE 'DROP USER ${TEST_SCHEMA} CASCADE'; END IF;
END;
/
SQL
}

echo "=== Simulacro de restauración $(date) ==="
echo "Dump: $DUMP_FILE ($(du -h "$DUMP_PATH" | cut -f1)) → esquema temporal $TEST_SCHEMA"

DPDIR=$(run_sql <<'SQL' | grep -E '^/' | head -1 | xargs
SELECT directory_path FROM dba_directories WHERE directory_name = 'SGD_DUMP';
SQL
)
[ -n "$DPDIR" ] || { echo "ERROR: no existe el directorio SGD_DUMP (correr backup.sh una vez)"; exit 1; }

cleanup() {
    echo "--- Limpieza ---"
    drop_test_schema >/dev/null && echo "Esquema $TEST_SCHEMA eliminado"
    docker compose exec -T --user root oracle-xe rm -f "$DPDIR/$DUMP_FILE" "$DPDIR/rehearsal_import.log" /tmp/rehearsal.sql 2>/dev/null || true
}
trap cleanup EXIT

drop_test_schema >/dev/null
TABLESPACE=$(run_sql <<SQL | xargs
SELECT default_tablespace FROM dba_users WHERE username = '${SOURCE_SCHEMA}';
SQL
)
TEST_PASSWORD="R$(openssl rand -hex 12)"
run_sql >/dev/null <<SQL
CREATE USER ${TEST_SCHEMA} IDENTIFIED BY "${TEST_PASSWORD}" DEFAULT TABLESPACE ${TABLESPACE} QUOTA UNLIMITED ON ${TABLESPACE} ACCOUNT LOCK;
SQL
unset TEST_PASSWORD
echo "Esquema temporal creado (bloqueado, tablespace $TABLESPACE)"

docker compose cp "$DUMP_PATH" "oracle-xe:$DPDIR/$DUMP_FILE" >/dev/null
docker compose exec -T --user root oracle-xe chown oracle:oinstall "$DPDIR/$DUMP_FILE" 2>/dev/null || true

echo "--- impdp ---"
START=$(date +%s)
# EXCLUDE=USER: el usuario ya existe bloqueado (no copiar la contraseña de producción). JOB: no programar jobs.
docker compose exec -T oracle-xe impdp "\"${CONNECT}\"" \
    directory=SGD_DUMP dumpfile="$DUMP_FILE" logfile=rehearsal_import.log \
    schemas="$SOURCE_SCHEMA" remap_schema="${SOURCE_SCHEMA}:${TEST_SCHEMA}" \
    exclude=USER,JOB 2>&1 | grep -E "^(ORA-|Job |Processing object type SCHEMA_EXPORT/TABLE/TABLE_DATA)" | grep -v "ORA-31684" || true
echo "impdp terminó en $(( $(date +%s) - START )) s"

echo "--- Comparación de filas (exacta, tabla por tabla) ---"
run_sql <<SQL
DECLARE
  src NUMBER; dst NUMBER; tables_ok NUMBER := 0; tables_diff NUMBER := 0; missing NUMBER := 0;
  total_src NUMBER := 0; total_dst NUMBER := 0;
BEGIN
  FOR t IN (SELECT table_name FROM dba_tables WHERE owner = '${SOURCE_SCHEMA}' AND nested = 'NO' AND temporary = 'N'
            AND table_name NOT LIKE 'SYS_EXPORT%' AND table_name NOT LIKE 'BIN$%' ORDER BY table_name) LOOP
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM "${SOURCE_SCHEMA}"."' || t.table_name || '"' INTO src;
    BEGIN
      EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM "${TEST_SCHEMA}"."' || t.table_name || '"' INTO dst;
    EXCEPTION WHEN OTHERS THEN
      missing := missing + 1; DBMS_OUTPUT.PUT_LINE('FALTA  ' || t.table_name || ' (' || src || ' filas en producción)'); CONTINUE;
    END;
    total_src := total_src + src; total_dst := total_dst + dst;
    IF src = dst THEN tables_ok := tables_ok + 1;
    ELSE tables_diff := tables_diff + 1; DBMS_OUTPUT.PUT_LINE('DIFIERE ' || t.table_name || ': producción=' || src || ' restaurado=' || dst);
    END IF;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('RESUMEN tablas_iguales=' || tables_ok || ' tablas_distintas=' || tables_diff || ' tablas_faltantes=' || missing
    || ' filas_produccion=' || total_src || ' filas_restauradas=' || total_dst);
END;
/
SELECT 'OBJETOS_INVALIDOS=' || COUNT(*) FROM dba_objects WHERE owner = '${TEST_SCHEMA}' AND status = 'INVALID';
SQL
echo "(Diferencias pequeñas en tablas con actividad desde la hora del dump son esperables.)"
