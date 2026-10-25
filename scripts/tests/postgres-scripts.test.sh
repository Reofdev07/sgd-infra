#!/bin/bash
# Prueba de los scripts y compose para Postgres (convive con Oracle hasta la limpieza final).
# Uso: bash scripts/tests/postgres-scripts.test.sh   (DOCKER=docker.exe en WSL sin integración)
set -u
cd "$(dirname "$0")/../.."
DOCKER="${DOCKER:-docker}"

FAILS=0
check() { # check "descripción" comando...
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "  ok   $name"; else echo "  FALLA $name"; FAILS=$((FAILS + 1)); fi
}

# Archivos temporales dentro del repo (docker.exe de Windows no ve /tmp de WSL); .env* está en .gitignore.
DIR=".env.prueba-postgres.$$"
mkdir -p "$DIR"
trap 'rm -rf "$DIR"' EXIT

echo "Sintaxis de los scripts"
for script in scripts/*.sh scripts/lib/*.sh; do
    check "bash -n $script" bash -n "$script"
done

base_env() { # base_env archivo DB_CONNECTION
    cat > "$1" <<ENV
APP_KEY=base64:prueba
OSAI_API_TOKEN=x
PASSPORT_CLIENT_SECRET=x
POSTGRES_PASSWORD=clave-postgres
REDIS_PASSWORD=x
REVERB_APP_ID=1
REVERB_APP_KEY=x
REVERB_APP_SECRET=x
WEBHOOK_SECRET=x
B2_KEY_ID=x
B2_APPLICATION_KEY=x
DOMAIN=sgd.example
ENV
    if [ "$2" = "pgsql" ]; then
        cat >> "$1" <<ENV
DB_CONNECTION=pgsql
DB_HOST=postgres
DB_PORT=5432
DB_DATABASE=sgd
DB_USERNAME=sgd
DB_PASSWORD=clave-postgres
ORACLE_DB_USERNAME=SGD_MR7
ORACLE_DB_PASSWORD=clave-oracle
ENV
    else
        cat >> "$1" <<ENV
DB_USERNAME=SGD_MR7
DB_PASSWORD=clave-oracle
ENV
    fi
}

# valor_env compose envfile servicio VARIABLE → valor que recibe el servicio
valor_env() {
    "$DOCKER" compose --env-file "$2" -f "$1" config --format json 2>/dev/null | python3 -c '
import json, sys
servicio, variable = sys.argv[1], sys.argv[2]
entorno = json.load(sys.stdin)["services"][servicio].get("environment", {})
print(entorno.get(variable, "") if isinstance(entorno, dict) else "")' "$3" "$4"
}
igual() { [ "$1" = "$2" ]; }

for compose in docker-compose.dockploy.yml docker-compose.yml; do
    echo "Compose $compose"
    base_env "$DIR/pgsql.env" pgsql
    base_env "$DIR/oracle.env" oracle
    check "config válido con DB_CONNECTION=pgsql" "$DOCKER" compose --env-file "$DIR/pgsql.env" -f "$compose" config -q
    check "config válido con Oracle" "$DOCKER" compose --env-file "$DIR/oracle.env" -f "$compose" config -q
    check "pgsql: la app usa postgres" igual "$(valor_env "$compose" "$DIR/pgsql.env" app DB_CONNECTION)/$(valor_env "$compose" "$DIR/pgsql.env" app DB_HOST)" "pgsql/postgres"
    check "pgsql: el origen del traslado sigue en Oracle" igual "$(valor_env "$compose" "$DIR/pgsql.env" app ORACLE_DB_HOST)/$(valor_env "$compose" "$DIR/pgsql.env" app ORACLE_DB_USERNAME)" "oracle-xe/SGD_MR7"
    check "pgsql: Oracle conserva su usuario" igual "$(valor_env "$compose" "$DIR/pgsql.env" oracle-xe APP_USER)" "SGD_MR7"
    check "Oracle: la app sigue en oracle-xe" igual "$(valor_env "$compose" "$DIR/oracle.env" app DB_CONNECTION)/$(valor_env "$compose" "$DIR/oracle.env" app DB_HOST)" "oracle/oracle-xe"
    check "worker-default recibe la misma base" igual "$(valor_env "$compose" "$DIR/pgsql.env" worker-default DB_HOST)" "postgres"
    check "postgres tiene su contraseña" igual "$(valor_env "$compose" "$DIR/pgsql.env" postgres POSTGRES_PASSWORD)" "clave-postgres"
    grep -v '^POSTGRES_PASSWORD=' "$DIR/pgsql.env" > "$DIR/sin.env"
    check "sin POSTGRES_PASSWORD el compose no arranca" bash -c "! '$DOCKER' compose --env-file '$DIR/sin.env' -f '$compose' config -q"
done

echo "Respaldo en modo seco"
printf 'DB_CONNECTION=pgsql\nBACKUP_DIR=%s\n' "$PWD/$DIR" > "$DIR/b-pg.env"
printf 'DB_CONNECTION=oracle\nBACKUP_DIR=%s\n' "$PWD/$DIR" > "$DIR/b-ora.env"
check "pgsql usa pg_dump" igual "$(ENV_FILE="$DIR/b-pg.env" BACKUP_DRY_RUN=1 bash scripts/backup.sh | tail -1)" "metodo=pg_dump"
check "Oracle usa expdp" igual "$(ENV_FILE="$DIR/b-ora.env" BACKUP_DRY_RUN=1 bash scripts/backup.sh | tail -1)" "metodo=expdp"

echo ""
[ "$FAILS" -eq 0 ] && echo "Todo bien." || echo "$FAILS fallas."
exit "$FAILS"
