#!/bin/bash
# scripts/restore.sh — Restaurar backups SGD desde restic (offsite) o local
# Ejecutar desde sgd-infra/
set -euo pipefail

# Cargar .env si existe
if [ -f .env ]; then
    set -a; source .env; set +a
fi

# Detectar compose activo
if [ -f docker-compose.dockploy.yml ]; then
    COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.dockploy.yml}"
else
    COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
fi
export COMPOSE_FILE

usage() {
    cat <<USAGE
Uso: bash scripts/restore.sh [opciones]

Opciones:
  --target=ensayo|produccion   Destino del restore (obligatorio).
                               'ensayo' restaura en la base sgd_restore_test sin tocar prod.
                               'produccion' exige confirmación interactiva.
  --snapshot=ID                Snapshot restic a restaurar (default: latest).
  --local=DIR                  Usar backups locales de DIR en vez de restic.
  --skip-db                    No restaurar la base de datos.
  --skip-storage               No restaurar el storage de Laravel.
  --skip-osai                  No restaurar la data de OSAI.
  --help                       Mostrar esta ayuda.

Ejemplos:
  bash scripts/restore.sh --target=ensayo --snapshot=latest
  bash scripts/restore.sh --target=produccion --snapshot=22f45b18
  bash scripts/restore.sh --target=ensayo --local=/home/deploy/backups
USAGE
    exit 0
}

TARGET=""
SNAPSHOT="latest"
LOCAL_DIR=""
SKIP_DB=0
SKIP_STORAGE=0
SKIP_OSAI=0

for arg in "$@"; do
    case $arg in
        --target=*) TARGET="${arg#*=}" ;;
        --snapshot=*) SNAPSHOT="${arg#*=}" ;;
        --local=*) LOCAL_DIR="${arg#*=}" ;;
        --skip-db) SKIP_DB=1 ;;
        --skip-storage) SKIP_STORAGE=1 ;;
        --skip-osai) SKIP_OSAI=1 ;;
        --help|-h) usage ;;
        *) echo "Opción desconocida: $arg"; usage ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "ERROR: --target es obligatorio (ensayo o produccion)."
    usage
fi

if [ "$TARGET" != "ensayo" ] && [ "$TARGET" != "produccion" ]; then
    echo "ERROR: --target debe ser 'ensayo' o 'produccion'."
    exit 1
fi

if [ "$TARGET" = "produccion" ]; then
    echo ""
    echo "⚠️  VAS A RESTAURAR SOBRE PRODUCCIÓN. Esto sobreescribe datos reales."
    echo "    Escribe exactamente 'RESTAURAR PRODUCCION' para confirmar:"
    read -r confirm
    if [ "$confirm" != "RESTAURAR PRODUCCION" ]; then
        echo "Abortado."
        exit 1
    fi
fi

START_TIME=$(date +%s)
RESTORE_DIR="/tmp/restore_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESTORE_DIR"

echo "=== Restore SGD — $(date) ==="
echo "Target: $TARGET"
echo "Directorio temporal: $RESTORE_DIR"

# ============================================
# 1. Obtener los archivos de backup
# ============================================
if [ -n "$LOCAL_DIR" ]; then
    echo ""
    echo "--- Usando backups locales de $LOCAL_DIR ---"
    cp "$LOCAL_DIR"/sgd_backup_*.pgdump "$RESTORE_DIR/" 2>/dev/null || true
    cp "$LOCAL_DIR"/laravel_storage_*.tar.gz "$RESTORE_DIR/" 2>/dev/null || true
    cp "$LOCAL_DIR"/osai_data_*.tar.gz "$RESTORE_DIR/" 2>/dev/null || true
