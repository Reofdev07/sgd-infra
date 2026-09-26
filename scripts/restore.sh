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
                               'ensayo' levanta un Oracle efímero sin tocar prod.
                               'produccion' exige confirmación interactiva.
  --snapshot=ID                Snapshot restic a restaurar (default: latest).
  --local=DIR                  Usar backups locales de DIR en vez de restic.
  --skip-oracle                No restaurar la base de datos Oracle.
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
SKIP_ORACLE=0
SKIP_STORAGE=0
SKIP_OSAI=0

for arg in "$@"; do
    case $arg in
        --target=*) TARGET="${arg#*=}" ;;
        --snapshot=*) SNAPSHOT="${arg#*=}" ;;
        --local=*) LOCAL_DIR="${arg#*=}" ;;
        --skip-oracle) SKIP_ORACLE=1 ;;
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
    cp "$LOCAL_DIR"/sgd_backup_*.dmp "$RESTORE_DIR/" 2>/dev/null || true
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
    NESTED=$(find "$RESTORE_DIR" -name "sgd_backup_*.dmp" -printf '%h\n' | head -1)
    if [ -n "$NESTED" ] && [ "$NESTED" != "$RESTORE_DIR" ]; then
        mv "$NESTED"/* "$RESTORE_DIR/" 2>/dev/null || true
    fi
fi

# Encontrar los archivos más recientes
DMP=$(ls -t "$RESTORE_DIR"/sgd_backup_*.dmp 2>/dev/null | head -1)
STORAGE_TAR=$(ls -t "$RESTORE_DIR"/laravel_storage_*.tar.gz 2>/dev/null | head -1)
OSAI_TAR=$(ls -t "$RESTORE_DIR"/osai_data_*.tar.gz 2>/dev/null | head -1)

echo ""
echo "Archivos encontrados:"
[ -n "$DMP" ] && echo "  Oracle dump: $(basename "$DMP") ($(ls -lh "$DMP" | awk '{print $5}'))" || echo "  Oracle dump: NO ENCONTRADO"
[ -n "$STORAGE_TAR" ] && echo "  Storage tar: $(basename "$STORAGE_TAR") ($(ls -lh "$STORAGE_TAR" | awk '{print $5}'))" || echo "  Storage tar: NO ENCONTRADO"
[ -n "$OSAI_TAR" ] && echo "  OSAI tar: $(basename "$OSAI_TAR") ($(ls -lh "$OSAI_TAR" | awk '{print $5}'))" || echo "  OSAI tar: NO ENCONTRADO"

# ============================================
# 2. Restaurar Oracle
# ============================================
if [ "$SKIP_ORACLE" -eq 0 ] && [ -n "$DMP" ]; then
    echo ""
    echo "--- Restaurando Oracle ---"

    SYSTEM_PASSWORD="${ORACLE_SYSTEM_PASSWORD:-}"
    if [ -z "$SYSTEM_PASSWORD" ]; then
        echo "ERROR: falta ORACLE_SYSTEM_PASSWORD en .env"
        exit 1
    fi

    if [ "$TARGET" = "ensayo" ]; then
        echo "Levantando Oracle de ensayo (puerto 1522, sin tocar producción)..."
        docker run -d --name sgd-restore-oracle \
            -p 1522:1521 \
            -e ORACLE_PASSWORD="$SYSTEM_PASSWORD" \
            --memory=2g \
            container-registry.oracle.com/database/express:21.3.0-xe \
            2>&1 || true

        echo "Esperando a que Oracle de ensayo esté listo (puede tomar ~2 min)..."
        for i in $(seq 1 60); do
            if docker exec sgd-restore-oracle sqlplus -S "SYSTEM/${SYSTEM_PASSWORD}@localhost/XEPDB1" <<< "SELECT 1 FROM DUAL; EXIT;" &>/dev/null; then
                echo "Oracle de ensayo listo."
                break
            fi
            sleep 5
        done

        ORACLE_CONTAINER="sgd-restore-oracle"
    else
        ORACLE_CONTAINER=$(docker compose ps -q oracle-xe)
        if [ -z "$ORACLE_CONTAINER" ]; then
            echo "ERROR: contenedor oracle-xe no está corriendo."
            exit 1
        fi
    fi

    DUMPFILE=$(basename "$DMP")
    docker cp "$DMP" "$ORACLE_CONTAINER:/tmp/$DUMPFILE"

    # Obtener DATA_PUMP_DIR
    DPDIR=$(docker exec "$ORACLE_CONTAINER" sqlplus -S "SYSTEM/${SYSTEM_PASSWORD}@localhost/XEPDB1" <<< "SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT directory_path FROM dba_directories WHERE directory_name = 'DATA_PUMP_DIR';
EXIT;" 2>/dev/null | grep -E '^/' | head -1 | xargs)

    if [ -n "$DPDIR" ]; then
        docker exec "$ORACLE_CONTAINER" cp "/tmp/$DUMPFILE" "$DPDIR/$DUMPFILE"
        docker exec "$ORACLE_CONTAINER" rm -f "/tmp/$DUMPFILE"

        echo "Ejecutando impdp (table_exists_action=replace)..."
        docker exec "$ORACLE_CONTAINER" impdp \
            "\"${DB_USERNAME:-SGD_MR7}/${DB_PASSWORD:-sgd123}@localhost/XEPDB1\"" \
            directory=DATA_PUMP_DIR dumpfile="$DUMPFILE" \
            table_exists_action=replace \
            logfile="restore_$(date +%Y%m%d).log" 2>&1 | tail -10

        docker exec "$ORACLE_CONTAINER" rm -f "$DPDIR/$DUMPFILE"
    else
        echo "ERROR: no se pudo obtener DATA_PUMP_DIR"
    fi
elif [ "$SKIP_ORACLE" -eq 1 ]; then
    echo ""
    echo "--- Oracle: omitido (--skip-oracle) ---"
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

if [ "$SKIP_ORACLE" -eq 0 ]; then
    if [ "$TARGET" = "ensayo" ] && docker ps --filter name=sgd-restore-oracle --format '{{.Names}}' | grep -q sgd-restore-oracle; then
        VALIDATE_CMD="docker exec sgd-restore-oracle sqlplus -S \"${DB_USERNAME:-SGD_MR7}/${DB_PASSWORD:-sgd123}@localhost/XEPDB1\""
    else
        VALIDATE_CMD="docker compose exec -T app php artisan tinker --execute"
    fi

    if [ "$TARGET" = "produccion" ] || ([ "$TARGET" = "ensayo" ] && docker ps --filter name=sgd-restore-oracle --format '{{.Names}}' | grep -q sgd-restore-oracle); then
        echo "Conteos de tablas principales:"
        for table in documents processed_documents users; do
            if [ "$TARGET" = "ensayo" ]; then
                count=$(docker exec sgd-restore-oracle sqlplus -S "${DB_USERNAME:-SGD_MR7}/${DB_PASSWORD:-sgd123}@localhost/XEPDB1" <<< "SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT COUNT(*) FROM ${table};
EXIT;" 2>/dev/null | grep -E '^[0-9]' | head -1 | xargs)
            else
                count=$(docker compose exec -T app php artisan tinker --execute="echo \\App\\Models\\$(echo $table | sed 's/s$//' | sed 's/\b\w/\U&/g')::count();" 2>/dev/null | tail -1)
            fi
            echo "  $table: ${count:-?}"
        done
    fi
fi

# ============================================
# 6. Limpieza de ensayo
# ============================================
if [ "$TARGET" = "ensayo" ]; then
    echo ""
    echo "--- Limpieza ---"
    if docker ps -a --filter name=sgd-restore-oracle --format '{{.Names}}' | grep -q sgd-restore-oracle; then
        echo "Para eliminar el Oracle de ensayo: docker rm -f sgd-restore-oracle"
    fi
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
