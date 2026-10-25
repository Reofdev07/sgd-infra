# SGD — Despliegue en Producción (VPS Contabo)

## Requisitos del VPS

| Recurso | Mínimo | Recomendado |
|---|---|---|
| RAM | 8 GB | 16 GB |
| Disco | 80 GB SSD | 160 GB SSD |
| CPU | 4 cores | 6 cores |
| SO | Ubuntu 22.04 | Ubuntu 24.04 |
| Puertos | 22, 80, 443 | 22, 80, 443 |

## 1. Setup inicial del VPS

Conéctate como **root** y ejecuta el script de bootstrap:

```bash
ssh root@IP_DEL_VPS
```

Copia el script al VPS y ejecútalo:

```bash
# En tu máquina local (si tienes acceso):
scp sgd-infra/scripts/setup-vps.sh root@IP_DEL_VPS:/root/

# O créalo directamente en el VPS con el contenido del archivo
```

```bash
# En el VPS como root:
bash /root/setup-vps.sh
```

Este script:
1. Crea usuario `deploy` con sudo sin contraseña
2. Actualiza el sistema
3. Instala Docker + Docker Compose
4. Instala Node.js 20
5. Instalar fail2ban + herramientas útiles
6. Configura firewall (UFW): solo SSH/HTTP/HTTPS
7. Crea directorio `/home/deploy`

Luego reconéctate como **deploy**:

```bash
ssh deploy@IP_DEL_VPS
```

## 2. Clonar repositorios

```bash
cd /home/deploy
git clone <url-de-SDG-Back-api>
git clone <url-de-SGD-Front>
git clone <url-de-OSAI>
git clone <url-de-sgd-infra>
```

Verifica que quede así:

```
/home/deploy/
├── SDG-Back-api/
├── SGD-Front/
├── OSAI/
└── sgd-infra/
```

## 3. Variables de entorno

### 3.1 Copiar y editar .env

```bash
cd /home/deploy/sgd-infra
cp .env.example .env
nano .env
```

### 3.2 Deshabilitar override local

**IMPORTANTE:** El archivo `docker-compose.override.yml` tiene configuraciones para desarrollo local (`APP_DEBUG=true`, `APP_ENV=local`, Postgres local en el puerto 5433, Oracle del host). En producción debe estar deshabilitado:

```bash
mv docker-compose.override.yml docker-compose.override.yml.bak
```

### 3.3 Guía de llenado del .env

A continuación, cada variable del `.env` explicada en detalle.

#### Dominio

```
DOMAIN=tudominio.com
```

Debe ser el dominio real que apunte al VPS. Controla:
- `APP_URL` y `FRONTEND_URL` en Laravel
- `REVERB_HOST` para WebSocket
- `config.json` del frontend (determina si usa HTTP o HTTPS)
- Certificado SSL

#### Base de datos (PostgreSQL)

La app usa **PostgreSQL 17** (imagen `pgvector/pgvector:pg17`, extensiones `vector` y `unaccent`).
Qué base usa la app se decide **solo** aquí, con las variables `DB_*`. Si no se cambian, la app
sigue en Oracle XE (hasta la limpieza).

```
POSTGRES_PASSWORD=...        # obligatoria: sin ella docker compose no arranca
POSTGRES_USER=sgd
POSTGRES_DB=sgd
DB_SIZE_ALERT_GB=20

DB_CONNECTION=pgsql
DB_HOST=postgres
DB_PORT=5432
DB_DATABASE=sgd
DB_USERNAME=sgd_app          # rol de la app, sin superusuario (ver 6b)
DB_PASSWORD=...              # contraseña de sgd_app
```

- `POSTGRES_PASSWORD`: contraseña del superusuario `sgd` (traslado, respaldos, administración). **Usa una segura.**
- `DB_USERNAME` / `DB_PASSWORD`: rol `sgd_app` de la app, sin superusuario (se crea en 6b, paso 8).
- `POSTGRES_USER` / `POSTGRES_DB`: usuario y base (por defecto `sgd`).
- `DB_SIZE_ALERT_GB`: tamaño de la base desde el que `healthcheck.sh` marca FAIL (por defecto 20).
- El servicio `postgres` no publica puertos: solo lo ve la red interna de Docker.
- La conexión usa `timezone=America/Bogota`; las fechas se guardan como `timestamp` sin zona.

#### Oracle XE (hasta la limpieza)

Oracle sigue en el compose solo como **origen del traslado** de datos. Se quita en la limpieza final.

```
ORACLE_PASSWORD=StrongPassword123!
ORACLE_DB_USERNAME=SGD_MR7
ORACLE_DB_PASSWORD=sgd123
```

- `ORACLE_PASSWORD`: Contraseña del usuario `SYS` y `SYSTEM` en Oracle. **Cámbiala por una segura.**
- `ORACLE_DB_USERNAME` / `ORACLE_DB_PASSWORD`: usuario y contraseña de la app en Oracle. Mientras la app
  siga en Oracle (`DB_CONNECTION=oracle`), estos datos van en `DB_USERNAME` / `DB_PASSWORD`; al pasar a
  Postgres se mueven a `ORACLE_DB_*`.

