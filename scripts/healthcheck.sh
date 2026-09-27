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
FAILED_CHECKS=""

check() {
    local name="$1"
    local cmd="$2"
    if eval "$cmd" &>/dev/null; then
        echo "  [OK] $name"
        PASS=$((PASS+1))
    else
        echo "  [FAIL] $name"
        FAIL=$((FAIL+1))
        FAILED_CHECKS="${FAILED_CHECKS}- ${name}\n"
    fi
}

# Token/chat hardcodeados como fallback (SGD-096: se rotan vía BotFather y se
# mueven a variables de entorno en la fase de secretos). Centralizado aquí
# para no repetir el bloque curl.
send_telegram() {
    local text="$1"
    local token="${TELEGRAM_BOT_TOKEN:-8706852433:AAF6KVl9fzbehgmJrClbntquTwAdXen7r_U}"
    local chat="${TELEGRAM_CHAT_ID:-5096050646}"
    curl -sf -X POST "https://api.telegram.org/bot$token/sendMessage" \
        --data-urlencode "chat_id=$chat" \
        --data-urlencode "text=$text"
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
    FAILED_CHECKS="${FAILED_CHECKS}- Colas (failed/backlog/mem)\n"
fi

# SGD-061: failed_jobs recientes (última hora) y backlog por cola individual
RECENT_FAILED=$(docker compose exec -T app php artisan tinker --execute="echo \App\Models\FailedJob::where('failed_at','>=',now()->subHour())->count();" 2>/dev/null | tr -d '[:space:]')
if [ -n "$RECENT_FAILED" ] && [ "$RECENT_FAILED" -gt 10 ] 2>/dev/null; then
    echo "  [WARN] $RECENT_FAILED failed_jobs en la última hora"
    FAILED_CHECKS="${FAILED_CHECKS}- ${RECENT_FAILED} failed_jobs recientes (>10)\n"
fi

QUEUE_DEFAULT=$(docker compose exec -T app php artisan tinker --execute="echo \Illuminate\Support\Facades\Redis::llen('queues:default');" 2>/dev/null | tr -d '[:space:]')
QUEUE_PQRSD=$(docker compose exec -T app php artisan tinker --execute="echo \Illuminate\Support\Facades\Redis::llen('queues:pqrsd-ai');" 2>/dev/null | tr -d '[:space:]')
if [ -n "$QUEUE_DEFAULT" ] && [ "$QUEUE_DEFAULT" -gt 50 ] 2>/dev/null; then
    echo "  [WARN] Cola default con $QUEUE_DEFAULT jobs pendientes"
    FAILED_CHECKS="${FAILED_CHECKS}- Cola default: ${QUEUE_DEFAULT} pendientes (>50)\n"
fi
if [ -n "$QUEUE_PQRSD" ] && [ "$QUEUE_PQRSD" -gt 50 ] 2>/dev/null; then
    echo "  [WARN] Cola pqrsd-ai con $QUEUE_PQRSD jobs pendientes"
    FAILED_CHECKS="${FAILED_CHECKS}- Cola pqrsd-ai: ${QUEUE_PQRSD} pendientes (>50)\n"
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
    FAILED_CHECKS="${FAILED_CHECKS}- Tamaño Oracle\n"
fi

echo ""
echo "Resultado: $PASS OK, $FAIL FAIL"
[ "$FAIL" -eq 0 ] && echo "Todos los servicios están saludables." || echo "Hay servicios con problemas."

# --- Telegram alert si hay chequeos fallidos ---
if [ "$FAIL" -gt 0 ]; then
    MSG="🚨 SGD ALERTA
$(date '+%Y-%m-%d %H:%M:%S')
✅ OK: $PASS  |  ❌ FAIL: $FAIL

━━ Fallos ━━
$(echo -e "$FAILED_CHECKS")
━━ Colas ━━
${QUEUE_OUT}

━━ Oracle ━━
${DBSIZE_OUT}"
    send_telegram "$MSG"
fi

exit $FAIL
