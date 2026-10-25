# Escalabilidad y Rendimiento — SGD

> Documento de referencia para revisar y ajustar el despliegue ante cambios de
> carga o de hardware. Complementa `AUDITORIA-DESPLIEGUE.md` y las reglas de
> `AGENTS.md`.

## 1. Modelo de despliegue (regla de arquitectura)

**Un municipio por instancia de la app.**

- El sistema SGD está diseñado para servir **un solo municipio** (Maripí,
  Pamplona, etc.) por instancia desplegada.
- La escala NO se resuelve haciendo más grande un solo VPS indefinidamente,
  sino **agregando instancias** (cada una con su propio `sgd-infra/`).
- Toda la configuración de rendimiento es **parametrizable vía `sgd-infra/.env`**
  para que una misma instancia pueda moverse a un VPS mayor cambiando solo
  variables (sin tocar código).

## 2. Matriz de escala por tamaño de VPS

Defaults actuales pensados para un **Contabo Cloud VPS M (8GB RAM, 4 vCPU)**.

| Variable                  | 8GB/4vCPU (actual) | 16GB/6vCPU | 32GB/8vCPU |
|---------------------------|--------------------|------------|------------|
| `PHP_FPM_MAX_CHILDREN`    | 15                 | 25         | 40         |
| `PHP_FPM_START_SERVERS`   | 4                  | 6          | 8          |
| `PHP_FPM_MAX_SPARE_SERVERS` | 8                | 12         | 18         |
| `MEM_LIMIT_APP`           | 2g                 | 4g         | 8g         |
| `MEM_LIMIT_OSAI`          | 2g                 | 4g         | 6g         |
| `OSAI_WORKERS`            | 1                  | 2          | 3          |
| `WORKER_PQRSD_REPLICAS`   | 1                  | 2          | 3          |
| `WORKER_DEFAULT_REPLICAS` | 1                  | 1          | 2          |
| `MEM_LIMIT_POSTGRES`      | 1g                 | por medir  | por medir  |

> Con **1 municipio** (30-60 usuarios concurrentes) los defaults de 8GB son
> suficientes.
> La matriz superior es para cuando un municipio grande (o varios
> procesos simultáneos de IA) lo exija.

## 3. Tabla de variables de rendimiento

| Variable | Default | Qué controla | Cómo ajustar |
|---|---|---|---|
| `PHP_FPM_MAX_CHILDREN` | 15 | Máximo de requests simultáneos de la API Laravel | ~2 por GB de `MEM_LIMIT_APP` |
| `PHP_FPM_START_SERVERS` | 4 | Workers PHP arrancados al inicio | ¼ de max_children |
| `PHP_FPM_MIN_SPARE_SERVERS` | 2 | Workers mínimos inactivos | bajo |
| `PHP_FPM_MAX_SPARE_SERVERS` | 8 | Workers máx inactivos | la mitad de max_children |
| `QUEUE_RETRY_AFTER` | 600 | Tiempo antes de re-despachar un job | **Debe ser > timeout del job IA más largo (180)** |
| `WORKER_PQRSD_REPLICAS` | 1 | Workers de la cola `pqrsd-ai` | Subir si hay backlog de análisis IA |
| `WORKER_DEFAULT_REPLICAS` | 1 | Workers de la cola `default` | Subir con carga transaccional |
| `OSAI_WORKERS` | 1 | Workers uvicorn de FastAPI | Ver ADR-05 |
| `OSAI_BACKGROUND_WORKER` | true | Ejecuta cola offline + webhook retry | Solo true en 1 instancia |
| `REDIS_MAXMEMORY` | 256mb | Máxima RAM de Redis (claves) | Ajustar a datos cacheados |
| `MEM_LIMIT_POSTGRES` | 1g | RAM máxima de PostgreSQL | Subir si `docker stats` lo muestra al tope |
| `DB_SIZE_ALERT_GB` | 20 | Tamaño de la base desde el que `healthcheck.sh` marca FAIL | Según el disco del VPS |
| `MEM_LIMIT_*` | varios | RAM máxima por contenedor | Ver matriz |

## 4. Techos duros (límites de la plataforma)

