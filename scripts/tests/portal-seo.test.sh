#!/bin/bash
# Prueba de scripts/lib/portal-seo.sh. Uso: bash scripts/tests/portal-seo.test.sh
set -u
cd "$(dirname "$0")/../.."
source scripts/lib/portal-seo.sh

FAILS=0
check() { # check "descripción" comando...
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "  ok   $name"; else echo "  FALLA $name"; FAILS=$((FAILS + 1)); fi
}
has() { grep -qF -- "$2" "$1"; }
lacks() { ! grep -qF -- "$2" "$1"; }

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT

echo "Con PORTAL_INDEXABLE=true"
write_portal_seo "$DIR" "alcaldia.gov.co" "true" >/dev/null
check "robots apunta al mapa del sitio" has "$DIR/robots.txt" "Sitemap: https://alcaldia.gov.co/sitemap.xml"
check "robots permite el portal" has "$DIR/robots.txt" "Allow: /public"
check "robots bloquea lo demás (sistema interno, inicio de sesión)" has "$DIR/robots.txt" "Disallow: /"
check "robots no nombra rutas internas" lacks "$DIR/robots.txt" "login"
# El portal es una aplicación: sin sus archivos y sus datos públicos el buscador solo vería una página vacía.
for needed in "Allow: /assets/" "Allow: /icons/" "Allow: /config.json" "Allow: /api/public/portal" "Allow: /api/public/ventanilla/config"; do
    check "robots deja leer lo que la página necesita: $needed" has "$DIR/robots.txt" "$needed"
done
check "robots no abre el resto de la API" lacks "$DIR/robots.txt" "Allow: /api/public/documents"
check "el mapa lista las nueve páginas" test "$(grep -c '<loc>' "$DIR/sitemap.xml")" = "9"
check "el mapa incluye Radicar" has "$DIR/sitemap.xml" "<loc>https://alcaldia.gov.co/public/radicar</loc>"
check "el mapa incluye Verificar" has "$DIR/sitemap.xml" "<loc>https://alcaldia.gov.co/verificar</loc>"
check "el mapa no trae direcciones con radicado ni código" lacks "$DIR/sitemap.xml" "radicado="
check "el mapa es XML bien formado" python3 -c "import sys, xml.dom.minidom; xml.dom.minidom.parse('$DIR/sitemap.xml')"

for value in "false" "" "TRUE" "1" "si"; do
    echo "Con PORTAL_INDEXABLE='$value'"
    write_portal_seo "$DIR" "alcaldia.gov.co" "$value" >/dev/null
    check "robots bloquea todo" test "$(cat "$DIR/robots.txt")" = "$(printf 'User-agent: *\nDisallow: /')"
    check "no queda mapa del sitio (ni uno anterior)" test ! -e "$DIR/sitemap.xml"
done

echo "Sin tercer argumento ni dominio"
write_portal_seo "$DIR" "alcaldia.gov.co" >/dev/null
check "sin argumento: bloquea todo" has "$DIR/robots.txt" "Disallow: /"
write_portal_seo "$DIR" "" "true" >/dev/null
check "sin dominio: bloquea todo aunque esté encendido" test ! -e "$DIR/sitemap.xml"

if [ "$FAILS" -gt 0 ]; then echo "FALLARON $FAILS comprobaciones"; exit 1; fi
echo "Todo correcto"
