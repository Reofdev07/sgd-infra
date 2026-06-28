#!/bin/bash
# scripts/setup-vps.sh — Configuración inicial del VPS Contabo (Ubuntu 22.04)
# Ejecutar como root: sudo bash setup-vps.sh
set -e

echo "=== Configuración inicial del VPS ==="

# 1. Crear usuario no-root
if ! id "deploy" &>/dev/null; then
    adduser --disabled-password --gecos "" deploy
    usermod -aG sudo deploy
    echo "deploy ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deploy
    echo "Usuario 'deploy' creado con sudo."
else
    echo "Usuario 'deploy' ya existe."
fi

# 2. Actualizar sistema
apt-get update && apt-get upgrade -y

# 3. Instalar Docker
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker deploy
    echo "Docker instalado."
else
    echo "Docker ya está instalado."
fi

# 4. Instalar Node.js 20 (para build del frontend)
if ! command -v node &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
    echo "Node.js 20 instalado."
else
    echo "Node.js ya está instalado: $(node --version)"
fi

# 5. Herramientas útiles
apt-get install -y git curl wget unzip htop tmux fail2ban

# 6. Firewall (UFW) — solo SSH, HTTP, HTTPS
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
yes | ufw enable

# 7. fail2ban (protección contra ataques SSH)
systemctl enable fail2ban
systemctl start fail2ban

# 8. Crear estructura de directorios
mkdir -p /home/deploy
chown deploy:deploy /home/deploy

echo ""
echo "=== Configuración completada ==="
echo "Pasos siguientes (como usuario deploy):"
echo "  1. ssh deploy@IP_DEL_VPS"
echo "  2. cd /home/deploy"
echo "  3. git clone <SDG-Back-api>"
echo "  4. git clone <SGD-Front>"
echo "  5. git clone <OSAI>"
echo "  6. git clone <sgd-infra>"
echo "  7. cd sgd-infra && cp .env.example .env && editar .env"
echo "  8. cd ../SGD-Front && npm ci && NODE_ENV=production npm run build"
echo "  9. cd ../sgd-infra && docker compose up -d"
