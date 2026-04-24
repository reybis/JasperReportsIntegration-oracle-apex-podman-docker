#!/usr/bin/env bash
# Instala los objetos PL/SQL de JasperReportsIntegration en Oracle
# Uso: bash scripts/init-db.sh
set -euo pipefail

# ── Cargar variables desde .env ────────────────────────────────────────────────
ENV_FILE="$(dirname "$0")/../.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
else
    echo "ERROR: No se encontró el archivo .env en $(realpath "$ENV_FILE")"
    echo "       Copia .env.sample a .env y ajusta los valores."
    exit 1
fi

# ── Validar variables requeridas ───────────────────────────────────────────────
: "${ORACLE_CONTAINER:?Variable ORACLE_CONTAINER no definida en .env}"
: "${ORACLE_HOST:?Variable ORACLE_HOST no definida en .env}"
: "${ORACLE_PORT:?Variable ORACLE_PORT no definida en .env}"
: "${ORACLE_SERVICE:?Variable ORACLE_SERVICE no definida en .env}"
: "${ORACLE_SYS_PWD:?Variable ORACLE_SYS_PWD no definida en .env}"
: "${ORACLE_APP_SCHEMA:?Variable ORACLE_APP_SCHEMA no definida en .env}"
: "${ORACLE_APP_PWD:?Variable ORACLE_APP_PWD no definida en .env}"
: "${JRI_CONTAINER:?Variable JRI_CONTAINER no definida en .env}"

# ── Validar variables de versión ───────────────────────────────────────────────
: "${JRI_VERSION:?Variable JRI_VERSION no definida en .env}"
: "${JRI_JASPER:?Variable JRI_JASPER no definida en .env}"

# ── Configuración derivada ─────────────────────────────────────────────────────
JRI_INTERNAL_PORT="${JRI_INTERNAL_PORT:-8080}"
CONN_INTERNAL="localhost:${ORACLE_PORT}"
APP_SCHEMA_UPPER=$(echo "$ORACLE_APP_SCHEMA" | tr '[:lower:]' '[:upper:]')

TMPDIR_HOST=$(mktemp -d)
TMPDIR_CTR="/tmp/jri_sql_$$"
cleanup() { rm -rf "$TMPDIR_HOST"; }
trap cleanup EXIT

echo "==> Descargando SQL scripts (JRI v${JRI_VERSION})..."
ZIP_URL="https://github.com/daust/JasperReportsIntegration/releases/download/v${JRI_VERSION}/jri-${JRI_VERSION}-jasper-${JRI_JASPER}.zip"
curl -fsSL "$ZIP_URL" -o "$TMPDIR_HOST/jri.zip"
unzip -q "$TMPDIR_HOST/jri.zip" -d "$TMPDIR_HOST/"
SQL_DIR="$TMPDIR_HOST/jri-${JRI_VERSION}-jasper-${JRI_JASPER}/sql"

echo "==> Copiando scripts al contenedor Oracle..."
podman exec "$ORACLE_CONTAINER" mkdir -p "$TMPDIR_CTR"
podman cp "$SQL_DIR/." "${ORACLE_CONTAINER}:${TMPDIR_CTR}/"

echo ""
echo "══════════════════════════════════════════════"
echo " Paso 1/4 — sys_install.sql  (como SYSDBA)"
echo "══════════════════════════════════════════════"
podman exec "$ORACLE_CONTAINER" bash -c "
  cd '${TMPDIR_CTR}' && \
  echo '@sys_install.sql ${ORACLE_APP_SCHEMA}
exit' | sqlplus -s \"sys/${ORACLE_SYS_PWD}@${CONN_INTERNAL}/${ORACLE_SERVICE} as sysdba\"
"

echo ""
echo "══════════════════════════════════════════════"
echo " Paso 2/4 — ACL de red  (como SYSDBA)"
echo " Permite que ${ORACLE_APP_SCHEMA} llame HTTP al contenedor ${JRI_CONTAINER}"
echo "══════════════════════════════════════════════"
podman exec "$ORACLE_CONTAINER" bash -c "
  sqlplus -s \"sys/${ORACLE_SYS_PWD}@${CONN_INTERNAL}/${ORACLE_SERVICE} as sysdba\" <<'SQLEOF'
BEGIN
   DBMS_NETWORK_ACL_ADMIN.append_host_ace(
      HOST  => '${JRI_CONTAINER}',
      ace   => xs\$ace_type(
                  privilege_list => xs\$name_list('http'),
                  principal_name => '${APP_SCHEMA_UPPER}',
                  principal_type => xs_acl.ptype_db));
END;
/
COMMIT;
exit
SQLEOF
"

echo ""
echo "══════════════════════════════════════════════"
echo " Paso 3/4 — user_install.sql  (como ${ORACLE_APP_SCHEMA})"
echo "══════════════════════════════════════════════"
podman exec "$ORACLE_CONTAINER" bash -c "
  export NLS_LANG=AMERICAN_AMERICA.AL32UTF8
  cd '${TMPDIR_CTR}' && \
  echo '@user_install.sql
exit' | sqlplus -s \"${ORACLE_APP_SCHEMA}/${ORACLE_APP_PWD}@${CONN_INTERNAL}/${ORACLE_SERVICE}\"
"

echo ""
echo "══════════════════════════════════════════════"
echo " Paso 4/4 — Actualizar XLIB_JASPERREPORTS_CONF"
echo " Apuntar a ${JRI_CONTAINER}:${JRI_INTERNAL_PORT}"
echo "══════════════════════════════════════════════"
podman exec "$ORACLE_CONTAINER" bash -c "
  sqlplus -s \"${ORACLE_APP_SCHEMA}/${ORACLE_APP_PWD}@${CONN_INTERNAL}/${ORACLE_SERVICE}\" << SQLEOF
UPDATE xlib_jasperreports_conf
SET conf_server = '${JRI_CONTAINER}',
    conf_port   = '${JRI_INTERNAL_PORT}'
WHERE conf_id = 'MAIN';
COMMIT;
exit
SQLEOF
"

echo ""
echo "==> Limpiando archivos temporales del contenedor..."
podman exec "$ORACLE_CONTAINER" rm -rf "$TMPDIR_CTR"

echo ""
echo "✓ Instalación completada."
echo ""
echo "  Verificar objetos instalados:"
echo "  podman exec -it ${ORACLE_CONTAINER} sqlplus ${ORACLE_APP_SCHEMA}/${ORACLE_APP_PWD}@${CONN_INTERNAL}/${ORACLE_SERVICE}"
echo "  SQL> SELECT object_name, object_type, status FROM user_objects WHERE object_name LIKE 'XLIB%' ORDER BY 1;"