| Componente | Techo | Consecuencia al alcanzarlo |
|---|---|---|
| PostgreSQL 17 | Sin tope de datos ni de CPU por licencia; manda `MEM_LIMIT_POSTGRES` y el disco | Consultas lentas si le falta RAM; alerta de `DB_SIZE_ALERT_GB` |
| PHP-FPM pool | `pm.max_children` | Si se satura → timeouts 502/504 |
| OSAI uvicorn | `--workers` + semáforo `MAX_CONCURRENT_DOCS=5` | Backlog de análisis IA |
| Reverb | 1 proceso, `scaling.enabled=false` | Saturación de WebSockets con muchos usuarios |

**Conclusión:** PostgreSQL no tiene techo de datos ni de CPU por licencia.
El límite es la RAM y el disco del VPS. Si un municipio los
supera, subir de VPS (Sección 7) o levantar una instancia adicional.

## 5. Runbook: qué verificar ante degradación en horas pico

Síntoma "el sistema no responde" → en orden:

```bash
# 1. ¿OOM killer mató un contenedor? (causa nº1 de "se cayó")
docker stats                     # ver RAM de cada servicio
dmesg | grep -i "oom\|killed"    # confirma OOM
free -h                          # memoria del host

# 2. ¿FPM saturado? (5→ahora 15 workers)
docker compose exec -T app php-fpm -t -q && echo "pool OK"
docker compose exec -T app ps aux | grep php-fpm | wc -l   # workers activos

# 3. ¿Backlog de colas? (jobs en Redis)
docker compose exec -T redis redis-cli llen queues:pqrsd-ai
docker compose exec -T redis redis-cli llen queues:default
docker compose exec -T redis redis-cli info keyspace          # DBSIZE de sesiones

# 4. ¿Base de datos lenta o llena?
docker compose exec -T postgres pg_isready -U sgd -d sgd
docker compose exec -T -u www-data -e HOME=/tmp app php artisan db:size   # db_size: N GB

# 5. ¿OSAI colapsado?
docker compose logs --tail=50 osai
```

**Reglas generales:**
- Si hay OOM → subir `MEM_LIMIT_*` correspondiente en `.env` y recrear.
- Si la cola `pqrsd-ai` acumula cientos de jobs → subir `WORKER_PQRSD_REPLICAS`.
- Si FPM se satura → subir `PHP_FPM_MAX_CHILDREN` (respetando RAM).
- Si la base responde lento en consultas → revisar índices (Sección 8).

## 6. ADR — Decisiones registradas

### ADR-01: Colas y sesiones en Redis (no en la base de datos)
- **Contexto (histórico):** producción usaba `QUEUE_CONNECTION=database` y
  `SESSION_DRIVER=database` → cada request y cada poll de job golpeaba la base.
- **Decisión:** `QUEUE_CONNECTION=redis`, `SESSION_DRIVER=redis`,
  `CACHE_DRIVER=redis` (Redis ya estaba corriendo).
- **Por qué:** quita carga transaccional de la base, polling instantáneo
  (`--sleep=1`), y colas/sesiones no compiten por la memoria de la base.
  Regla: colas y sesiones nunca en la base.

### ADR-02: `retry_after` > timeout de los jobs de IA
- **Contexto:** `retry_after=90` < `timeout=180` de `ProcessDocumentJob` y el
  default de `queue:work --timeout=60` mataban/re-despachaban jobs IA en curso.
- **Decisión:** `QUEUE_RETRY_AFTER=600` y `--timeout=200` en `worker-pqrsd`.
- **Por qué:** evita llamadas IA duplicadas (costo $ y carga ×3 por documento).

### ADR-03: Pool PHP-FPM parametrizado (reemplaza default de 5 workers)
- **Contexto:** la imagen oficial `php:8.2-fpm` trae `pm.max_children=5`, que se
  satura con ráfagas de uploads/consultas en hora pico.
- **Decisión:** nuevo `php/www.conf` con `pm=dynamic`, `max_children=15` (env),
  `pm.max_requests=500` (anti-fuga de memoria).
- **Por qué:** más concurrencia sin cambiar infraestructura; `max_requests`
  recicla workers y previene OOM por fuga lenta.