**Para cambiar el password del usuario SGD_MR7 después del primer arranque (hasta la limpieza):**

```bash
docker compose exec oracle-xe sqlplus SYS/$ORACLE_PASSWORD@XEPDB1 as sysdba
# ALTER USER SGD_MR7 IDENTIFIED BY nuevo_password;
```

#### Laravel APP_KEY

```
APP_KEY=base64:...
```

Clave de encriptación de Laravel. Generar con:

```bash
docker compose run --rm app php artisan key:generate --show
```

Debe ser la **misma** en todos los servicios que usan Laravel (app, workers, scheduler, reverb). No cambiar después del primer deploy o se perderán datos encriptados.

#### Token compartido OSAI ↔ Laravel

```
OSAI_API_TOKEN=...
```

Token secreto compartido entre Laravel y OSAI para autenticar webhooks. Generar con:

```bash
openssl rand -hex 32
```

Debe coincidir con `API_KEY_TOKEN` en el `.env` de OSAI.

#### Reverb (WebSocket)

```
REVERB_APP_ID=240902
REVERB_APP_KEY=wzstepthkcfmlxta3wya
REVERB_APP_SECRET=...
```

- `REVERB_APP_ID` y `REVERB_APP_KEY`: Usar los mismos valores que están en los seeders (no cambiar).
- `REVERB_APP_SECRET`: **Secreto de producción**. Generar con:

```bash
openssl rand -hex 16
```

**No usar el mismo secreto que en desarrollo local.**

#### Passport (OAuth2)

```
PASSPORT_CLIENT_ID=2
PASSPORT_CLIENT_SECRET=...
```

El login (`POST /api/auth/login`) pide el token a `/oauth/token` con **grant `password`**, usando el
cliente de tipo **password** (`oauth_clients.password_client = 1`). Compose pasa estas variables al
contenedor como `PASSPORT_PERSONAL_ACCESS_CLIENT_ID/SECRET` (el nombre es histórico: **no** es el
cliente personal). Si el ID o el secreto no coinciden con la tabla, el login responde error.

- `deploy-laravel.sh` crea los dos clientes si no existen (personal y password). En una base nueva
  quedan como id 1 (personal) y **id 2 (password)**.
- El secreto se guarda en **texto plano** (no se usa `Passport::hashClientSecrets()`): 40 caracteres.
- **Nunca imprimir el secreto** en terminal, logs ni commits. Pasarlo directo de la base al `.env`:

```bash
cd /home/deploy/sgd-infra && export COMPOSE_FILE=docker-compose.dockploy.yml
A="docker compose exec -T -u www-data -e XDG_CONFIG_HOME=/tmp -e XDG_DATA_HOME=/tmp -e XDG_RUNTIME_DIR=/tmp app"
cp -p .env .env.respaldo-$(date +%Y%m%d) && chmod 600 .env.respaldo-*
S=$($A php artisan tinker --execute='echo PHP_EOL."SECRET=".DB::table("oauth_clients")->where("password_client",1)->value("secret").PHP_EOL;' 2>/dev/null | grep -oE '^SECRET=[A-Za-z0-9]+' | cut -d= -f2)
I=$($A php artisan tinker --execute='echo PHP_EOL."ID=".DB::table("oauth_clients")->where("password_client",1)->value("id").PHP_EOL;' 2>/dev/null | grep -oE '^ID=[0-9]+' | cut -d= -f2)
[ ${#S} -eq 40 ] && sed -i "s/^PASSPORT_CLIENT_ID=.*/PASSPORT_CLIENT_ID=$I/; s/^PASSPORT_CLIENT_SECRET=.*/PASSPORT_CLIENT_SECRET=$S/" .env; unset S
# El contenedor lee el .env al crearse: recrear y rehacer cachés
docker compose up -d --no-deps --force-recreate app worker-default worker-pqrsd worker-filing worker-chat scheduler reverb
bash scripts/deploy-laravel.sh
```

#### SECRET_KEY (frontend)

```
SECRET_KEY=...
```

Clave para encriptar tokens en localStorage del navegador. Generar con:

```bash
openssl rand -hex 32
```

Si cambias esta clave después de que los usuarios hayan iniciado sesión, ellos tendrán que volver a loguearse.

#### Backblaze B2 (almacenamiento de archivos)

```
B2_KEY_ID=00535c...
B2_APPLICATION_KEY=K005...
B2_BUCKET=sgd-mr7
B2_ENDPOINT=https://s3.us-east-005.backblazeb2.com
B2_REGION=us-east-005
```

Para obtener estas credenciales:
1. Crear cuenta en https://backblaze.com
2. Ir a "App Keys" → "Generate New Key"
3. Seleccionar el bucket o crear uno nuevo
4. Copiar `keyID` y `applicationKey`

