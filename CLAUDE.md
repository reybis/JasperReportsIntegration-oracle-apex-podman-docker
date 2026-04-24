# CLAUDE.md

## What this project is

Containerización de [JasperReportsIntegration](https://github.com/daust/JasperReportsIntegration) (JRI) sobre Oracle Database 26ai usando Podman en macOS Apple Silicon. JRI expone un endpoint HTTP que Oracle llama vía `UTL_HTTP` para generar reportes `.jrxml` desde PL/SQL.

## Single source of truth: `.env`

Todas las variables de entorno viven en `.env` (gitignored). Copiar desde `.env.sample` antes de operar. Las variables requeridas son:

```
ORACLE_CONTAINER, ORACLE_HOST, ORACLE_PORT, ORACLE_SERVICE
ORACLE_SYS_PWD, ORACLE_APP_SCHEMA, ORACLE_APP_PWD
JRI_VERSION, JRI_JASPER
JRI_CONTAINER, JRI_HOST_PORT, PODMAN_NETWORK
```

`JRI_VERSION` y `JRI_JASPER` controlan qué artefactos se descargan tanto en el build de la imagen como en `init-db.sh`.

## Comandos operacionales

```bash
source .env

# Build
podman build \
  --build-arg JRI_VERSION=$JRI_VERSION \
  --build-arg JRI_JASPER=$JRI_JASPER \
  -t jri:$JRI_VERSION .

# Iniciar contenedor
mkdir -p reports
podman run -d \
  --name $JRI_CONTAINER \
  --network $PODMAN_NETWORK \
  -p $JRI_HOST_PORT:8080 \
  --env-file .env \
  -e OC_JASPER_CONFIG_HOME=/opt/jri \
  -v "$(pwd)/reports:/opt/jri/reports:z" \
  --restart on-failure:3 \
  localhost/jri:$JRI_VERSION

# Instalar objetos PL/SQL en Oracle (solo primera vez o tras borrar el schema)
bash scripts/init-db.sh

# Verificar
curl -o /dev/null -w "%{http_code}\n" http://localhost:${JRI_HOST_PORT}/jri

# Logs en tiempo real
podman logs -f $JRI_CONTAINER
podman exec $JRI_CONTAINER tail -f /opt/jri/logs/JasperReportsIntegration.log

# Re-despliegue rápido (sin tocar la base de datos)
podman rm -f $JRI_CONTAINER && podman rmi localhost/jri:$JRI_VERSION
# luego build + run como arriba
```

## Arquitectura

```
[Host macOS :JRI_HOST_PORT]
        │
        ▼
[Red Podman: PODMAN_NETWORK]
   ┌──────────────────┐  JDBC   ┌─────────────────────┐
   │  JRI_CONTAINER   │ ──────► │  ORACLE_CONTAINER   │
   │  Tomcat 10/:8080 │ ◄────── │  ORACLE_APP_SCHEMA  │
   └──────────────────┘ UTL_HTTP└─────────────────────┘
```

- **Oracle → JRI**: PL/SQL llama `XLIB_JASPERREPORTS.get_report(...)` → el paquete usa `UTL_HTTP` para llamar al endpoint JRI en `conf_server:conf_port` (almacenado en `XLIB_JASPERREPORTS_CONF`).
- **JRI → Oracle**: JDBC con las credenciales de `ORACLE_APP_SCHEMA` para ejecutar la query del `.jrxml`.

## Cómo interactúan los archivos clave

| Archivo | Rol |
|---|---|
| `Dockerfile` | Descarga zip JRI, extrae `conf/` → `/opt/jri/conf/`, `reports/` → `/opt/jri/reports-default/`, war Tomcat10 → `/usr/local/tomcat/webapps/jri.war` |
| `docker-entrypoint.sh` | Al arrancar: corre `envsubst` sobre el template → genera `application.properties`; si `reports/` está vacío, copia `reports-default/` |
| `conf/application.properties.template` | Template INI con `${ORACLE_HOST}`, `${ORACLE_PORT}`, `${ORACLE_SERVICE}`, `${ORACLE_APP_SCHEMA}`, `${ORACLE_APP_PWD}` |
| `scripts/init-db.sh` | Descarga el zip de JRI, copia los SQL al contenedor Oracle, ejecuta 4 pasos: grants SYSDBA, ACL de red, `user_install.sql`, UPDATE de `XLIB_JASPERREPORTS_CONF` |
| `compose.yml` | Alternativa a `podman run` manual; pasa `JRI_VERSION`/`JRI_JASPER` como `build.args` |

## Consideraciones críticas

**Heredoc en init-db.sh (paso 2 — ACL):** el bloque PL/SQL usa `<<'SQLEOF'` (delimitador entre comillas simples) para evitar que bash expanda `$ace_type` dentro del PL/SQL. Los valores de shell como `${JRI_CONTAINER}` son sustituidos por el shell exterior antes de que `bash -c` ejecute el heredoc.

**`XLIB_JASPERREPORTS_CONF`:** Oracle llama a JRI usando `conf_server` y `conf_port` de esta tabla. El valor por defecto del zip (`localhost:8090`) apunta al host, no al contenedor JRI. El paso 4 de `init-db.sh` lo corrige a `$JRI_CONTAINER:8080`.

**`reportsPath=` en application.properties:** debe existir (aunque vacío). Si se omite la línea, JRI lanza `StringIndexOutOfBoundsException` al parsear el INI.

**Volumen `reports/`:** el directorio debe existir en el host antes de `podman run` (`mkdir -p reports`); si no existe, Podman lo crea como root y el entrypoint no puede escribir en él.

**`user_install.sql` es idempotente para objetos compilados** (paquetes, procedimientos) pero no para tablas/secuencias — los errores ORA-00955 al re-ejecutar `init-db.sh` sobre un schema existente son esperados e inofensivos.
