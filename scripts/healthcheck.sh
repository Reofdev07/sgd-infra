#!/bin/bash
# scripts/healthcheck.sh — Verifica que todos los servicios estén funcionando
# Ejecutar desde sgd-infra/
set +e

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

# Token/chat hardcodeados como fallback (SGD-096: se rotan vía BotFather y se
# mueven a variables de entorno en la fase de secretos). Centralizado aquí
# para no repetir el bloque curl.
send_telegram() {
    local text="$1"
    local token="${TELEGRAM_BOT_TOKEN:-8706852433:AAF6KVl9fzbehgmJrClbntquTwAdXen7r_U}"
    local chat="${TELEGRAM_CHAT_ID:-5096050646}"
    curl -s -X POST "https://api.telegram.org/bot$token/sendMessage" \
        -d "chat_id=$chat" \
        -d "text=$text" \
        -d "parse_mode=Markdown" > /dev/null 2>&1
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

# Salud de colas: failed_jobs (Oracle), backlog en Redis y uso de memoria.
# queue:health devuelve exit≠0 si se superan los umbrales (SGD-061).
QUEUE_RC=0
QUEUE_OUT=$(docker compose exec -T app php artisan queue:health --max-failed=0 --max-pending=200 2>&1) || QUEUE_RC=$?
if [ "$QUEUE_RC" -eq 0 ]; then
    echo "  [OK] Colas (failed/backlog/mem)"
    PASS=$((PASS+1))
else
    echo "  [FAIL] Colas (failed/backlog/mem)"
    FAIL=$((FAIL+1))
fi

# Tamaño de Oracle: alerta temprana antes de alcanzar el límite duro de 12 GB (SGD-110).
DBSIZE_RC=0
DBSIZE_OUT=$(docker compose exec -T app php artisan db:size --max-gb=8 2>&1) || DBSIZE_RC=$?
if [ "$DBSIZE_RC" -eq 0 ]; then
    echo "  [OK] Tamaño Oracle"
    PASS=$((PASS+1))
else
    echo "  [FAIL] Tamaño Oracle"
    FAIL=$((FAIL+1))
fi

echo ""
echo "Resultado: $PASS OK, $FAIL FAIL"
[ "$FAIL" -eq 0 ] && echo "Todos los servicios están saludables." || echo "Hay servicios con problemas."

# --- Telegram alert si hay chequeos fallidos ---
if [ "$FAIL" -gt 0 ]; then
    MSG="🚨 *SGD ALERTA*: $FAIL chequeos fallidos
$(date)
✅ OK: $PASS  |  ❌ FAIL: $FAIL

Colas:
${QUEUE_OUT}

Oracle:
${DBSIZE_OUT}"
    send_telegram "$MSG"
fi

exit $FAIL