El bucket se usa para almacenar documentos adjuntos y archivos subidos.

#### Correo (SMTP)

```
MAIL_MAILER=smtp
MAIL_HOST=smtp.tu-proveedor.com
MAIL_PORT=587
MAIL_USERNAME=...
MAIL_PASSWORD=...
MAIL_FROM_ADDRESS=noreply@tudominio.com
MAIL_FROM_NAME=SGD
```

Recomendaciones:
- **Desarrollo:** Usar `MAIL_MAILER=log` (los correos se guardan en `storage/logs/laravel.log`)
- **Producción:** Usar Mailtrap (pruebas), SendGrid, Amazon SES, o el SMTP de tu dominio.
- Cambiar `MAIL_FROM_ADDRESS` a una dirección real de tu dominio.

#### IA — Proveedores y modelos

```
AI_SELECTOR=DEEPSEEK
AI_SELECTOR_EMERGENCY=GEMINI
AI_SELECTOR_VISION=GEMINI
```

Proveedores disponibles: `GEMINI`, `DEEPSEEK`, `COHERE`, `OPENAI`.

Modelos recomendados:

| Variable | Valor sugerido |
|---|---|
| `MODEL_GEMINI` | `gemini-2.5-flash` |
| `MODEL_DEEPSEEK` | `deepseek-chat` |
| `MODEL_COHERE` | `command-r-plus` |
| `MODEL_OPENAI` | `gpt-4o` |
| `AI_MODEL_VISION_FALLBACK` | `qwen/qwen-vl-plus:free` (OpenRouter) |

#### IA — API Keys

Cada proveedor requiere su propia API key:

| Variable | Cómo obtener |
|---|---|
| `GOOGLE_API_KEY` | https://aistudio.google.com → Get API Key |
| `DEEPSEEK_API_KEY` | https://platform.deepseek.com → API Keys |
| `CO_API_KEY` | https://dashboard.cohere.com → API Keys |
| `OPENAI_API_KEY` | https://platform.openai.com → API Keys |
| `OPENROUTER_API_KEY` | https://openrouter.ai → Keys |

**Nota de seguridad:** Estas keys dan acceso a servicios facturados. Protégelas como contraseñas.

#### LangSmith (tracing opcional)

```
LANGSMITH_TRACING=false
LANGSMITH_PROJECT=Osai
LANGSMITH_API_KEY=...
```

Solo si usas LangSmith para debuggear llamadas a la IA. En producción se recomienda `false` para evitar overhead.

#### Portal ciudadano: buscadores y dominios

| Variable | Valor por defecto | Qué hace |
|---|---|---|
| `PORTAL_INDEXABLE` | `false` | Con `true`, `deploy-front.sh` genera un `robots.txt` que permite las páginas informativas del portal y un `sitemap.xml`. Con cualquier otro valor el `robots.txt` bloquea todo el sitio. Encenderlo solo en la instalación definitiva de la entidad, nunca en una de pruebas. |
| `CORS_ALLOWED_ORIGINS` | vacío | Dominios adicionales que pueden llamar a la API desde el navegador, separados por comas. Se suman al dominio del portal (`DOMAIN`), que siempre está permitido. Solo hace falta si otro dominio debe llamar a la API (por ejemplo, un front de desarrollo). |

Ni el sistema interno ni las direcciones con número de radicado o código se ofrecen nunca a los buscadores.
Comprobar tras desplegar: `curl -s https://$DOMAIN/robots.txt`.

### 3.4 Verificar que el .env está completo

Revisa que no haya valores como `coloca_aqui...` sin reemplazar:

```bash
grep -n "coloca_aqui\|tu_" /home/deploy/sgd-infra/.env
```

Si el comando no da salida, está todo reemplazado.

## 4. SSL con Let's Encrypt

**Requisito:** El dominio (`DOMAIN`) debe apuntar al VPS (registro A en DNS) ANTES de ejecutar esto.

```bash
cd /home/deploy/sgd-infra
bash scripts/setup-ssl.sh
```

Este script:
1. Verifica que nginx esté corriendo (necesario para el challenge HTTP-01)
2. Ejecuta Certbot para obtener el certificado:
   ```
   docker compose run --rm certbot certonly --webroot \
     -w /var/www/certbot -d tudominio.com
   ```
3. Genera `nginx/sgd-ssl.conf` con `envsubst` usando tu `$DOMAIN`
4. Instala un cron que renueva el certificado diariamente:
   ```
   0 3 * * * cd /home/deploy/sgd-infra && docker compose run --rm certbot renew && docker compose exec nginx nginx -s reload
   ```
5. Recarga nginx

**Si el script falla:**
- Verifica que el dominio apunte al VPS: `dig +short tudominio.com`
- Verifica que el puerto 80 esté abierto: `curl -I http://tudominio.com`
- Si ya tienes un certificado vigente, agrega `--force-renewal` al comando de certbot
- Si certbot no está disponible, puedes obtener el certificado manualmente y luego editar `nginx/sgd-ssl.conf`

