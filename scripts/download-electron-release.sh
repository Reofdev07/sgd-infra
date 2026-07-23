#!/bin/bash
# download-electron-release.sh
# Descarga el instalador .exe de Windows desde GitHub Releases y lo copia al
# directorio downloads/ para que nginx lo sirva en demo.aviliontech.com/downloads/
#
# Requisitos:
#   - GITHUB_TOKEN configurado en el VPS (export GITHUB_TOKEN=ghp_xxx)
#   - Repositorio SGD-Front debe estar clonado en /home/deploy/SGD-Front
#
# Uso:
#   bash scripts/download-electron-release.sh
#   # o especificar una versión:
#   bash scripts/download-electron-release.sh v1.2.0

set -euo pipefail

REPO="Reofdev07/SGD-Front"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
DOWNLOADS_DIR="${INFRA_DIR}/downloads"
TAG="${1:-latest}"

echo "=== Descargando instalador Windows desde GitHub Releases ==="

mkdir -p "$DOWNLOADS_DIR"

if [ "$TAG" == "latest" ]; then
    echo "📡 Obteniendo el release más reciente de $REPO..."
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        RELEASE_TAG=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
            "https://api.github.com/repos/$REPO/releases/latest" \
            | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    else
        RELEASE_TAG=$(curl -s \
            "https://api.github.com/repos/$REPO/releases/latest" \
            | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
    fi
    if [ -z "$RELEASE_TAG" ]; then
        echo "❌ No se pudo obtener el release más reciente (¿repositorio privado sin token?)"
        exit 1
    fi
    TAG="$RELEASE_TAG"
fi

echo "📦 Versión: $TAG"
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/MR7-SGD-Setup.exe"

echo "⬇️  Descargando $DOWNLOAD_URL ..."
if [ -n "${GITHUB_TOKEN:-}" ]; then
    curl -L -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/octet-stream" \
        -o "$DOWNLOADS_DIR/MR7-SGD-Setup.exe" \
        "$DOWNLOAD_URL"
else
    curl -L -o "$DOWNLOADS_DIR/MR7-SGD-Setup.exe" "$DOWNLOAD_URL"
fi

if [ -f "$DOWNLOADS_DIR/MR7-SGD-Setup.exe" ]; then
    chmod 644 "$DOWNLOADS_DIR/MR7-SGD-Setup.exe"
    echo "✅ Instalador guardado en $DOWNLOADS_DIR/MR7-SGD-Setup.exe"
    echo "   Tamaño: $(du -h "$DOWNLOADS_DIR/MR7-SGD-Setup.exe" | cut -f1)"
else
    echo "❌ Error: no se generó el archivo"
    exit 1
fi

echo "🔁 Reiniciando nginx para servir el nuevo instalador..."
docker compose restart nginx

echo "✅ Listo. Disponible en: https://demo.aviliontech.com/downloads/MR7-SGD-Setup.exe"
