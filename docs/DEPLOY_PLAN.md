# SGD — Plan de Despliegue en Contabo + Dockploy

## Arquitectura

```
Internet → Traefik (puertos 80/443 del host, SSL automático)
                ↓
           nginx (interno, puerto 80)
                ↓
        ┌───────┼───────┐
        ↓       ↓       ↓
     Laravel  OSAI   Reverb
     (FPM)   (FastAPI) (WS)
        ↓
     Oracle XE
```

Con Dockploy:
- **Traefik** maneja SSL (Let's Encrypt automático, renovación automática)
- **Nginx** sigue manejando el ruteo interno (SPA, API, WS, OSAI)
- **No más certbot, no más crons SSL, no más ssl.conf**

---

## Fase 1 — Comprar VPS en Contabo ✅ (LISTO)

- **Cloud VPS 20** (6 vCPU, 12 GB RAM, 200 GB NVMe, ~€13/mes)
- Ubuntu 24.04
- IP asignada, credenciales recibidas

---

## Fase 2 — DNS en Spaceship (tú haces ahora)

1. Entrar a Spaceship → dominios → **aviliontech**
2. Crear registro A:
   - **Nombre:** `demo`
   - **Valor:** IP del VPS Contabo
3. Esperar propagación. Verificar:
   ```bash
   dig +short demo.aviliontech.com
   ```
4. **Nota:** El dominio principal es `demo.aviliontech.com`. Si más adelante quieres agregar `aviliontech.com` (raíz) u otros subdominios, repites el proceso con otro registro A.

---

## Fase 3 — Setup inicial del VPS (hago yo como root)

```bash
ssh root@IP_DEL_VPS

# Copiar script de bootstrap
# (desde tu máquina local)
scp /home/reof07/proyectos/sgd-infra/scripts/setup-vps.sh root@IP:/root/

# Ejecutar en el VPS
bash /root/setup-vps.sh
```

**Qué hace el script:**

| Paso | Descripción |
|---|---|
| 1 | Crea usuario `deploy` con sudo sin contraseña |
| 2 | `apt update && apt upgrade -y` |
| 3 | Instala Docker Engine |
| 4 | Agrega `deploy` al grupo docker |
| 5 | Instala Node.js 20 (para build del frontend) |
| 6 | Instala git, curl, wget, unzip, htop, tmux, fail2ban |
| 7 | UFW: solo SSH (22), HTTP (80), HTTPS (443) |
| 8 | Activa fail2ban para protección SSH |
| 9 | Crea `/home/deploy` |

Luego reconectarse como deploy:
```bash
ssh deploy@IP_DEL_VPS
```

---

## Fase 4 — Instalar Dockploy (hago yo como root)

```bash
# Como root
curl -sSL https://dokploy.com/install.sh | sh
```

**Qué instala:**
- Docker Swarm inicializado
- Red `dokploy-network` (overlay)
- PostgreSQL 16 (datos de Dockploy)
- Redis 7 (cache/colas)
- Traefik v3 (proxy inverso en puertos 80/443)
- Dockploy web UI (puerto 3000)

Después: acceder a `http://IP_DEL_VPS:3000` y crear cuenta admin.

---

## Fase 5 — Clonar repos (hago yo)

```bash
cd /home/deploy
git clone <url-SDG-Back-api>
git clone <url-SGD-Front>
git clone <url-OSAI>
git clone <url-sgd-infra>
```

Estructura:
```
/home/deploy/
├── SDG-Back-api/
├── SGD-Front/
├── OSAI/
└── sgd-infra/
```

---

## Fase 6 — Adaptar docker-compose.yml para Dockploy (hago yo)

Crear `docker-compose.dockploy.yml` con estos cambios respecto al original:

### 6.1 — Quitar `container_name` de TODOS los servicios

```
oracle-xe, redis, app, worker-default, worker-pqrsd, scheduler, reverb, osai, nginx
```

Dockploy no permite `container_name`.

### 6.2 — Cambiar puertos de nginx

```yaml
ports:
  - 80        # sin host binding — Traefik reenvía a nginx:80
```

### 6.3 — Agregar red dokploy-network + labels Traefik a nginx

```yaml
networks:
  - sgd-network
  - dokploy-network

labels:
  - "traefik.enable=true"
  - "traefik.http.routers.sgd.rule=Host(`${DOMAIN}`)"
  - "traefik.http.routers.sgd.entrypoints=websecure"
  - "traefik.http.routers.sgd.tls.certResolver=letsencrypt"
  - "traefik.http.services.sgd.loadbalancer.server.port=80"
```

### 6.4 — Agregar red externa al final

```yaml
networks:
  sgd-network:
    driver: bridge
  dokploy-network:
    external: true
```

### 6.5 — Remover servicios no necesarios

- **certbot** → SSL lo maneja Traefik
- **portainer** → Dockploy es la UI de gestión

Remover volúmenes: `certbot_certs`, `certbot_www`, `portainer_data`

---

## Fase 7 — Configurar .env (hacemos juntos)

```bash
cd /home/deploy/sgd-infra
cp .env.example .env
nano .env
```

| Variable | Cómo generar |
|---|---|
| `DOMAIN` | `demo.aviliontech.com` |
| `ORACLE_PASSWORD` | Inventar una segura |
| `APP_KEY` | `docker compose run --rm app php artisan key:generate --show` |
| `OSAI_API_TOKEN` | `openssl rand -hex 32` |
| `REVERB_APP_ID` | `240902` (de seeders, no cambiar) |
| `REVERB_APP_KEY` | `wzstepthkcfmlxta3wya` (de seeders, no cambiar) |
| `REVERB_APP_SECRET` | `openssl rand -hex 16` |
| `SECRET_KEY` | `openssl rand -hex 32` |
| `GOOGLE_API_KEY` | https://aistudio.google.com |
| `DEEPSEEK_API_KEY` | https://platform.deepseek.com |
| `PASSPORT_CLIENT_ID` | Después del deploy inicial |
| `PASSPORT_CLIENT_SECRET` | Después del deploy inicial |

Verificar:
```bash
grep -n "coloca_aqui\|tu_" .env
# Sin salida = completo
```

Deshabilitar override local:
```bash
mv docker-compose.override.yml docker-compose.override.yml.bak
```

---

## Fase 8 — Build de imágenes (hago yo, ~30 min)

```bash
cd /home/deploy/sgd-infra
docker compose build app    # PHP+OCI8 (~15-20 min)
docker compose build osai   # FastAPI (~10 min)
```

---

## Fase 9 — Desplegar en Dockploy (hacemos juntos)

1. UI: http://IP_VPS:3000 → login
2. Projects → New Project → nombre `sgd`
3. Docker Compose → pegar `docker-compose.dockploy.yml`
4. Subir `.env` como variables de entorno
5. Configurar dominio: `demo.aviliontech.com`
6. Deploy

---

## Fase 10 — Setup Laravel (hago yo)

```bash
cd /home/deploy/sgd-infra
bash scripts/deploy-laravel.sh
```

Luego obtener Passport client:
```bash
docker compose exec app php -r "
\$c = App\Models\PassportClient::where('personal_access_client', 1)->first();
if (\$c) echo 'ID: ' . \$c->id . ' Secret: ' . \$c->secret;
"
```

Actualizar `.env` con los valores y recargar caches.

---

## Fase 11 — Build frontend (hago yo)

```bash
cd /home/deploy/sgd-infra
bash scripts/deploy-front.sh
```

Genera `config.json` con rutas HTTPS, host `demo.aviliontech.com`.

---

## Fase 12 — Verificar (hacemos juntos)

```bash
bash scripts/healthcheck.sh
# Esperado: 12 OK, 0 FAIL
```

Pruebas en navegador:
- `https://demo.aviliontech.com` → frontend cargado
- Login con `SytemasMR7` / `System_mr7*0707`
- `https://demo.aviliontech.com/intelligent-filing` → ruta SPA funciona
- `https://demo.aviliontech.com/api/health` → JSON con BD, Redis, Reverb OK

---

## Fase 13 — Backups (configuro yo)

```bash
sudo crontab -e
# Agregar:
0 2 * * * cd /home/deploy/sgd-infra && bash scripts/backup.sh >> /home/deploy/backups/backup.log 2>&1
```

Backups diarios de Oracle, storage Laravel, data OSAI (retención 7 días).

---

## Fase 14 — Operación continua

### Actualización
```bash
cd /home/deploy/sgd-infra
cd ../SDG-Back-api && git pull && cd ../sgd-infra
cd ../SGD-Front && git pull && cd ../sgd-infra
cd ../OSAI && git pull && cd ../sgd-infra
docker compose build app osai
bash scripts/deploy-laravel.sh
bash scripts/deploy-front.sh
```

### Logs
```bash
docker compose logs -f --tail=100 app
```

### Espacio
```bash
df -h
```

---

## Agregar más dominios después (futuro)

Si quieres que `aviliontech.com` (raíz) u otros subdominios (`admin.aviliontech.com`, etc.) también apunten a la app:

### DNS (Spaceship)
Crear registro A adicional:
- **Nombre:** `@` (para raíz) u otro nombre
- **Valor:** misma IP del VPS

### Dockploy
En el proyecto `sgd` → Domains → agregar el nuevo dominio.

Traefik automáticamente:
1. Reconoce el nuevo dominio
2. Obtiene certificado SSL
3. Enruta el tráfico al mismo nginx

No necesitas modificar nginx ni el compose. Los dominios adicionales comparten el mismo backend.
