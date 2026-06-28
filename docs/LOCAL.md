# SGD — Entorno de Desarrollo Local

## Requisitos

- Docker Engine 24+ con Docker Compose v2
- Node.js 20+ (para build del frontend)
- Python 3.11+ (solo si editas OSAI)
- Git

## Estructura de directorios

Clonar los 4 repositorios dentro del mismo directorio padre:

```
proyectos/
├── SDG-Back-api/          # Laravel API (PHP 8.2)
├── SGD-Front/             # Quasar SPA (Vue 3)
├── OSAI/                  # FastAPI microservicio IA (Python)
└── sgd-infra/             # Docker infraestructura (este repo)
```

## 1. Configurar variables de entorno

```bash
cd sgd-infra
cp .env.example .env
nano .env
```

### Variables obligatorias (llenar sí o sí):

| Variable | Valor local recomendado | Notas |
|---|---|---|
| `DOMAIN` | `localhost` | Para desarrollo local |
| `APP_KEY` | `base64:Pdlxkw7Dlxbr+kJXt4JP1ICbSFHWgk9L8VEDnTeOjpg` | Generar con `php artisan key:generate --show` |
| `OSAI_API_TOKEN` | `openssl rand -hex 32` | Token compartido Laravel ↔ OSAI |
| `REVERB_APP_ID` | `240902` | Fijo de seeders |
| `REVERB_APP_KEY` | `wzstepthkcfmlxta3wya` | Fijo de seeders |
| `REVERB_APP_SECRET` | `1bveubiumo5pburks3ab` | Fijo de seeders |
| `PASSPORT_CLIENT_ID` | `3` | Ver con `SELECT id FROM oauth_clients` |
| `PASSPORT_CLIENT_SECRET` | El del `oauth_clients.secret` | Debe ser texto plano, **no hash** |
| `SECRET_KEY` | `openssl rand -hex 32` | Para encriptar localStorage del frontend |

### API Keys de IA (opcional en local, pero necesarias para funcionalidad completa):

| Variable | Dónde obtenerla |
|---|---|
| `GOOGLE_API_KEY` | https://aistudio.google.com |
| `DEEPSEEK_API_KEY` | https://platform.deepseek.com |
| `CO_API_KEY` | https://dashboard.cohere.com |
| `OPENAI_API_KEY` | https://platform.openai.com |
| `OPENROUTER_API_KEY` | https://openrouter.ai |

### Backblaze B2 (almacenamiento de archivos, opcional en local):

| Variable | Valor |
|---|---|
| `B2_KEY_ID` | De consola Backblaze B2 |
| `B2_APPLICATION_KEY` | De consola Backblaze B2 |
| `B2_BUCKET` | `sgd-mr7` (o el que crees) |
| `B2_ENDPOINT` | `https://s3.us-east-005.backblazeb2.com` |
| `B2_REGION` | `us-east-005` |

## 2. Iniciar contenedores

```bash
# Desde sgd-infra/
docker compose up -d
```

Esto levanta 10 servicios:

| Contenedor | Puerto interno | Propósito |
|---|---|---|
| `sgd-oracle` | 1521 | Base de datos Oracle XE |
| `sgd-redis` | 6379 | Cache y sesiones |
| `sgd-app` | 9000 | Laravel PHP-FPM |
| `sgd-reverb` | 8080 | WebSocket server |
| `sgd-worker-default` | — | Cola de jobs (default) |
| `sgd-worker-pqrsd` | — | Cola de jobs (PQRSD-AI) |
| `sgd-scheduler` | — | Cron de Laravel |
| `sgd-osai` | 8000 | FastAPI microservicio IA |
| `sgd-nginx` | 80, 443 | Reverse proxy + frontend SPA |
| `sgd-portainer` | 9000 | Dashboard Docker (solo localhost) |

### Oracle del host (opcional)

Si tienes Oracle XE corriendo en el host con usuario `SGD_MR7`, puerto `1522`, servicio `FREEPDB1`:

- El archivo `docker-compose.override.yml` ya detecta esto y configura la conexión.
- Los workers y scheduler también se configuran automáticamente.
- Verifica que tu Oracle del host tenga el usuario `SGD_MR7`.

**Para desconectar Oracle del host** (usar el contenedor Oracle en su lugar):

```bash
mv docker-compose.override.yml docker-compose.override.yml.bak
docker compose up -d oracle-xe
# Esperar ~2 minutos a que Oracle XE arranque
docker compose up -d
```

## 3. Setup de Laravel

```bash
bash scripts/deploy-laravel.sh
```

