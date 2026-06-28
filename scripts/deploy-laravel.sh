#!/bin/bash
# scripts/deploy-laravel.sh — Migraciones y setup de Laravel después del primer arranque
# Ejecutar desde sgd-infra/
set -e

echo "=== Deploy Laravel ==="

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

# Passport — solo regenerar si NO existen (persistencia entre deploys)
if docker compose exec -T app test -f storage/oauth-private.key; then
    echo "Llaves Passport ya existen, omitiendo regeneración."
else
    echo "Generando llaves Passport..."
    docker compose exec -T app php artisan passport:keys --force
fi

echo "Verificando cliente personal de Passport..."
docker compose exec -T app php artisan passport:client --personal --no-interaction || \
    echo "  (Cliente personal ya existe, omitiendo)"

# Storage link
echo "Creando symlink de storage..."
docker compose exec -T app php artisan storage:link || true

# Caches de optimización
echo "Cacheando configuración, rutas, vistas y eventos..."
docker compose exec -T app php artisan config:cache
docker compose exec -T app php artisan route:cache
docker compose exec -T app php artisan view:cache
docker compose exec -T app php artisan event:cache

# Reiniciar workers
echo "Reiniciando queue workers..."
docker compose exec -T app php artisan queue:restart || true

echo ""
echo "=== Laravel deploy completado ==="
echo "Probar: curl -s http://localhost/api/health"
