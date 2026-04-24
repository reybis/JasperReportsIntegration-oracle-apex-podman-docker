#!/bin/bash
set -e

# Generar application.properties desde el template usando las variables de entorno
echo "[JRI] Generando application.properties desde template..."
envsubst '${ORACLE_HOST}${ORACLE_PORT}${ORACLE_SERVICE}${ORACLE_APP_SCHEMA}${ORACLE_APP_PWD}' \
  < /opt/jri/conf/application.properties.template \
  > /opt/jri/conf/application.properties

# Seed de reportes de demo si el volumen está vacío
if [ -z "$(ls -A /opt/jri/reports 2>/dev/null)" ]; then
    echo "[JRI] reports/ vacío — copiando reportes de demo..."
    cp -r /opt/jri/reports-default/. /opt/jri/reports/
fi

exec "$@"
