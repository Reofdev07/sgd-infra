#!/bin/bash
# Prepara Postgres para PowerSync (trabajo sin conexión). Se puede repetir: no duplica nada y vuelve a fijar las
# contraseñas (sirve para rotarlas).
#  - rol powersync_rep (REPLICATION, solo lectura de las tablas publicadas)
#  - publicación powersync (solo las tablas que se sincronizan)
#  - base powersync_storage con su propio dueño (estado de PowerSync)
# Requiere que las migraciones ya hayan creado las tablas y que Postgres tenga wal_level=logical.
#
# Producción (desde sgd-infra/): bash powersync/preparar.sh
#   Lee POWERSYNC_REP_PASSWORD y POWERSYNC_STORAGE_PASSWORD del entorno o de .env; nunca las imprime.
# Local: bash powersync/preparar-local.sh (contraseñas fijas de desarrollo).
set -euo pipefail
cd "$(dirname "$0")/.."
DOCKER="${DOCKER:-docker}"
TABLAS="document_tasks documents dependencies document_traces document_actions document_electronic_record electronic_records officials document_typologies gdo_tablas process_activities process_steps holidays"

# Mismo criterio que los scripts de despliegue: el compose de producción si existe (preparar-local.sh fija el suyo).
if [ -z "${COMPOSE_FILE:-}" ] && [ -f docker-compose.dockploy.yml ]; then
    export COMPOSE_FILE=docker-compose.dockploy.yml
fi

del_env() { [ -f .env ] && grep -E "^$1=" .env | tail -1 | cut -d= -f2- | tr -d '\r' || true; }
REP_PASS="${POWERSYNC_REP_PASSWORD:-$(del_env POWERSYNC_REP_PASSWORD)}"
STORAGE_PASS="${POWERSYNC_STORAGE_PASSWORD:-$(del_env POWERSYNC_STORAGE_PASSWORD)}"
# El token de administración no lo usa este script, pero PowerSync no debe arrancar sin uno fuerte.
ADMIN_TOKEN="${POWERSYNC_ADMIN_TOKEN:-$(del_env POWERSYNC_ADMIN_TOKEN)}"
PG_USER="${POSTGRES_USER:-$(del_env POSTGRES_USER)}"; PG_USER="${PG_USER:-sgd}"
PG_DB="${POSTGRES_DB:-$(del_env POSTGRES_DB)}"; PG_DB="${PG_DB:-sgd}"

for nombre in REP_PASS STORAGE_PASS ADMIN_TOKEN; do
    valor="${!nombre}"
    if [ -z "$valor" ]; then
        echo "Falta ${nombre} (POWERSYNC_*) en sgd-infra/.env (genere uno con: openssl rand -hex 24)." >&2
        exit 1
    fi
    # Van dentro de SQL: solo letras, números, - y _ (openssl rand -hex 24 cumple).
    if ! [[ "$valor" =~ ^[A-Za-z0-9_-]{16,}$ ]]; then
        echo "${nombre} (POWERSYNC_*) debe tener al menos 16 caracteres: letras, números, - o _." >&2
        exit 1
    fi
done

# La SQL va por la entrada estándar: las contraseñas no quedan en la lista de procesos.
psql_sgd() { "$DOCKER" compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -U "$PG_USER" -d "$PG_DB" -tA; }

if [ "$(echo "SHOW wal_level" | psql_sgd)" != "logical" ]; then
    echo "Postgres no tiene wal_level=logical: recree el servicio postgres con el compose actual (corte de 1–2 min)." >&2
    exit 1
fi

psql_sgd <<SQL
DO \$\$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'powersync_rep') THEN
        CREATE ROLE powersync_rep WITH REPLICATION LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'powersync_storage') THEN
        CREATE ROLE powersync_storage WITH LOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'powersync') THEN
        CREATE PUBLICATION powersync;
    END IF;
END \$\$;
ALTER ROLE powersync_rep WITH REPLICATION LOGIN PASSWORD '${REP_PASS}';
ALTER ROLE powersync_storage WITH LOGIN PASSWORD '${STORAGE_PASS}';
GRANT USAGE ON SCHEMA public TO powersync_rep;
SQL

for tabla in $TABLAS; do
    echo "GRANT SELECT ON public.$tabla TO powersync_rep" | psql_sgd
done
echo "ALTER PUBLICATION powersync SET TABLE $(echo "$TABLAS" | sed 's/ /, /g')" | psql_sgd
if [ "$(echo "SELECT count(*) FROM pg_database WHERE datname = 'powersync_storage'" | psql_sgd)" = "0" ]; then
    echo "CREATE DATABASE powersync_storage OWNER powersync_storage" | psql_sgd
fi
echo "Postgres listo para PowerSync (tablas: $TABLAS)."