**Estructura resultante:**

```
/etc/letsencrypt/live/tudominio.com/
├── fullchain.pem    ← Certificado + cadena
└── privkey.pem      ← Clave privada
```

## 5. Levantar todos los servicios

```bash
cd /home/deploy/sgd-infra
docker compose up -d
```

Esto inicia todos los servicios. Para ver el estado:

```bash
docker compose ps
```

Todos deben mostrar `Up` o `healthy`.

## 6. Setup de Laravel

```bash
bash scripts/deploy-laravel.sh
```

### Qué hace paso a paso:

**Paso 1 — Esperar la base de datos:**
El script espera hasta que la base de la app acepte conexiones (PostgreSQL u Oracle, según
`DB_CONNECTION`). Puede tomar 1-2 minutos la primera vez.

**Paso 2 — Migraciones:**
```bash
docker compose exec -T app php artisan migrate --force
```
Ejecuta las migraciones pendientes. Están consolidadas: una por tabla, con su forma final; las
llaves foráneas van en una migración al final. Las 238 migraciones viejas de Oracle quedaron archivadas
en `database/migrations/_oracle_legacy/` (históricas, no se ejecutan). Si alguna falla, revisa los logs:
```bash
docker compose logs app
```

**Paso 3 — Passport keys:**
Solo se generan si no existen (`storage/oauth-private.key`). Esto asegura que los tokens JWT no se invaliden entre deploys.

Si necesitas regenerarlas (por ejemplo, si se perdieron):
```bash
docker compose exec app rm -f storage/oauth-*.key
# Luego ejecuta de nuevo deploy-laravel.sh
```

**Paso 4 — Cliente personal Passport:**
```bash
docker compose exec app php artisan passport:client --personal --no-interaction
```
Crea el cliente OAuth si no existe.

**Paso 5 — Storage link:**
```bash
docker compose exec app php artisan storage:link
```

**Paso 6 — Caches de optimización:**
```bash
docker compose exec app php artisan config:cache
docker compose exec app php artisan route:cache
docker compose exec app php artisan view:cache
docker compose exec app php artisan event:cache
```

Si después de un cambio no ves los efectos, limpia las caches:
```bash
docker compose exec app php artisan optimize:clear
```

**Paso 7 — Reiniciar workers:**
```bash
docker compose exec app php artisan queue:restart
```

## 6b. Cambio de Oracle a PostgreSQL (una sola ventana de mantenimiento)

Se hace **una vez** por instalación. El código de la rama de Postgres **no funciona con Oracle como base
activa** (usa SQL de Postgres), así que el código nuevo y el cambio de base van juntos, con la app en
mantenimiento y las colas detenidas. Oracle no se toca: es el origen y la vuelta atrás.

Variables: `C="docker compose -f docker-compose.dockploy.yml"` y
`A="$C exec -T -u www-data -e HOME=/tmp app php artisan"` (todo desde `/home/deploy/sgd-infra`).

**Antes de la ventana (con Oracle, sin cortar nada)**
1. Respaldo de Oracle guardado **fuera** de `BACKUP_DIR` (la limpieza de `backup.sh` borra los `.dmp` de más
   de 7 días): `bash scripts/backup.sh` y copiar el `.dmp` a `/home/deploy/respaldos/oracle-antes-de-postgres/`.
2. Copia del `.env`: `cp .env .env.antes-postgres`. Anotar los commits actuales de SDG-Back-api y sgd-infra.

**Ventana**
3. Mantenimiento: `$A down --retry=60`. El portal muestra mantenimiento y los webhooks de OSAI reciben 503,
   que OSAI reintenta (solo 400/404/409/410/422 son definitivos).
4. Detener lo que escribe en la base: `$C stop worker-default worker-pqrsd worker-filing worker-chat scheduler reverb`.
5. Comprobar que no queda trabajo a medias:
   - colas vacías: `$A queue:monitor redis:default,redis:pqrsd-ai,redis:filing-ai,redis:chat-ai`;
   - ningún documento analizándose:
     `$A tinker --execute="echo App\Models\ProcessedDocument::whereIn('status', ['processing','queued'])->count();"` → 0.
   Si hay trabajo pendiente, levantar los workers, esperar y repetir.
6. Código nuevo: `git pull` (o `checkout`) de la versión con Postgres en SDG-Back-api y sgd-infra.
7. `.env` (secretos con `read -rs`, nunca en el historial):
   `POSTGRES_PASSWORD=<admin>`, `DB_CONNECTION=pgsql`, `DB_HOST=postgres`, `DB_PORT=5432`, `DB_DATABASE=sgd`,
   `DB_USERNAME=sgd_app`, `DB_PASSWORD=<app>`, y los datos de Oracle en `ORACLE_DB_USERNAME` / `ORACLE_DB_PASSWORD`.
