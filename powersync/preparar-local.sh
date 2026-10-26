#!/bin/bash
# Prepara el Postgres LOCAL para PowerSync. Se puede repetir.
#  - rol powersync_rep (REPLICATION, solo lectura de las tablas publicadas)
#  - publicación powersync (solo las tablas que se sincronizan)
#  - base powersync_storage con su propio dueño (estado de PowerSync)
# Requiere que las migraciones ya hayan creado las tablas.
set -euo pipefail
cd "$(dirname "$0")/.."
DOCKER="${DOCKER:-docker}"
TABLAS="document_tasks"

psql_sgd() { "$DOCKER" compose exec -T postgres psql -v ON_ERROR_STOP=1 -U sgd -d sgd -tAc "$1" < /dev/null; }

psql_sgd "DO \$\$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'powersync_rep') THEN
        CREATE ROLE powersync_rep WITH REPLICATION LOGIN PASSWORD 'powersync_rep';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'powersync_storage') THEN
        CREATE ROLE powersync_storage WITH LOGIN PASSWORD 'powersync_storage';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'powersync') THEN
        CREATE PUBLICATION powersync;
    END IF;
END \$\$;"
psql_sgd "GRANT USAGE ON SCHEMA public TO powersync_rep"
for tabla in $TABLAS; do
    psql_sgd "GRANT SELECT ON public.$tabla TO powersync_rep"
done
psql_sgd "ALTER PUBLICATION powersync SET TABLE $(echo "$TABLAS" | sed 's/ /, /g')"
if [ "$(psql_sgd "SELECT count(*) FROM pg_database WHERE datname = 'powersync_storage'")" = "0" ]; then
    psql_sgd "CREATE DATABASE powersync_storage OWNER powersync_storage"
fi
echo "Postgres local listo para PowerSync (tablas: $TABLAS)."
