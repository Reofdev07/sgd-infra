#!/bin/bash
# scripts/deploy-front.sh — Build del frontend y despliegue
# Genera config.json automático desde .env
# Ejecutar desde sgd-infra/
set -e

if [ -f .env ]; then
    set -a; source .env; set +a
fi

FRONT_DIR="${FRONTEND_PATH:-../SGD-Front}"

echo "=== Deploy Frontend ==="

echo "Instalando dependencias..."
cd "$FRONT_DIR"
npm ci

echo "Compilando SPA para producción..."
NODE_ENV=production npm run build

echo "Verificando build..."
if [ ! -f dist/spa/index.html ]; then
    echo "ERROR: dist/spa/index.html no existe. El build falló."
    exit 1
fi

echo "Build correcto: $(wc -c < dist/spa/index.html) bytes"

# --- Generar config.json desde .env ---
# Esto evita tener que editar config.json a mano para cada entorno
DOMAIN="${DOMAIN:-localhost}"
REVERB_PORT="80"
REVERB_SCHEME="http"
if [ "$DOMAIN" != "localhost" ]; then
    REVERB_PORT="443"
    REVERB_SCHEME="https"
fi

cat > dist/spa/config.json <<JSON
{
  "API_URL": "/api/",
  "REVERB_APP_KEY": "${REVERB_APP_KEY}",
  "REVERB_HOST": "${DOMAIN}",
  "REVERB_PORT": "${REVERB_PORT}",
  "REVERB_SCHEME": "${REVERB_SCHEME}",
  "REVERB_WSPATH": "/ws",
  "SECRET_KEY": "${SECRET_KEY:-mr7-sgd-secure-key-2026}"
}
JSON

echo "config.json generado para DOMAIN=$DOMAIN (${REVERB_SCHEME}://${DOMAIN}:${REVERB_PORT})"

# Volver a sgd-infra
cd - >/dev/null

# --- Nginx: bind mount fix ---
# npm run build borra y recrea dist/spa/ (cambia el inodo),
# rompiendo el bind mount de Docker. Hay que recrear el contenedor.
if [ -f docker-compose.dockploy.yml ]; then
  COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.dockploy.yml}"
else
  COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
fi
echo "Recreando nginx para refrescar bind mount (usando $COMPOSE_FILE)..."
docker compose -f "$COMPOSE_FILE" up -d --force-recreate nginx

echo ""
echo "=== Frontend deploy completado ==="