8. Levantar Postgres: `$C up -d --no-deps postgres` (esperar `healthy`). Crear el rol de la app (sin superusuario)
   y las extensiones, como superusuario:
   ```bash
   $C exec -T postgres psql -U sgd -d sgd -v ON_ERROR_STOP=1 -v pass="$SGD_APP_PASSWORD" <<'SQL'
   CREATE ROLE sgd_app LOGIN PASSWORD :'pass';
   ALTER DATABASE sgd OWNER TO sgd_app;
   ALTER SCHEMA public OWNER TO sgd_app;
   CREATE EXTENSION IF NOT EXISTS vector;
   CREATE EXTENSION IF NOT EXISTS unaccent;
   SQL
   ```
9. Recrear la app con el `.env` nuevo y **borrar la configuración cacheada** (si no, sigue apuntando a Oracle):
   `$C up -d --no-deps --force-recreate app`, `$A config:clear`, `$A migrate --force` (sin seeders).
10. Trasladar con la conexión de administración (superusuario, solo para esta orden):
    ```bash
    $C exec -T -u www-data -e HOME=/tmp -e DB_ADMIN_USERNAME=sgd -e DB_ADMIN_PASSWORD="$POSTGRES_PASSWORD" app \
      php artisan db:migrate-from-oracle --to=pgsql_admin
    ```
    Debe terminar en «Traslado verificado» (código 0). Avisa cuántas fechas traían hora en columnas `date`
    (se guarda el día; la app ya las leía como día). Si algo no cuadra: **vuelta atrás** (abajo).
11. `bash scripts/deploy-laravel.sh` (caches, permisos, Passport ya existe por el traslado), levantar
    `$C up -d --no-deps worker-default worker-pqrsd worker-filing worker-chat scheduler reverb` y `$A up`.
12. `bash scripts/healthcheck.sh` → 16 OK. Probar login, un radicado de prueba (recibe el id y el número
    siguientes al último copiado) y la consulta con código en el portal.

**Vuelta atrás** (Oracle quedó intacto; lo escrito en Postgres después del cambio se pierde, aceptado en staging):
`$A down`, detener workers/scheduler/reverb, `cp .env.antes-postgres .env`, volver SDG-Back-api y sgd-infra a
los commits anotados en el paso 2, `$C up -d --no-deps --force-recreate app worker-default worker-pqrsd worker-filing worker-chat scheduler reverb`,
`bash scripts/deploy-laravel.sh`, `$A up`, `bash scripts/healthcheck.sh`.

Opciones del comando: `--from=oracle`, `--to=pgsql|pgsql_admin`, `--truncate` (vacía el destino y copia de
nuevo), `--verify-only` (solo compara), `--batch=500` (no pasar de ~1000: tope de parámetros de Postgres).

Qué hace `db:migrate-from-oracle`:
- Compara los esquemas de origen y destino y **se detiene si no coinciden**.
- Exige el destino migrado y **vacío** (o `--truncate`).
- Copia todas las tablas menos `migrations` y `jobs`, con las llaves foráneas apagadas (por eso el superusuario).
- Convierte 0/1 a booleano y `''` a `NULL`; las fechas se copian sin mover la hora; un valor fuera de un CHECK
  da un error claro. Un fallo al insertar muestra tabla, lote y SQLSTATE, **nunca los valores**.
- Ajusta las secuencias de los id y verifica filas, suma de control, llaves huérfanas y que las columnas
  cifradas se lean con la `APP_KEY`.

Notas del esquema en Postgres:
- Los índices únicos que en Oracle convivían con `deleted_at` ahora son **índices únicos parciales**
  `WHERE deleted_at IS NULL` (algunos usan `NULLS NOT DISTINCT`).
- Las columnas JSON se guardan como `text` (no `jsonb`), por las búsquedas con `LIKE`.
- Postgres mide los `varchar` en caracteres (Oracle medía bytes). La regla `MaxBytes` se conserva:
  es más estricta.
- La app se conecta con `sgd_app` (sin superusuario). El superusuario (`POSTGRES_USER`) solo para el traslado,
  los respaldos y la administración.

## 7. Build del frontend

```bash
bash scripts/deploy-front.sh
```

### Qué hace:

1. **Instala dependencias:** `npm ci` (usa `package-lock.json` para versiones exactas)
2. **Compila:** `NODE_ENV=production npm run build` → genera `dist/spa/`
3. **Genera config.json** automáticamente desde `.env`:

```json
{
  "API_URL": "/api/",
  "REVERB_APP_KEY": "wzstepthkcfmlxta3wya",
  "REVERB_HOST": "tudominio.com",
  "REVERB_PORT": "443",
  "REVERB_SCHEME": "https",
  "REVERB_WSPATH": "/ws",
  "SECRET_KEY": "bef6be93..."
}
```

4. **Recrea nginx** (fix bind mount):
   - `docker compose rm -f nginx` elimina el contenedor con el mount roto
   - `docker compose up -d nginx` lo recrea con el nuevo inodo

