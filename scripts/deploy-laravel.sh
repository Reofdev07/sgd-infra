#!/bin/bash
# scripts/deploy-laravel.sh — Migraciones y setup de Laravel después del primer arranque
# Ejecutar desde sgd-infra/
set -e

echo "=== Deploy Laravel ==="

# Detectar compose activo
if [ -f docker-compose.dockploy.yml ]; then
  COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.dockploy.yml}"
else
  COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
fi
export COMPOSE_FILE
echo "Usando compose file: $COMPOSE_FILE"

# Esperar a que Oracle esté listo
echo "Esperando a Oracle XE..."
until docker compose exec -T app php -r 'exit(oci_connect(getenv("DB_USERNAME"), getenv("DB_PASSWORD"), getenv("DB_HOST").":".getenv("DB_PORT")."/".getenv("DB_DATABASE")) ? 0 : 1);' &>/dev/null; do
    echo "  Oracle no listo, reintentando en 5s..."
    sleep 5
done
echo "Oracle listo."

# Migraciones (solo las pendientes, seguro de repetir)
echo "Ejecutando migraciones..."
docker compose exec -T app php artisan migrate --force

# Seeders — SOLO se ejecutan si se solicita explícitamente con SEED=true
# Por seguridad, seeders no se corren automáticamente en producción.
# Usar: SEED=true bash deploy-laravel.sh
if [ "$SEED" = "true" ]; then
    echo "Ejecutando seeders (solicitado vía SEED=true)..."
    docker compose exec -T app php artisan db:seed --force
    echo "Seeders completados."
else
    echo "Seeders omitidos. Para ejecutarlos: SEED=true bash deploy-laravel.sh"
fi

# Storage permissions (PHP-FPM corre como www-data)
echo "Corrigiendo permisos de storage..."
docker compose exec -T app mkdir -p /var/www/html/storage/framework/views \
  /var/www/html/storage/framework/cache/data \
  /var/www/html/storage/framework/sessions \
  /var/www/html/storage/framework/testing
docker compose exec -T app chown -R www-data:www-data /var/www/html/storage
docker compose exec -T app chmod -R 775 /var/www/html/storage

# Passport — solo regenerar si NO existen (persistencia entre deploys)
if docker compose exec -T app test -f storage/oauth-private.key; then
    echo "Llaves Passport ya existen, omitiendo regeneración."
else
    echo "Generando llaves Passport..."
    docker compose exec -T app php artisan passport:keys --force
fi

# Cuenta clientes Passport de un tipo con Laravel cargado (antes `php -r` sin bootstrap fallaba siempre
# y el script creía que ya existían: en una instancia nueva nunca se creaban y el login no funcionaba).
# Imprime el número, o nada si no se pudo consultar (entonces NO se crea nada para no duplicar clientes).
count_passport_clients() {
    docker compose exec -T -u www-data -e XDG_CONFIG_HOME=/tmp -e XDG_DATA_HOME=/tmp -e XDG_RUNTIME_DIR=/tmp app \
        php artisan tinker --execute="echo PHP_EOL.'COUNT='.DB::table('oauth_clients')->where('$1', 1)->count().PHP_EOL;" 2>/dev/null \
        | grep -oE 'COUNT=[0-9]+' | cut -d= -f2
}

# Verificar si ya existe un cliente personal
PERSONAL_CLIENT_EXISTS=$(count_passport_clients personal_access_client)
if [ -z "$PERSONAL_CLIENT_EXISTS" ]; then
    echo "WARN: no se pudo consultar oauth_clients; no se crea el cliente personal (revisar a mano)."
elif [ "$PERSONAL_CLIENT_EXISTS" = "0" ]; then
    echo "Creando cliente personal de Passport..."
    docker compose exec -T app php artisan passport:client --personal --name="SGD Personal Access Client" --no-interaction
else
    echo "Cliente personal ya existe ($PERSONAL_CLIENT_EXISTS), omitiendo."
fi

# Verificar si ya existe un cliente password grant
PASSWORD_CLIENT_EXISTS=$(count_passport_clients password_client)
if [ -z "$PASSWORD_CLIENT_EXISTS" ]; then
    echo "WARN: no se pudo consultar oauth_clients; no se crea el cliente password grant (revisar a mano)."
elif [ "$PASSWORD_CLIENT_EXISTS" = "0" ]; then
    echo "Creando cliente password grant de Passport..."
    docker compose exec -T app php artisan passport:client --password --name="SGD Password Grant Client" --no-interaction
else
    echo "Cliente password grant ya existe ($PASSWORD_CLIENT_EXISTS), omitiendo."
fi

# Storage link
echo "Creando symlink de storage..."
docker compose exec -T app php artisan storage:link || true

# Opcache: limpiar vía CLI antes de cachear (afecta a artisan)
echo "Limpiando opcache (CLI)..."
docker compose exec -T app php -r 'if (function_exists("opcache_reset")) { opcache_reset(); }'

# Caches de optimización
echo "Cacheando configuración, rutas, vistas y eventos..."
docker compose exec -T app php artisan config:clear
docker compose exec -T app php artisan config:cache
docker compose exec -T app php artisan route:cache
docker compose exec -T app php artisan view:cache

# Los caches y vistas compiladas se generaron como root: devolverlos a www-data (PHP-FPM).
# Si un archivo de storage queda de root (p. ej. el log diario), cada excepción registrada da 500.
docker compose exec -T app php artisan event:cache
docker compose exec -T app chown -R www-data:www-data /var/www/html/storage /var/www/html/bootstrap/cache

# Reiniciar app para que FPM tome los nuevos caches y opcache limpio
# (opcache_reset() vía CLI no afecta al pool FPM)
echo "Reiniciando contenedor app (FPM) para refrescar opcache..."
docker compose restart app

# Reiniciar workers
echo "Reiniciando queue workers..."
docker compose exec -T app php artisan queue:restart || true

# Reiniciar reverb y scheduler para que tomen el código actualizado
echo "Reiniciando reverb (WebSocket)..."
docker compose restart reverb || true

echo "Reiniciando scheduler..."
docker compose restart scheduler || true

echo ""
echo "=== Laravel deploy completado ==="
echo "Probar: curl -s http://localhost/api/health"
echo ""
echo "Recordatorio:"
echo "  - Seeders NO se ejecutan automáticamente"
echo "  - Si necesitas seeders: SEED=true bash $0"
echo "  - Para solo código (sin migrate): docker compose restart app"
