#!/bin/bash
# Prueba: si PowerSync se cae, Postgres no llena el disco (R2). Con max_slot_wal_keep_size, un slot de replicación
# que nadie lee deja de retener WAL al llegar al tope: se invalida (wal_status = lost) y el WAL se recicla.
# PowerSync, al volver, ve el slot perdido y copia todo de nuevo (docs/PRODUCTION.md › PowerSync).
# Usa un Postgres temporal con tope de 64MB (no toca el de desarrollo) y lo borra al terminar.
# Uso: bash scripts/tests/powersync-wal-tope.test.sh
set -u
DOCKER="${DOCKER:-docker}"
NOMBRE="sgd-prueba-wal-$$"
TOPE_MB=64

FAILS=0
check() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "  ok   $name"; else echo "  FALLA $name"; FAILS=$((FAILS + 1)); fi
}
limpiar() { "$DOCKER" rm -f "$NOMBRE" > /dev/null 2>&1; }
trap limpiar EXIT

sql() { "$DOCKER" exec "$NOMBRE" psql -U prueba -d prueba -tAc "$1"; }

echo "Postgres temporal con wal_level=logical y tope de ${TOPE_MB}MB"
"$DOCKER" run -d --name "$NOMBRE" -e POSTGRES_USER=prueba -e POSTGRES_PASSWORD=prueba -e POSTGRES_DB=prueba \
    pgvector/pgvector:pg17 postgres -c wal_level=logical -c "max_slot_wal_keep_size=${TOPE_MB}MB" -c max_wal_size=96MB \
    -c min_wal_size=32MB > /dev/null
for _ in $(seq 1 30); do
    "$DOCKER" exec "$NOMBRE" pg_isready -U prueba -d prueba > /dev/null 2>&1 && sql "select 1" > /dev/null 2>&1 && break
    sleep 1
done
check "el tope quedó en ${TOPE_MB}MB" test "$(sql "select setting from pg_settings where name = 'max_slot_wal_keep_size'")" = "$TOPE_MB"

echo "Un slot que nadie lee (PowerSync caído)"
sql "select pg_create_logical_replication_slot('powersync_prueba', 'pgoutput')" > /dev/null
sql "create table relleno (id bigserial primary key, dato text)" > /dev/null
check "el slot empieza reservado" test "$(sql "select wal_status from pg_replication_slots where slot_name = 'powersync_prueba'")" = "reserved"

echo "Se escriben ~300MB de WAL"
for _ in $(seq 1 6); do
    sql "insert into relleno (dato) select repeat(md5(g::text), 30) from generate_series(1, 50000) g" > /dev/null
    sql "select pg_switch_wal()" > /dev/null
    sql "checkpoint" > /dev/null
done

estado=$(sql "select coalesce(wal_status, '') from pg_replication_slots where slot_name = 'powersync_prueba'")
en_disco=$(sql "select (sum(size) / 1048576)::bigint from pg_ls_waldir()")
echo "  estado del slot: ${estado:-?}; WAL en disco: ${en_disco:-?}MB"
check "el slot se invalidó (lost) en vez de retener todo" test "$estado" = "lost"
check "el WAL en disco no creció con lo escrito (< 3 × tope, se escribieron ~300MB)" test "${en_disco:-99999}" -lt $((TOPE_MB * 3))

echo
if [ "$FAILS" -eq 0 ]; then echo "TODO OK"; else echo "$FAILS FALLAS"; exit 1; fi