## 7b. Reiniciar un ambiente de demo desde cero (base, Passport, Redis, archivos, B2)

**Destructivo e irreversible.** Solo en el ambiente de demo/staging y con autorización explícita. Nunca
en la instancia de un cliente. (Hecho el 2026-09-28 en demo.aviliontech.com.)

1. *(Recomendado)* respaldo final: `bash scripts/backup.sh` (queda en restic, bucket `SGD-BACKUPS`, que
   **no** es el bucket de la app).
2. Detener lo que procesa en segundo plano:
   `docker compose stop worker-default worker-pqrsd worker-filing worker-chat scheduler`
3. Base nueva con datos iniciales (única vez en que se corren seeders, y solo con autorización):
   `$A php artisan migrate:fresh --seed --force` → crea tablas y el admin `SytemasMR7` (cambiar su
   contraseña al entrar: la del seeder está en el código). Las secciones quedan con su `area`.
4. Passport nuevo: `$A php artisan passport:keys --force`, luego
   `$A php artisan passport:client --personal --name="SGD Personal Access Client" --no-interaction` y
   `$A php artisan passport:client --password --name="SGD Password Grant Client" --provider=users --no-interaction`;
   después actualizar el `.env` como en **3.3 › Passport** (sin imprimir el secreto).
5. Redis: `docker compose exec -T redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli FLUSHALL'`.
6. Archivos locales: vaciar `storage/app/public/*` y `storage/app/report-exports/*` del contenedor `app`
   (**no** borrar `storage/oauth-*.key`). OSAI: vaciar `data/pending_webhooks`,
   `data/pending_portal_webhooks` y `data/dead_webhooks`.
7. B2 de la app (`B2_BUCKET`): borrar **todas las versiones** (listObjectVersions + deleteObjects); un
   `deleteObject` simple solo oculta el archivo y sigue ocupando espacio. Verificar que el bucket es el
   de la app y no `SGD-BACKUPS`.
8. Recrear contenedores y cachés (último bloque de 3.3 › Passport) y `bash scripts/healthcheck.sh`
   (16 OK). Probar login real.

## 8. Verificar el despliegue

```bash
bash scripts/healthcheck.sh
```

Salida esperada:

```
=== Health Check SGD ===
  [OK] PostgreSQL
  [OK] Redis
  [OK] Laravel App
  [OK] Worker Default
  [OK] Worker PQRSD
  [OK] Worker Filing
  [OK] Worker Chat
  [OK] Scheduler
  [OK] Reverb
  [OK] OSAI
  [OK] Nginx

  [OK] API Health
  [OK] OSAI /info
  [OK] Frontend SPA
  [OK] Colas (failed/backlog/mem)
  [OK] Tamaño de la base

Resultado: 16 OK, 0 FAIL
Todos los servicios están saludables.
```

El primer chequeo revisa la base activa según `DB_CONNECTION`: `PostgreSQL`, o `Oracle XE` mientras
la app siga en Oracle (hasta la limpieza). «Tamaño de la base» usa `php artisan db:size` (en Postgres,
`pg_database_size`; salida `db_size: N GB`) y falla si pasa de `DB_SIZE_ALERT_GB`.

### Pruebas manuales adicionales:

```bash
# 1. API responde
curl -s https://tudominio.com/api/health | python3 -m json.tool

# 2. Login funciona
curl -s -X POST https://tudominio.com/api/auth/login \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{"username":"SytemasMR7","password":"System_mr7*0707"}'

# 3. Frontend sirve
curl -s -o /dev/null -w "%{http_code}" https://tudominio.com/intelligent-filing

# 4. WebSocket conecta
wscat -c wss://tudominio.com/ws/app/wzstepthkcfmlxta3wya?protocol=7

# 5. OSAI
curl -s https://tudominio.com/osai-api/info
```

## 9. Monitoreo y operación continua

### Logs

```bash
# Ver logs de un servicio específico
docker compose logs -f --tail=100 app
docker compose logs -f --tail=100 nginx
docker compose logs -f --tail=100 reverb
docker compose logs -f --tail=100 worker-default
docker compose logs -f --tail=100 worker-pqrsd
docker compose logs -f --tail=100 osai

# Todos los logs a la vez (mucho texto)
docker compose logs -f
```

### Backups

El script `scripts/backup.sh` respalda:

| Componente | Método | Archivo |
|---|---|---|
| PostgreSQL | `pg_dump -Fc` | `sgd_backup_YYYYMMDD_HHMMSS.pgdump` |
| Oracle (hasta la limpieza) | `expdp` (data pump) | `sgd_backup_YYYYMMDD_HHMMSS.dmp` |
| Storage Laravel | `tar.gz` | `laravel_storage_YYYYMMDD_HHMMSS.tar.gz` |
| Data OSAI | `tar.gz` | `osai_data_YYYYMMDD_HHMMSS.tar.gz` |

