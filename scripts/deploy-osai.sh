#!/bin/bash
# scripts/deploy-osai.sh — Build y despliegue de OSAI
# Ejecutar desde sgd-infra/
set -e

echo "=== Deploy OSAI ==="

echo "Construyendo imagen OSAI..."
docker compose build osai

echo "Levantando OSAI..."
docker compose up -d osai

echo "Esperando a que OSAI esté listo..."
sleep 10
until curl -sf http://localhost:8001/info &>/dev/null || docker compose exec -T osai curl -sf http://localhost:8000/info &>/dev/null; do
    echo "  OSAI no listo, reintentando en 5s..."
    sleep 5
done

echo ""
echo "=== OSAI deploy completado ==="
echo "Probar: docker compose exec osai curl -s http://localhost:8000/info"
