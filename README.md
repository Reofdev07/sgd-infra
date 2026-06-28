# sgd-infra — Infraestructura de despliegue del Sistema SGD

Repositorio de infraestructura que levanta los 3 componentes del sistema SGD
en un VPS con Docker Compose.

## Requisitos

- VPS Ubuntu 22.04 (Contabo Cloud M: 8GB RAM, 4 vCPU, 200GB SSD)
- Dominio apuntado al VPS vía Cloudflare
- Los 3 repos clonados como hermanos:
  ```
  /home/deploy/
  ├── SDG-Back-api/    (Laravel API)
  ├── OSAI/            (FastAPI IA)
  ├── SGD-Front/       (Vue/Quasar frontend)
  └── sgd-infra/       (este repo)
  ```

## Arranque rápido

```bash
# 1. Configurar .env
cp .env.example .env
nano .env  # rellenar con valores reales

# 2. Build del frontend
cd ../SGD-Front
cp .env.production .env.production  # verificar URLs
npm ci && NODE_ENV=production npm run build
cd ../sgd-infra

# 3. Levantar todo
docker compose up -d

# 4. Esperar a Oracle (~3 min) y migrar
bash scripts/deploy-laravel.sh

# 5. Verificar
bash scripts/healthcheck.sh
```

## Servicios

| Servicio | Contenedor | Puerto interno | Descripción |
|---|---|---|---|
| Oracle XE | sgd-oracle | 1521 | Base de datos |
| Redis | sgd-redis | 6379 | Cache + sesiones |
| Laravel App | sgd-app | 9000 (FPM) | API principal |
| Worker Default | sgd-worker-default | — | Cola de jobs default |
| Worker PQRSD | sgd-worker-pqrsd | — | Cola de jobs pqrsd-ai |
| Scheduler | sgd-scheduler | — | Cron de Laravel |
| Reverb | sgd-reverb | 8080 | WebSocket server |
| OSAI | sgd-osai | 8000 | Microservicio IA |
| Nginx | sgd-nginx | 80/443 | Reverse proxy + SPA |
| Portainer | sgd-portainer | 9001 (localhost) | Dashboard visual |

## Puertos expuestos al exterior

Solo **80** (HTTP) y **443** (HTTPS). Todo lo demás es interno.
Portainer escucha en 127.0.0.1:9001 (acceso vía SSH tunnel):

```bash
ssh -L 9001:localhost:9001 deploy@IP_DEL_VPS
# luego abrir http://localhost:9001 en el navegador
```

## Scripts

| Script | Función |
|---|---|
| `scripts/setup-vps.sh` | Configuración inicial del VPS (usuario, Docker, firewall) |
| `scripts/deploy-laravel.sh` | Migraciones, Passport, caches |
| `scripts/deploy-osai.sh` | Build y despliegue de OSAI |
| `scripts/deploy-front.sh` | Build del frontend y reinicio de Nginx |
| `scripts/healthcheck.sh` | Verifica que todos los servicios estén activos |
| `scripts/backup.sh` | Backup de Oracle + storage |

## Actualizar código

```bash
cd /home/deploy/SDG-Back-api && git pull
cd ../sgd-infra && docker compose restart app worker-default worker-pqrsd scheduler reverb
```

## Backups automáticos (cron)

```bash
crontab -e
# Añadir: 0 3 * * * cd /home/deploy/sgd-infra && bash scripts/backup.sh >> /home/deploy/backups/backup.log 2>&1
```

## Arquitectura

```
Internet → Cloudflare (SSL) → Nginx (:80/:443)
                                   ├── / → SPA (estáticos)
                                   ├── /api → Laravel FPM (:9000)
                                   ├── /ws → Reverb (:8080, WebSocket)
                                   └── /osai-api/ → OSAI (:8000)
                                            ↓ webhook
                                   Laravel ← workers (default + pqrsd-ai)
                                   Oracle (:1521) ← Laravel
                                   Redis (:6379) ← Laravel + Reverb
```