El script elige la base según `DB_CONNECTION` del `.env`. Modo seco (solo informa qué método usaría, sin tocar contenedores): `BACKUP_DRY_RUN=1 bash scripts/backup.sh`.

Los backups se guardan en `BACKUP_DIR` (configurable en `.env`, por defecto `/home/deploy/backups`). Se conservan 7 días.

**Restaurar y simulacro** (con Postgres; con Oracle funcionan como antes, hasta la limpieza):
- `bash scripts/restore.sh --target=ensayo` restaura el `.pgdump` en la base `sgd_restore_test` del mismo
  servidor, sin tocar producción. `--target=produccion` restaura sobre la real con `pg_restore --clean`
  (pide confirmación). `--skip-db` (alias `--skip-oracle`) omite la base.
- `bash scripts/restore-rehearsal.sh [dump]` restaura en la base temporal `sgd_restore_test`, compara
  filas tabla por tabla con la real, imprime `RESUMEN ... tablas_faltantes=N` y borra la temporal.
  Esperado: `tablas_faltantes=0`.
- Prueba de los scripts: `bash scripts/tests/postgres-scripts.test.sh` (en WSL sin integración de
  Docker: `DOCKER=docker.exe`).

**Programar backup diario (cron del sistema):**

```bash
sudo crontab -e
```

Agregar:

```
0 2 * * * cd /home/deploy/sgd-infra && bash scripts/backup.sh >> /home/deploy/backups/backup.log 2>&1
```

### Actualización (deploy de nuevas versiones)

```bash
# 1. Ir al directorio de infra
cd /home/deploy/sgd-infra

# 2. Pull de cambios de cada repo
cd ../SDG-Back-api && git pull && cd ../sgd-infra
cd ../OSAI && git pull && cd ../sgd-infra
cd ../SGD-Front && git pull && cd ../sgd-infra

# 3. Reconstruir imágenes si hay cambios en Dockerfile
docker compose build app osai

# 4. Levantar con nuevas imágenes
docker compose up -d

# 5. Migraciones y caches
bash scripts/deploy-laravel.sh

# 6. Frontend
bash scripts/deploy-front.sh
```

### SSL — renovación automática

El script `setup-ssl.sh` instala un cron que ejecuta:

```bash
0 3 * * * cd /home/deploy/sgd-infra && docker compose run --rm certbot renew && docker compose exec nginx nginx -s reload
```

Esto verifica cada día si el certificado expira en menos de 30 días. Si es así, lo renueva automáticamente y recarga nginx sin downtime.

Para verificar el estado del certificado:

```bash
docker compose run --rm certbot certificates
```

## 10. Seguridad

### Firewall (UFW)

El `setup-vps.sh` configura:

```
22/tcp  (SSH)      → ALLOW
80/tcp  (HTTP)     → ALLOW
443/tcp (HTTPS)    → ALLOW
Otros              → DENY
```

Para verificar:

```bash
sudo ufw status verbose
```

### fail2ban

Protege contra ataques de fuerza bruta SSH. Para ver el estado:

```bash
sudo fail2ban-client status sshd
```

### Prácticas recomendadas

1. **No exponer Portainer** — solo acceder vía SSH tunnel: `ssh -L 9001:localhost:9001 deploy@VPS`
2. **Rotar API keys** periódicamente (cada 6-12 meses)
3. **Mantener Ubuntu actualizado:** `sudo apt update && sudo apt upgrade -y`
4. **Monitorear espacio en disco:** `df -h`
5. **Revisar logs de errores:** `docker compose logs app | grep -i error`
6. **No compartir el `.env`** — contiene credenciales de producción

## 11. Solución de problemas

### 500 "Server Error" en toda la API

**Causa:** `APP_DEBUG=true` o errores de PHP no capturados.
**Diagnóstico:**
```bash
# Ver logs de Laravel
docker compose exec app tail -100 storage/logs/laravel.log

# Probar con APP_DEBUG=true temporal
docker compose exec -e APP_DEBUG=true app php artisan config:clear
```

### Login responde "Invalid credentials"

**Causa común 1:** El secret del cliente Passport está hasheado en la BD.
**Verificar:**
```bash
docker compose exec app php -r "
\$c = App\Models\PassportClient::where('personal_access_client', 1)->first();
echo 'ID: ' . \$c->id . PHP_EOL;
echo 'Secret starts with: ' . substr(\$c->secret, 0, 10) . PHP_EOL;
"
```
Si el secret empieza con `$2y$`, está hasheado (bcrypt). Debe ser texto plano.

**Solución:**
```sql
UPDATE oauth_clients SET secret = 'nuevo_secreto_plano' WHERE personal_access_client = 1;
```
Y actualizar `PASSPORT_CLIENT_SECRET` en `.env`.

**Causa común 2:** El `PASSPORT_CLIENT_ID` en `.env` no coincide con el ID real.
**Verificar:**
```bash
docker compose exec app php -r "echo App\Models\PassportClient::where('personal_access_client', 1)->first()->id ?? 'none';"
```

