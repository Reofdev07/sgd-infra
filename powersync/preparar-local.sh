#!/bin/bash
# Prepara el Postgres LOCAL para PowerSync con las contraseñas de desarrollo (las del override). Se puede repetir.
# Mismo procedimiento que producción: powersync/preparar.sh.
set -euo pipefail
cd "$(dirname "$0")"
POWERSYNC_REP_PASSWORD=powersync_rep_local POWERSYNC_STORAGE_PASSWORD=powersync_storage_local \
    POWERSYNC_ADMIN_TOKEN=solo-local-desarrollo \
    POSTGRES_USER=sgd POSTGRES_DB=sgd bash ./preparar.sh
