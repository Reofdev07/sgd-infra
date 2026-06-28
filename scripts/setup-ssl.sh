#!/bin/bash
# scripts/setup-ssl.sh — Obtener certificado SSL con Let's Encrypt y activar HTTPS
# Ejecutar desde sgd-infra/ DESPUÉS de que el dominio apunte al VPS
# Requiere: DOMAIN configurado en .env
set -e

if [ -f .env ]; then
    set -a; source .env; set +a
fi

if [ -z "$DOMAIN" ] || [ "$DOMAIN" = "localhost" ]; then
    echo "ERROR: DOMAIN no está configurado en .env o es 'localhost'."
    echo "Configura DOMAIN= tudominio.com antes de ejecutar este script."
    exit 1
fi

echo "=== Setup SSL para $DOMAIN ==="

# 1. Asegurar que nginx esté corriendo (necesario para el challenge HTTP-01)
echo "Verificando que nginx esté activo..."
docker compose ps nginx | grep -q 'Up' || docker compose up -d nginx

# 2. Obtener certificado con Certbot via HTTP-01 challenge
echo "Obteniendo certificado SSL para $DOMAIN..."
docker compose run --rm certbot certonly --webroot \
    -w /var/www/certbot \
    -d "$DOMAIN" \
    --non-interactive \
    --agree-tos \
    --email admin@"$DOMAIN" \
    || {
        echo ""
        echo "Certbot falló. Posibles causas:"
        echo "  - El dominio $DOMAIN no apunta a este servidor"
        echo "  - El puerto 80 no está abierto"
        echo "  - Ya hay un certificado vigente (usa --force-renewal)"
        exit 1
    }

# 3. Generar nginx config con SSL a partir de template
echo "Generando configuración SSL de nginx..."
export DOMAIN
envsubst '${DOMAIN}' < nginx/ssl.conf > nginx/sgd-ssl.conf

# 4. Renovar config de certbot automáticamente (cron)
RENEW_CMD="cd $(pwd) && docker compose run --rm certbot renew && docker compose exec nginx nginx -s reload"
(crontab -l 2>/dev/null | grep -v "certbot"; echo "0 3 * * * $RENEW_CMD") | crontab -
echo "Cron de renovación SSL instalado (diario a las 3:00 AM)."

# 5. Recargar nginx
echo "Recargando nginx..."
docker compose exec nginx nginx -s reload || docker compose restart nginx

echo ""
echo "=== SSL configurado correctamente ==="
echo "Tu sitio ahora responde en:"
echo "  https://$DOMAIN"