### WebSocket no conecta desde el navegador

**Causa:** `config.json` tiene valores incorrectos.
**Verificar:**
```bash
curl -s https://tudominio.com/config.json | python3 -m json.tool
```

Debe mostrar `REVERB_HOST=tudominio.com`, `REVERB_PORT=443`, `REVERB_SCHEME=https`, `REVERB_WSPATH=/ws`.

**Solución:** Re-ejecutar `bash scripts/deploy-front.sh`.

### Nginx 500 en rutas del SPA (intelligent-filing, etc.)

**Error en logs de nginx:** `rewrite or internal redirection cycle while internally redirecting to "/index.html"`

**Causa:** El `npm run build` borró y recreó `dist/spa/`, rompiendo el bind mount de Docker.

**Solución:**
```bash
docker compose rm -f nginx
docker compose up -d nginx
```

### PostgreSQL no arranca

**Síntomas:** `docker compose` no arranca, o el contenedor `postgres` no llega a `healthy`.

**Causas comunes:**
- Falta `POSTGRES_PASSWORD` en `.env` (compose se niega a arrancar y lo dice)
- Disco lleno

**Diagnóstico:**
```bash
docker compose logs postgres
df -h
```

### Oracle XE no arranca (hasta la limpieza)

**Síntomas:** Contenedor se reinicia en bucle, healthcheck falla.

**Causas comunes:**
- No hay suficiente memoria (mínimo 2 GB libres para Oracle)
- Puerto 1521 ocupado por otra instancia de Oracle
- Disco lleno

**Diagnóstico:**
```bash
docker compose logs oracle-xe
df -h
free -h
```

**Solución:**
```bash
# Aumentar memoria del sistema (si está en límite)
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile

# O usar Oracle del host si está disponible
```

### Passport keys perdidas

**Síntomas:** Los tokens JWT existentes dejan de funcionar.

**Solución:** Regenerar keys y emitir nuevos tokens:
```bash
docker compose exec app php artisan passport:keys --force
# Los usuarios deben volver a iniciar sesión
```

### Cache obsoleta después de cambios

Si agregaste rutas, configuraciones o vistas nuevas y no se reflejan:

```bash
docker compose exec app php artisan optimize:clear
docker compose exec app php artisan config:cache
docker compose exec app php artisan route:cache
docker compose exec app php artisan view:cache
docker compose restart app
```

## 12. Referencia de puertos

| Puerto | Servicio | Acceso |
|---|---|---|
| 22 | SSH | Público (solo clave SSH) |
| 80 | HTTP (redirección a HTTPS) | Público |
| 443 | HTTPS (todo el tráfico) | Público |
| 9001 | Portainer | Solo localhost (SSH tunnel) |
| 5432 | PostgreSQL | Solo red interna Docker |
| 1521 | Oracle XE (hasta la limpieza) | Solo red interna Docker |
| 6379 | Redis | Solo red interna Docker |
| 8080 | Reverb | Solo red interna Docker |
| 8000 | OSAI | Solo red interna Docker |
| 9000 | PHP-FPM | Solo red interna Docker |

## 13. Referencia de volúmenes Docker

| Volumen | Monta en | Propósito |
|---|---|---|
| `pg_data` | `/var/lib/postgresql/data` | Datos de PostgreSQL |
| `oracle_data` | `/opt/oracle/oradata` | Datos de Oracle (hasta la limpieza) |
| `redis_data` | `/data` | Persistencia de Redis |
| `app_storage` | `/var/www/html/storage` | Uploads, logs de Laravel |
| `osai_data` | `/app/data` | Datos de OSAI |
| `certbot_certs` | `/etc/letsencrypt` | Certificados SSL |
| `certbot_www` | `/var/www/certbot` | Webroot para Certbot |
| `portainer_data` | `/data` | Datos de Portainer |

## 14. Apéndice: Comandos rápidos

```bash
# === Diagnóstico ===
bash scripts/healthcheck.sh                    # 16 checks
docker compose ps                             # Estado de contenedores
docker compose logs --tail=50 app             # Últimos logs de Laravel

# === Mantenimiento ===
bash scripts/backup.sh                        # Backup manual
docker compose exec app php artisan optimize:clear  # Limpiar caches
docker compose restart app                    # Reiniciar Laravel
docker compose restart nginx                  # Reiniciar nginx

# === Actualización ===
cd /home/deploy/sgd-infra
git pull                                      # Actualizar infra
docker compose build app osai                 # Reconstruir imágenes
docker compose up -d                          # Aplicar cambios
bash scripts/deploy-laravel.sh                # Migraciones + caches
bash scripts/deploy-front.sh                  # Build frontend

# === SSL ===
docker compose run --rm certbot certificates  # Estado del certificado
docker compose run --rm certbot renew         # Renovar manualmente
```
