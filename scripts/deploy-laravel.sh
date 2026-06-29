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
until docker compose exec -T app php artisan migrate:status &>/dev/null; do
    echo "  Oracle no listo, reintentando en 5s..."
    sleep 5
done
echo "Oracle listo."

# Migraciones
echo "Ejecutando migraciones..."
docker compose exec -T app php artisan migrate --force

# Seeders (updateOrCreate — seguro de repetir)
echo "Sembrando datos base..."
docker compose exec -T app php artisan db:seed --force

# Storage permissions (PHP-FPM corre como www-data)
echo "Corrigiendo permisos de storage..."
docker compose exec -T app chown -R www-data:www-data /var/www/html/storage
docker compose exec -T app chmod -R 775 /var/www/html/storage

# Passport — solo regenerar si NO existen (persistencia entre deploys)
if docker compose exec -T app test -f storage/oauth-private.key; then
    echo "Llaves Passport ya existen, omitiendo regeneración."
else
    echo "Generando llaves Passport..."
    docker compose exec -T app php artisan passport:keys --force
fi

# Verificar si ya existe un cliente personal
PERSONAL_CLIENT_EXISTS=$(docker compose exec -T app php -r 'echo \Illuminate\Support\Facades\DB::table("oauth_clients")->where("personal_access_client", 1)->count();')
if [ "$PERSONAL_CLIENT_EXISTS" = "0" ]; then
    echo "Creando cliente personal de Passport..."
    docker compose exec -T app php artisan passport:client --personal --name="SGD Personal Access Client" --no-interaction
else
    echo "Cliente personal ya existe ($PERSONAL_CLIENT_EXISTS), omitiendo."
fi

# Verificar si ya existe un cliente password grant
PASSWORD_CLIENT_EXISTS=$(docker compose exec -T app php -r 'echo \Illuminate\Support\Facades\DB::table("oauth_clients")->where("password_client", 1)->count();')
if [ "$PASSWORD_CLIENT_EXISTS" = "0" ]; then
    echo "Creando cliente password grant de Passport..."
    docker compose exec -T app php artisan passport:client --password --name="SGD Password Grant Client" --no-interaction
else
    echo "Cliente password grant ya existe ($PASSWORD_CLIENT_EXISTS), omitiendo."
fi

# Storage link
echo "Creando symlink de storage..."
docker compose exec -T app php artisan storage:link || true

# Caches de optimización
echo "Cacheando configuración, rutas, vistas y eventos..."
docker compose exec -T app php artisan config:cache
docker compose exec -T app php artisan route:cache
docker compose exec -T app php artisan view:cache
docker compose exec -T app php artisan event:cache

# Opcache: limpiar para que los cambios de código se reflejen
# (opcache.validate_timestamps=0 en producción, no detecta cambios solito)
echo "Limpiando opcache..."
docker compose exec -T app php -r 'if (function_exists("opcache_reset")) { opcache_reset(); }'

# Reiniciar workers
echo "Reiniciando queue workers..."
docker compose exec -T app php artisan queue:restart || true

echo ""
echo "=== Laravel deploy completado ==="
echo "Probar: curl -s http://localhost/api/health"