Este script ejecuta automáticamente:
1. Espera a que Oracle esté listo
2. `php artisan migrate --force` — todas las migraciones (151)
3. `php artisan passport:keys --force` — solo si no existen (persistencia)
4. `php artisan passport:client --personal` — crea cliente personal si no existe
5. `php artisan storage:link` — symlink de storage público
6. `php artisan config:cache`, `route:cache`, `view:cache`, `event:cache`
7. `php artisan queue:restart` — reinicia workers

### Seeders (solo primera vez)

Si la base está vacía:

```bash
docker compose exec app php artisan db:seed --force
```

Esto crea:
- Usuario admin: `SytemasMR7` / `System_mr7*0707`
- Permisos, roles, módulos, secciones
- Datos de prueba (entidades, dependencias, etc.)

## 4. Build del frontend

```bash
bash scripts/deploy-front.sh
```

Este script:
1. `npm ci` — instala dependencias exactas
2. `NODE_ENV=production npm run build` — compila SPA
3. Genera `dist/spa/config.json` automáticamente desde `.env`:

```json
{
  "API_URL": "/api/",
  "REVERB_APP_KEY": "wzstepthkcfmlxta3wya",
  "REVERB_HOST": "localhost",
  "REVERB_PORT": "80",
  "REVERB_SCHEME": "http",
  "REVERB_WSPATH": "/ws",
  "SECRET_KEY": "..."
}
```

4. Recrea nginx (bind mount fix)

### Modo desarrollo (hot-reload)

Si prefieres trabajar con hot-reload en vez de el build:

```bash
cd ../SGD-Front
npm ci
npm run dev
```

Esto arranca el dev server de Quasar en `http://localhost:3000`. La API sigue yendo contra nginx (`http://localhost/api/`).

## 5. Acceso

| Servicio | URL |
|---|---|
| Frontend SPA | http://localhost |
| Laravel API | http://localhost/api |
| Health check | http://localhost/api/health |
| OSAI | http://localhost/osai-api/info |
| WebSocket | ws://localhost/ws |
| Portainer | http://localhost:9001 (solo SSH tunnel) |

### Usuario por defecto

| Campo | Valor |
|---|---|
| Username | `SytemasMR7` |
| Email | `SistemasMR7@example.com` |
| Password | `System_mr7*0707` |
| Rol | `system_admin` |

## 6. Comandos útiles

```bash
# Logs en vivo
docker compose logs -f app
docker compose logs -f nginx
docker compose logs -f reverb
docker compose logs -f worker-default
docker compose logs -f worker-pqrsd
docker compose logs -f osai

# Artisan
docker compose exec app php artisan tinker
docker compose exec app php artisan route:list
docker compose exec app php artisan queue:restart

# Healthcheck
bash scripts/healthcheck.sh

# Backup manual
bash scripts/backup.sh

# Detener todo
docker compose down

# Reconstruir imágenes (después de cambios en Dockerfile)
docker compose build app osai
docker compose up -d
```

## 7. Referencia rápida de rutas API

Todas las rutas están agrupadas bajo `/api/`:

| Ruta | Método | Autenticación | Propósito |
|---|---|---|---|
| `/api/auth/login` | POST | No | Iniciar sesión |
| `/api/auth/logout` | POST | Bearer | Cerrar sesión |
| `/api/health` | GET | No | Health check |
| `/api/v1/sections` | GET | Bearer | Secciones y módulos |
| `/api/v1/admin/users` | CRUD | Bearer + admin | Usuarios |
| `/api/v1/documents` | CRUD | Bearer | Documentos |
| `/api/v1/electronic-records` | CRUD | Bearer | Expedientes |
| `/api/webhooks/...` | POST | Token | Webhooks de OSAI |
| `/broadcasting/auth` | POST | Bearer | Auth de WebSocket |

Para ver todas las rutas:

```bash
docker compose exec app php artisan route:list
```

## 8. Solución de problemas comunes

### Nginx 500 en rutas SPA
**Causa:** El `npm run build` borró/recreó `dist/spa/` y el bind mount de Docker se rompió.
**Solución:**
```bash
docker compose rm -f nginx
docker compose up -d nginx
```

### Login 500 "Server Error"
**Causa:** `APP_DEBUG=false` o Passport keys faltantes.
**Solución:**
```bash
docker compose exec app php artisan passport:keys --force
# Verificar APP_DEBUG en .env y override
```

### WebSocket no conecta
**Causa:** `config.json` tiene puerto/host incorrecto.
**Solución:** Re-ejecutar `bash scripts/deploy-front.sh` para regenerar `config.json`.

### Oracle no arranca
**Causa:** Falta de memoria o puerto ocupado.
**Solución:**
```bash
docker compose logs oracle-xe
# Verificar que el puerto 1521/1522 esté libre
```

### "Class not found" en rutas
**Causa:** Opcache de PHP-FPM con versión cacheada.
**Solución:**
```bash
docker compose restart app
```
