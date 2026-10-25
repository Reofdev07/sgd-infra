#!/bin/bash
# Prueba de los scripts y compose con Postgres.
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

cat > "$DIR/base.env" <<ENV
APP_KEY=base64:prueba
OSAI_API_TOKEN=x
PASSPORT_CLIENT_SECRET=x
POSTGRES_PASSWORD=clave-admin
DB_PASSWORD=clave-app
REDIS_PASSWORD=x
REVERB_APP_ID=1
REVERB_APP_KEY=x
REVERB_APP_SECRET=x
WEBHOOK_SECRET=x
B2_KEY_ID=x
B2_APPLICATION_KEY=x
DOMAIN=sgd.example
ENV

# valor_env compose envfile servicio VARIABLE → valor que recibe el servicio
valor_env() {
    "$DOCKER" compose --env-file "$2" -f "$1" config --format json 2>/dev/null | python3 -c '
import json, sys
servicio, variable = sys.argv[1], sys.argv[2]
entorno = json.load(sys.stdin)["services"][servicio].get("environment", {})
print(entorno.get(variable, "") if isinstance(entorno, dict) else "")' "$3" "$4"
}
igual() { [ "$1" = "$2" ]; }
servicios() { "$DOCKER" compose --env-file "$2" -f "$1" config --services 2>/dev/null | sort | tr '\n' ' '; }

for compose in docker-compose.dockploy.yml docker-compose.yml; do
    echo "Compose $compose"
    E="$DIR/base.env"
    check "config válido" "$DOCKER" compose --env-file "$E" -f "$compose" config -q
    check "sin servicio oracle-xe" bash -c "! grep -qi oracle '$compose'"
    check "la app usa postgres por defecto" igual "$(valor_env "$compose" "$E" app DB_CONNECTION)/$(valor_env "$compose" "$E" app DB_HOST)/$(valor_env "$compose" "$E" app DB_USERNAME)" "pgsql/postgres/sgd_app"
    check "worker-default recibe la misma base" igual "$(valor_env "$compose" "$E" worker-default DB_HOST)" "postgres"
    check "postgres tiene su contraseña de administración" igual "$(valor_env "$compose" "$E" postgres POSTGRES_PASSWORD)" "clave-admin"
    grep -v '^POSTGRES_PASSWORD=' "$E" > "$DIR/sin-admin.env"
    check "sin POSTGRES_PASSWORD el compose no arranca" bash -c "! '$DOCKER' compose --env-file '$DIR/sin-admin.env' -f '$compose' config -q"
    grep -v '^DB_PASSWORD=' "$E" > "$DIR/sin-app.env"
    check "sin DB_PASSWORD el compose no arranca" bash -c "! '$DOCKER' compose --env-file '$DIR/sin-app.env' -f '$compose' config -q"
done

echo "Instalación nueva: el script de inicio de Postgres crea sgd_app"
PROYECTO="prueba-init-$$"
"$DOCKER" compose -p "$PROYECTO" --env-file "$DIR/base.env" -f docker-compose.yml up -d --no-deps postgres >/dev/null 2>&1
for _ in $(seq 1 40); do
    "$DOCKER" compose -p "$PROYECTO" --env-file "$DIR/base.env" -f docker-compose.yml ps postgres 2>/dev/null | grep -q '(healthy)' && break
    sleep 2
done
consulta() { "$DOCKER" compose -p "$PROYECTO" --env-file "$DIR/base.env" -f docker-compose.yml exec -T postgres psql -U sgd -d sgd -At -c "$1" 2>/dev/null | tr -d '\r'; }
check "sgd_app existe y no es superusuario" igual "$(consulta "select rolsuper from pg_roles where rolname = 'sgd_app'")" "f"
check "la base y el esquema public son de sgd_app" igual "$(consulta "select pg_get_userbyid(d.datdba) || '/' || pg_get_userbyid(n.nspowner) from pg_database d, pg_namespace n where d.datname = 'sgd' and n.nspname = 'public'")" "sgd_app/sgd_app"
check "extensiones vector y unaccent" igual "$(consulta "select string_agg(extname, ',' order by extname) from pg_extension where extname in ('vector','unaccent')")" "unaccent,vector"
check "sgd_app entra con su contraseña" bash -c "'$DOCKER' compose -p '$PROYECTO' --env-file '$DIR/base.env' -f docker-compose.yml exec -T -e PGPASSWORD=clave-app postgres psql -h 127.0.0.1 -U sgd_app -d sgd -Atc 'select 1' | grep -q 1"
"$DOCKER" compose -p "$PROYECTO" --env-file "$DIR/base.env" -f docker-compose.yml down -v >/dev/null 2>&1

echo "Respaldo en modo seco"
printf 'BACKUP_DIR=%s\n' "$PWD/$DIR" > "$DIR/b.env"
check "usa pg_dump" igual "$(ENV_FILE="$DIR/b.env" BACKUP_DRY_RUN=1 bash scripts/backup.sh | tail -1)" "metodo=pg_dump"

echo "Sin Oracle en los scripts"
check "ningún script menciona Oracle" bash -c "! grep -rliE 'oracle|expdp|impdp|sqlplus|oci_connect' scripts/*.sh scripts/lib/*.sh"
check "el Dockerfile no instala oci8" bash -c "! grep -qiE 'oci8|oracle' php/Dockerfile"

echo ""
[ "$FAILS" -eq 0 ] && echo "Todo bien." || echo "$FAILS fallas."
exit "$FAILS"
