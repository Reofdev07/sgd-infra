#!/bin/bash
# Prueba del servicio de sincronización (PowerSync) en el entorno local.
# Uso: bash scripts/tests/powersync-local.test.sh
# Levanta postgres y powersync con el override local, prepara la base y comprueba que replica.
#
# Prueba manual con un token de Laravel (Laravel local con `php artisan serve --host=0.0.0.0 --port=8000`
# y llaves creadas con `php artisan sync:keys`):
#   TOKEN=$(curl -s -H "Authorization: Bearer <token de sesión>" http://127.0.0.1:8000/api/v1/sync/token | jq -r .token)
#   curl -sN -X POST http://localhost:8089/sync/stream -H "Authorization: Token $TOKEN" \
#        -H 'Content-Type: application/json' -d '{"raw_data":true}'
# Debe llegar un checkpoint con las tareas del usuario; un token alterado responde 401.
set -u
cd "$(dirname "$0")/../.."
DOCKER="${DOCKER:-docker}"

FAILS=0
check() { # check "descripción" comando...
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "  ok   $name"; else echo "  FALLA $name"; FAILS=$((FAILS + 1)); fi
}
psql_sgd() { "$DOCKER" compose exec -T postgres psql -U sgd -d sgd -tAc "$1" < /dev/null; }
# PowerSync registra «Failed to update sync config» si un stream usa algo que no acepta.
sin_errores_de_config() { ! "$DOCKER" compose logs --since 2m powersync 2>&1 | grep -q "Failed to update sync config"; }

echo "Postgres con replicación lógica"
"$DOCKER" compose up -d postgres > /dev/null 2>&1
until "$DOCKER" compose exec -T postgres pg_isready -U sgd -d sgd > /dev/null 2>&1 < /dev/null; do sleep 2; done
check "wal_level = logical" test "$(psql_sgd 'show wal_level')" = "logical"

echo "Preparación de la base (repetible)"
check "preparar-local.sh corre" bash powersync/preparar-local.sh
check "preparar-local.sh se puede repetir" bash powersync/preparar-local.sh
check "publicación powersync solo con las tablas que se sincronizan" \
    test "$(psql_sgd "select string_agg(tablename, ',' order by tablename) from pg_publication_tables where pubname = 'powersync'")" = "dependencies,document_actions,document_electronic_record,document_suspensions,document_tasks,document_traces,document_typologies,documents,electronic_records,gdo_tablas,holidays,officials,process_activities,process_steps"
# Una tabla publicada sin clave primaria ni identidad de réplica hace que Postgres rechace sus UPDATE y DELETE: la app
# dejaría de poder cambiarla (document_electronic_record, Etapa 3).
check "toda tabla publicada admite UPDATE y DELETE (clave primaria o identidad de réplica)" \
    test "$(psql_sgd "select count(*) from pg_publication_tables pt join pg_class c on c.relname = pt.tablename join pg_namespace n on n.oid = c.relnamespace and n.nspname = pt.schemaname where pt.pubname = 'powersync' and c.relreplident = 'd' and not exists (select 1 from pg_index i where i.indrelid = c.oid and i.indisprimary)")" = "0"
check "rol powersync_rep con REPLICATION" test "$(psql_sgd "select rolreplication from pg_roles where rolname = 'powersync_rep'")" = "t"
check "base powersync_storage existe" test "$(psql_sgd "select count(*) from pg_database where datname = 'powersync_storage'")" = "1"

echo "Qué se sincroniza"
check "los streams no envían filas borradas" grep -q "deleted_at IS NULL" powersync/sync-config.yaml
check "el id viaja como texto (lo exige la base local)" grep -q "CAST(id AS text) AS id" powersync/sync-config.yaml
check "PowerSync solo escucha en este equipo" grep -q '"127.0.0.1:8089:8080"' docker-compose.override.yml

echo "Servicio PowerSync"
"$DOCKER" compose up -d powersync > /dev/null 2>&1
"$DOCKER" compose restart powersync > /dev/null 2>&1 # relee sync-config.yaml
vivo=0
for _ in $(seq 1 30); do
    if curl -sf http://localhost:8089/probes/liveness > /dev/null; then vivo=1; break; fi
    sleep 2
done
check "responde /probes/liveness en :8089" test "$vivo" = "1"
sleep 5
check "PowerSync acepta los streams (sin errores de configuración)" sin_errores_de_config
slot=0
for _ in $(seq 1 15); do
    if [ "$(psql_sgd "select count(*) from pg_replication_slots where slot_type = 'logical'")" -ge 1 ]; then slot=1; break; fi
    sleep 2
done
check "creó su slot de replicación" test "$slot" = "1"

echo
if [ "$FAILS" -eq 0 ]; then echo "TODO OK"; else echo "$FAILS FALLAS"; exit 1; fi
