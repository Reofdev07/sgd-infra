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

**IMPORTANTE:** El archivo `docker-compose.override.yml` tiene configuraciones para desarrollo local (`APP_DEBUG=true`, `APP_ENV=local`, Oracle del host). En producción debe estar deshabilitado:

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

#### Oracle XE

```
ORACLE_PASSWORD=StrongPassword123!
DB_USERNAME=SGD_MR7
DB_PASSWORD=sgd123
```

- `ORACLE_PASSWORD`: Contraseña del usuario `SYS` y `SYSTEM` en Oracle. **Cámbiala por una segura.**
- `DB_USERNAME`: Usuario de la aplicación. Debe ser `SGD_MR7` (usado en migraciones y seeders).
- `DB_PASSWORD`: Contraseña del usuario de la aplicación.

**Para cambiar el password del usuario SGD_MR7 después del primer arranque:**

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
PASSPORT_CLIENT_ID=3
PASSPORT_CLIENT_SECRET=...
```

- `PASSPORT_CLIENT_ID`: ID del cliente personal de Passport. Se obtiene después del primer deploy:

```bash
# Después de ejecutar deploy-laravel.sh:
docker compose exec app php artisan passport:client --personal --no-interaction
# Luego ver el ID:
docker compose exec app php -r "echo App\Models\PassportClient::where('personal_access_client', 1)->first()->id ?? 'none';"
```

Generalmente es `2` o `3`.

- `PASSPORT_CLIENT_SECRET`: El `secret` de ese cliente en la tabla `oauth_clients`. Debe ser **texto plano** (no hash bcrypt), porque `Passport::$hashesClientSecrets = false` en la configuración actual.

Para obtenerlo:

```bash
docker compose exec app php -r "
\$client = App\Models\PassportClient::where('personal_access_client', 1)->first();
if (\$client) echo \$client->secret;
"
```

Si el secret está hasheado (empieza con `$2y$`), hay que regenerarlo en texto plano:

```sql
UPDATE oauth_clients SET secret = 'un_secreto_plano_seguro' WHERE personal_access_client = 1;
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

**Paso 1 — Esperar Oracle:**
```bash
until docker compose exec -T app php artisan migrate:status &>/dev/null; do sleep 5; done
```
Puede tomar 1-2 minutos la primera vez.

**Paso 2 — Migraciones:**
```bash
docker compose exec -T app php artisan migrate --force
```
Ejecuta las 151 migraciones. Si alguna falla, revisa los logs:
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

## 8. Verificar el despliegue

```bash
bash scripts/healthcheck.sh
```

Salida esperada:

```
=== Health Check SGD ===
  [OK] Oracle XE
  [OK] Redis
  [OK] Laravel App
  [OK] Worker Default
  [OK] Worker PQRSD
  [OK] Scheduler
  [OK] Reverb
  [OK] OSAI
  [OK] Nginx

  [OK] API Health
  [OK] OSAI /info
  [OK] Frontend SPA

Resultado: 12 OK, 0 FAIL
Todos los servicios están saludables.
```

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
| Oracle | `expdp` (data pump) | `sgd_backup_YYYYMMDD_HHMMSS.dmp` |
| Storage Laravel | `tar.gz` | `laravel_storage_YYYYMMDD_HHMMSS.tar.gz` |
| Data OSAI | `tar.gz` | `osai_data_YYYYMMDD_HHMMSS.tar.gz` |

Los backups se guardan en `BACKUP_DIR` (configurable en `.env`, por defecto `/home/deploy/backups`). Se conservan 7 días.

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

### Oracle XE no arranca

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
| 1521 | Oracle XE | Solo red interna Docker |
| 6379 | Redis | Solo red interna Docker |
| 8080 | Reverb | Solo red interna Docker |
| 8000 | OSAI | Solo red interna Docker |
| 9000 | PHP-FPM | Solo red interna Docker |

## 13. Referencia de volúmenes Docker

| Volumen | Monta en | Propósito |
|---|---|---|
| `oracle_data` | `/opt/oracle/oradata` | Datos de Oracle |
| `redis_data` | `/data` | Persistencia de Redis |
| `app_storage` | `/var/www/html/storage` | Uploads, logs de Laravel |
| `osai_data` | `/app/data` | Datos de OSAI |
| `certbot_certs` | `/etc/letsencrypt` | Certificados SSL |
| `certbot_www` | `/var/www/certbot` | Webroot para Certbot |
| `portainer_data` | `/data` | Datos de Portainer |

## 14. Apéndice: Comandos rápidos

```bash
# === Diagnóstico ===
bash scripts/healthcheck.sh                    # 12 checks
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