else
    echo ""
    echo "--- Descargando snapshot $SNAPSHOT desde restic ---"
    if [ -z "${RESTIC_REPOSITORY:-}" ] || [ -z "${RESTIC_PASSWORD:-}" ]; then
        echo "ERROR: faltan RESTIC_REPOSITORY / RESTIC_PASSWORD en .env"
        exit 1
    fi
    echo "Snapshots disponibles:"
    restic snapshots --tag sgd 2>&1 | head -20
    echo ""
    restic restore "$SNAPSHOT" --target "$RESTORE_DIR" --tag sgd 2>&1
    # restic restaura la estructura completa; los archivos quedan bajo la ruta original
    NESTED=$(find "$RESTORE_DIR" -name "sgd_backup_*" -printf '%h\n' | head -1)
    if [ -n "$NESTED" ] && [ "$NESTED" != "$RESTORE_DIR" ]; then
        mv "$NESTED"/* "$RESTORE_DIR/" 2>/dev/null || true
    fi
fi

# Encontrar los archivos más recientes
PGDUMP=$(ls -t "$RESTORE_DIR"/sgd_backup_*.pgdump 2>/dev/null | head -1 || true)
PG_USER="${POSTGRES_USER:-sgd}"
PG_DB="${POSTGRES_DB:-sgd}"
PG_TEST_DB="sgd_restore_test"
STORAGE_TAR=$(ls -t "$RESTORE_DIR"/laravel_storage_*.tar.gz 2>/dev/null | head -1 || true)
OSAI_TAR=$(ls -t "$RESTORE_DIR"/osai_data_*.tar.gz 2>/dev/null | head -1 || true)

echo ""
echo "Archivos encontrados:"
[ -n "$PGDUMP" ] && echo "  Postgres dump: $(basename "$PGDUMP") ($(ls -lh "$PGDUMP" | awk '{print $5}'))" || echo "  Postgres dump: NO ENCONTRADO"
[ -n "$STORAGE_TAR" ] && echo "  Storage tar: $(basename "$STORAGE_TAR") ($(ls -lh "$STORAGE_TAR" | awk '{print $5}'))" || echo "  Storage tar: NO ENCONTRADO"
[ -n "$OSAI_TAR" ] && echo "  OSAI tar: $(basename "$OSAI_TAR") ($(ls -lh "$OSAI_TAR" | awk '{print $5}'))" || echo "  OSAI tar: NO ENCONTRADO"

# ============================================
# 2. Restaurar la base de datos (Postgres)
# ============================================
# Servicios que escriben en la base: se detienen mientras se restaura sobre producción.
ESCRITORES="worker-default worker-pqrsd worker-filing worker-chat scheduler reverb"
ARTISAN="docker compose exec -T -u www-data -e HOME=/tmp app php artisan"

# pg_restore en una sola transacción y deteniéndose en el primer error: si falla, la base queda como estaba.
# Devuelve el código de pg_restore; el detalle queda en $RESTORE_DIR/pg_restore.log.
restaurar_base() {
    local base="$1"; shift
    local rc=0
    docker compose exec -T postgres pg_restore -U "$PG_USER" -d "$base" --single-transaction --exit-on-error "$@" \
        < "$PGDUMP" > "$RESTORE_DIR/pg_restore.log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "ERROR: pg_restore falló (código $rc). La transacción se revirtió: $base quedó como estaba."
        tail -20 "$RESTORE_DIR/pg_restore.log"
    fi
    return "$rc"
}

volver_a_levantar() {
    echo "Levantando de nuevo los servicios y quitando el mantenimiento..."
    docker compose up -d --no-deps $ESCRITORES >/dev/null 2>&1 || echo "WARN: no se pudieron levantar todos los servicios ($ESCRITORES)"
    $ARTISAN up >/dev/null 2>&1 || echo "WARN: no se pudo quitar el modo mantenimiento (php artisan up)"
}

if [ "$SKIP_DB" -eq 0 ] && [ -n "$PGDUMP" ]; then
    echo ""
    echo "--- Restaurando Postgres ---"
    if [ "$TARGET" = "ensayo" ]; then
        PG_TARGET_DB="$PG_TEST_DB"
        echo "Base de ensayo $PG_TARGET_DB (mismo servidor, sin tocar $PG_DB)..."
        docker compose exec -T postgres dropdb -U "$PG_USER" --if-exists "$PG_TARGET_DB"
        docker compose exec -T postgres createdb -U "$PG_USER" "$PG_TARGET_DB"
        restaurar_base "$PG_TARGET_DB" --no-owner || { echo "El ensayo falló: revise $RESTORE_DIR/pg_restore.log"; exit 1; }
    else
        PG_TARGET_DB="$PG_DB"
        echo "Mantenimiento: la app deja de atender y se detienen $ESCRITORES..."
        $ARTISAN down --retry=60 >/dev/null || { echo "ERROR: no se pudo poner la app en mantenimiento; no se restauró nada."; exit 1; }
        trap volver_a_levantar EXIT
        docker compose stop $ESCRITORES >/dev/null
        echo "Restaurando sobre $PG_TARGET_DB (pg_restore --clean, conserva los dueños del respaldo)..."
        restaurar_base "$PG_TARGET_DB" --clean --if-exists || exit 1
        echo "Base restaurada."
        # Opcache y caches con la base nueva; el trap levanta los servicios al salir.
        $ARTISAN optimize:clear >/dev/null 2>&1 || true
    fi
elif [ "$SKIP_DB" -eq 1 ]; then
    echo ""
    echo "--- Base de datos: omitida (--skip-db) ---"
fi

# ============================================
# 3. Restaurar Storage de Laravel
# ============================================
if [ "$SKIP_STORAGE" -eq 0 ] && [ -n "$STORAGE_TAR" ]; then
    echo ""
    echo "--- Restaurando storage de Laravel ---"
    if [ "$TARGET" = "produccion" ]; then
        cat "$STORAGE_TAR" | docker compose exec -T app tar xzf - -C /var/www/html/storage 2>&1
        echo "Storage restaurado en el volumen de producción."
    else
        mkdir -p "$RESTORE_DIR/storage_check"
        tar xzf "$STORAGE_TAR" -C "$RESTORE_DIR/storage_check"
        echo "Storage extraído en $RESTORE_DIR/storage_check (ensayo, no se tocó producción)."
    fi

    # Verificar oauth keys
    if [ "$TARGET" = "produccion" ]; then
        if docker compose exec -T app test -f /var/www/html/storage/oauth-private.key; then
            echo "  ✅ oauth-private.key presente"
        else
            echo "  ❌ oauth-private.key NO encontrado — ALERTA"
        fi
    else
        if [ -f "$RESTORE_DIR/storage_check/oauth-private.key" ]; then
            echo "  ✅ oauth-private.key presente en el backup"
        else
            echo "  ❌ oauth-private.key NO encontrado en el backup — ALERTA"
        fi
    fi
elif [ "$SKIP_STORAGE" -eq 1 ]; then
    echo ""
    echo "--- Storage: omitido (--skip-storage) ---"
fi

# ============================================
# 4. Restaurar data OSAI
# ============================================
if [ "$SKIP_OSAI" -eq 0 ] && [ -n "$OSAI_TAR" ]; then
    echo ""
    echo "--- Restaurando data OSAI ---"
    if [ "$TARGET" = "produccion" ]; then
        cat "$OSAI_TAR" | docker compose exec -T osai tar xzf - -C / 2>&1
        echo "OSAI data restaurada."
    else
        mkdir -p "$RESTORE_DIR/osai_check"
        tar xzf "$OSAI_TAR" -C "$RESTORE_DIR/osai_check" 2>/dev/null || true
        echo "OSAI data extraída en $RESTORE_DIR/osai_check (ensayo)."
    fi
elif [ "$SKIP_OSAI" -eq 1 ]; then
    echo ""
    echo "--- OSAI: omitido (--skip-osai) ---"
fi

# ============================================
# 5. Validación con conteos
# ============================================
echo ""
echo "--- Validación ---"

if [ "$SKIP_DB" -eq 0 ] && [ -n "$PGDUMP" ]; then
    echo "Conteos de tablas principales ($PG_TARGET_DB):"
    for table in documents processed_documents users; do
        count=$(docker compose exec -T postgres psql -U "$PG_USER" -d "$PG_TARGET_DB" -At -c "SELECT count(*) FROM \"$table\"" 2>/dev/null | tail -1)
        echo "  $table: ${count:-?}"
    done
fi

# ============================================
# 6. Limpieza de ensayo
# ============================================
if [ "$TARGET" = "ensayo" ]; then
    echo ""
    echo "--- Limpieza ---"
    echo "Para eliminar la base de ensayo: docker compose exec -T postgres dropdb -U $PG_USER $PG_TEST_DB"
    echo "Para eliminar archivos temporales: rm -rf $RESTORE_DIR"
fi

# ============================================
# Resumen
# ============================================
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
MINUTES=$((ELAPSED / 60))
SECONDS=$((ELAPSED % 60))

echo ""
echo "=== Restore completado ==="
echo "Tiempo total: ${MINUTES}m ${SECONDS}s"
echo "Target: $TARGET"
echo "Fuente: ${LOCAL_DIR:-restic snapshot $SNAPSHOT}"
echo ""
echo "⚠️  Si restauraste producción, ejecuta: bash scripts/healthcheck.sh"