### ADR-04: Límites de memoria por contenedor
- **Contexto:** sin `mem_limit`, un pico de OSAI (pandas/PyMuPDF) podía matar
  la base de datos o Redis por OOM (cascada).
- **Decisión:** `mem_limit` en cada servicio vía `MEM_LIMIT_*`.
- **Por qué:** si un contenedor excede su tope, Docker mata solo a ese, no a la
  app completa.

### ADR-05: Multi-worker de OSAI con claim atómico
- **Contexto:** `--workers N` duplicaría los background tasks (cola offline,
  webhook retry) y el claim de jobs no era atómico.
- **Decisión:** flag `BACKGROUND_WORKER` (solo 1 instancia lo corre) + claim
  atómico (`BEGIN IMMEDIATE` → `status='processing'`) en `offline_queue.py`.
- **Por qué:** permite escalar OSAI a 2-3 workers sin procesar el mismo job dos
  veces. Default sigue siendo 1 worker (suficiente para 1 municipio).
- **Nota:** al subir `OSAI_WORKERS>1`, desactivar `OSAI_BACKGROUND_WORKER` en
  las instancias extra (o aceptar que corran background tasks; Laravel es
  idempotente para los webhooks).

## 7. Procedimiento de upgrade a un VPS mayor

1. Comprar el nuevo VPS (ver matriz de la Sección 2).
2. Migrar datos (base PostgreSQL con `backup.sh` → `restore.sh`, volúmenes de
   app/storage) — mismo flujo que un VPS nuevo.
3. Editar `sgd-infra/.env`: aplicar la fila de la matriz del nuevo tamaño.
4. Re-deploy:
   ```bash
   docker compose up -d --force-recreate
   bash scripts/deploy-laravel.sh
   bash scripts/healthcheck.sh
   ```
5. Verificar memoria libre con `free -h` y `docker stats`.

No requiere cambios de código: todo es `.env`.

## 8. Índices recomendados

Validar con `EXPLAIN` (en PostgreSQL, `EXPLAIN ANALYZE`) los queries del dashboard (`DashboardController`) y
agregar índices donde falten:

```sql
-- Sesiones (si se usa el driver database en algún ambiente)
CREATE INDEX idx_sessions_user ON sessions(user_id);
-- Jobs (si se usa el driver database en algún ambiente)
CREATE INDEX idx_jobs_queue_reserved ON jobs(queue, reserved_at);
-- Documentos por dependencia/estado (dashboard)
CREATE INDEX idx_documents_dep_status ON documents(dependency_id, current_status, updated_at);
-- Tareas vencidas
CREATE INDEX idx_document_tasks_due ON document_tasks(due_date, status);
```

## 9. Base de datos: PostgreSQL 17 + pgvector

- **Memoria:** Postgres arranca con `MEM_LIMIT_POSTGRES=1g`.
- **Tamaño:** `healthcheck.sh` marca FAIL si la base pasa de `DB_SIZE_ALERT_GB` (20).
- **Esquema:** los `varchar` se miden en caracteres; la regla `MaxBytes` (bytes) se
  conserva y es más estricta.
- **Historia:** el traslado desde la base anterior está en `docs/PRODUCTION.md`,
  sección 6b (nota histórica).
- **Trabajo futuro:** ajustar parámetros de Postgres (memoria compartida, memoria
  por consulta, conexiones) según mediciones reales en producción. Aún no hay
  valores medidos: no cambiarlos a ciegas.

## 10. Rollback de cambios de rendimiento

Todos los cambios de este doc son **configuración/env, sin migraciones** → el
rollback es completo y sin pérdida de datos:

```bash
# 1. En cada repo: revertir el commit
git revert HEAD   # en SDG-Back-api, OSAI, sgd-infra

# 2. VPS: pull + recrear contenedores
git pull origin <rama>
docker compose up -d --force-recreate
bash scripts/deploy-laravel.sh

# 3. Verificar
bash scripts/healthcheck.sh
```

Si se revierte el switch a Redis, los jobs encolados en Redis se pierden (pero
los lotes de IA se re-disparan con `POST /v1/batches/{id}/retry-analysis`).