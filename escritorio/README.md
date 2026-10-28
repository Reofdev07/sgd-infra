# App de escritorio: instaladores y canal de actualizaciones

nginx sirve esta carpeta en `https://DOMINIO/escritorio/` (solo lectura). Va fuera de `dist/` para que el despliegue
del front no la borre.

- `tauri/latest.json`: versión vigente; los programas instalados lo consultan al abrir (sin caché).
- `tauri/MR7 SGD_<versión>_x64-setup.exe` y su `.sig`: el instalador que descarga la actualización.
- `tauri/MR7 SGD_<versión>_x64_en-US.msi`: el instalador para el área de sistemas.

Publicar una versión: bajar el artifact `escritorio-<versión>` del flujo «Escritorio» de SGD-Front (armado para
este dominio), copiar sus archivos a `tauri/` y reemplazar `latest.json` **al final**. Así ningún programa ve la
versión nueva antes de que su instalador esté completo.
