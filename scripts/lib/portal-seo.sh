#!/bin/bash
# scripts/lib/portal-seo.sh — robots.txt y mapa del sitio del portal ciudadano.
#
# write_portal_seo DIR DOMINIO INDEXABLE
#   INDEXABLE=true  → robots.txt permite solo el portal público y apunta al mapa del sitio, que lista las
#                     páginas informativas (nunca direcciones con número de radicado o código).
#   cualquier otro valor (o vacío) → robots.txt bloquea todo y no queda mapa del sitio.
# Apagado por defecto: una instalación de pruebas no debe aparecer en buscadores.

PORTAL_SEO_PAGES=(
    "/public"
    "/public/radicar"
    "/public/consulta"
    "/public/informes"
    "/public/ayuda"
    "/public/acerca"
    "/public/terminos"
    "/public/privacidad"
    "/verificar"
)

write_portal_seo() {
    local dir="$1" domain="$2" indexable="${3:-false}"

    if [ "$indexable" != "true" ] || [ -z "$domain" ]; then
        printf 'User-agent: *\nDisallow: /\n' > "$dir/robots.txt"
        rm -f "$dir/sitemap.xml"
        echo "robots.txt: el sitio NO se ofrece a los buscadores (PORTAL_INDEXABLE distinto de true)"
        return 0
    fi

    {
        echo "User-agent: *"
        echo "Allow: /public"
        echo "Allow: /verificar\$"
        echo "Disallow: /"
        echo ""
        echo "Sitemap: https://${domain}/sitemap.xml"
    } > "$dir/robots.txt"

    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
        local page
        for page in "${PORTAL_SEO_PAGES[@]}"; do
            echo "  <url><loc>https://${domain}${page}</loc></url>"
        done
        echo '</urlset>'
    } > "$dir/sitemap.xml"
    echo "robots.txt y sitemap.xml generados para https://${domain} (${#PORTAL_SEO_PAGES[@]} páginas)"
}
