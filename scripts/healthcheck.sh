#!/bin/bash
# scripts/healthcheck.sh — Verifica que todos los servicios estén funcionando
# Ejecutar desde sgd-infra/
set -e

if [ -f docker-compose.dockploy.yml ]; then
  COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.dockploy.yml}"
else
  COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
fi
export COMPOSE_FILE

echo "=== Health Check SGD ==="
PASS=0
FAIL=0

check() {
    local name="$1"
    local cmd="$2"
    if eval "$cmd" &>/dev/null; then
        echo "  [OK] $name"
        PASS=$((PASS+1))
    else
        echo "  [FAIL] $name"
        FAIL=$((FAIL+1))
    fi
}

# Contenedores activos
check "Oracle XE"        "docker compose ps oracle-xe | grep -q 'healthy'"
check "Redis"            "docker compose ps redis | grep -q 'healthy'"
check "Laravel App"      "docker compose ps app | grep -q 'Up'"
check "Worker Default"   "docker compose ps worker-default | grep -q 'Up'"
check "Worker PQRSD"     "docker compose ps worker-pqrsd | grep -q 'Up'"
check "Scheduler"        "docker compose ps scheduler | grep -q 'Up'"
check "Reverb"           "docker compose ps reverb | grep -q 'Up'"
check "OSAI"             "docker compose ps osai | grep -q 'Up'"
check "Nginx"            "docker compose ps nginx | grep -q 'Up'"

echo ""

# Health endpoint de Laravel via HTTPS (Traefik → nginx → app)
check "API Health"       "curl -sfk https://demo.aviliontech.com/api/health"

# OSAI info (via red interna de docker compose)
check "OSAI /info"       "docker compose exec -T osai curl -sf http://localhost:8000/info"

# Frontend via HTTPS (Traefik → nginx → SPA)
check "Frontend SPA"     "curl -sfk https://demo.aviliontech.com/ | grep -q 'id=q-app'"

echo ""
echo "Resultado: $PASS OK, $FAIL FAIL"
[ "$FAIL" -eq 0 ] && echo "Todos los servicios están saludables." || echo "Hay servicios con problemas."

# --- Telegram alert si hay servicios caídos ---
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-8706852433:AAF6KVl9fzbehgmJrClbntquTwAdXen7r_U}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-5096050646}"

if [ "$FAIL" -gt 0 ]; then
    MSG="🚨 *SGD ALERTA*: $FAIL servicios caídos
$(date)
✅ OK: $PASS  |  ❌ FAIL: $FAIL"
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -d "chat_id=$TELEGRAM_CHAT_ID" \
        -d "text=$MSG" \
        -d "parse_mode=Markdown" > /dev/null 2>&1
fi

exit $FAIL
