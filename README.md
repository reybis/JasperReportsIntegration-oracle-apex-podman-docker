# JasperReportsIntegration — Oracle APEX - Podman / Docker

[![APEX Community](https://cdn.rawgit.com/Dani3lSun/apex-github-badges/78c5adbe/badges/apex-community-badge.svg)](https://github.com/Dani3lSun/apex-github-badges)
[![APEX Built with Love](https://cdn.rawgit.com/Dani3lSun/apex-github-badges/7919f913/badges/apex-love-badge.svg)](https://github.com/Dani3lSun/apex-github-badges)

[JasperReportsIntegration](https://github.com/daust/JasperReportsIntegration) usando Podman o Docker.

**Autores:** [@reybis](https://github.com/reybis) · [@lruiz1309](https://github.com/lruiz1309)
**Año:** 2026

---

## Stack

| Componente | Versión |
|---|---|
| JasperReportsIntegration | 3.0.0 (JasperReports 7.0.1) |
| Apache Tomcat | 10.x |
| Java | 17 (Eclipse Temurin) |

---

## Arquitectura

```
  [Host]
     │ :JRI_HOST_PORT
     ▼
┌──────────────────────────────────────────────────────────────┐
│        Red Podman/Docker: CONTAINER_NETWORK                  │
│                                                              │
│   ┌─────────────────────┐   JDBC    ┌─────────────────────┐  │
│   │  JRI_CONTAINER      │ ────────► │  ORACLE_CONTAINER   │  │
│   │  Tomcat 10 / :8080  │           │  ORACLE_SERVICE     │  │
│   │  JRI                │ ◄──────── │  ORACLE_APP_SCHEMA  │  │
│   └─────────────────────┘ UTL_HTTP  └─────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

- **JRI → Oracle**: JDBC para ejecutar las consultas de los reportes
- **Oracle → JRI**: `UTL_HTTP` desde los paquetes PL/SQL para solicitar la generación de reportes

---

## Estructura del proyecto

```
jasper-reports-integration/
├── .env.sample                          # Variables de entorno — copiar a .env y ajustar
├── Dockerfile                           # Imagen: Tomcat 10 + JRI war
├── compose.yml                          # Definición del servicio
├── docker-entrypoint.sh                 # Genera application.properties + seed de reports
├── conf/
│   └── application.properties.template  # Template del datasource JRI (usa vars de .env)
├── reports/                             # Volumen: reportes .jrxml
│   └── demo/                            # Reportes de demo (auto-copiados en primer arranque)
└── scripts/
    └── init-db.sh                       # Instala objetos PL/SQL en Oracle
```

---

## Configuración

### 1. Crear el archivo `.env`

```bash
cp .env.sample .env
```

Editar `.env` con los valores del ambiente:

| Variable | Descripción |
|---|---|
| `ORACLE_CONTAINER` | Nombre del contenedor Oracle (para `podman exec`) |
| `ORACLE_HOST` | Hostname de Oracle en la red Podman (generalmente igual al container name) |
| `ORACLE_PORT` | Puerto interno de Oracle en la red (`1521`) |
| `ORACLE_SERVICE` | Nombre del PDB / servicio (ej. `FREEPDB1`) |
| `ORACLE_SYS_PWD` | Password de `SYS` |
| `ORACLE_APP_SCHEMA` | Schema donde se instalan los objetos PL/SQL de JRI |
| `ORACLE_APP_PWD` | Password del schema de la aplicación |
| `JRI_VERSION` | Versión de JRI a descargar y empaquetar (ej. `3.0.0`) |
| `JRI_JASPER` | Versión de JasperReports incluida en el artefacto (ej. `7.0.1`) |
| `JRI_CONTAINER` | Nombre del contenedor JRI |
| `JRI_HOST_PORT` | Puerto expuesto en el host (ej. `8090`) |
| `PODMAN_NETWORK` | Nombre exacto de la red Podman compartida con Oracle |

> El archivo `conf/application.properties.template` se completa automáticamente con estas variables al iniciar el contenedor. No es necesario editar `application.properties` manualmente.

---

## Primera instalación

### Prerequisitos

- Podman 4+ instalado y corriendo
- Contenedor Oracle activo y accesible en la red Podman definida en `.env`

```bash
# Verificar que la red existe
podman network inspect $PODMAN_NETWORK
```

### Paso 1 — Build

```bash
source .env
cd jasper-reports-integration
podman build \
  --build-arg JRI_VERSION=$JRI_VERSION \
  --build-arg JRI_JASPER=$JRI_JASPER \
  -t jri:$JRI_VERSION .
```

### Paso 2 — Levantar el contenedor JRI

```bash
podman run -d \
  --name $JRI_CONTAINER \
  --network $PODMAN_NETWORK \
  -p $JRI_HOST_PORT:8080 \
  --env-file .env \
  -e OC_JASPER_CONFIG_HOME=/opt/jri \
  -v "$(pwd)/reports:/opt/jri/reports:z" \
  --restart on-failure:3 \
  localhost/jri:$JRI_VERSION
```

> Si `reports/` está vacío, el entrypoint copia automáticamente los reportes de demo al arrancar.

### Paso 3 — Instalar objetos PL/SQL en Oracle

```bash
bash scripts/init-db.sh
```

El script lee `.env`, valida las variables y ejecuta 4 pasos:

| Paso | Qué hace |
|---|---|
| 1 | `sys_install.sql` — permisos al schema (`CONNECT`, `RESOURCE`, `CREATE VIEW`, `EXECUTE ON UTL_HTTP`) |
| 2 | ACL de red — permite que el schema haga llamadas HTTP al contenedor JRI |
| 3 | `user_install.sql` — tablas, secuencias y paquetes PL/SQL (`XLIB_JASPERREPORTS`, `XLIB_HTTP`, `XLIB_LOG`, etc.) |
| 4 | Actualiza `XLIB_JASPERREPORTS_CONF` — apunta al contenedor JRI en el puerto interno `8080` |

### Paso 4 — Verificar

```bash
# Cargar variables del .env
source .env

# El endpoint debe responder HTTP 200 o 302
curl -o /dev/null -w "%{http_code}\n" http://localhost:${JRI_HOST_PORT}/jri
```

Página de estado completa: **`http://localhost:${JRI_HOST_PORT}/jri`**

```bash
# Verificar objetos instalados en Oracle
podman exec $ORACLE_CONTAINER \
  sqlplus -s ${ORACLE_APP_SCHEMA}/${ORACLE_APP_PWD}@localhost:${ORACLE_PORT}/${ORACLE_SERVICE} <<'EOF'
SELECT object_name, object_type, status
FROM user_objects
WHERE object_name LIKE 'XLIB%'
ORDER BY object_type, object_name;
exit
EOF
```

---

## Re-despliegue del contenedor JRI

Usar cuando cambia el `Dockerfile`, el template de configuración o la versión de JRI.
**No requiere volver a ejecutar `init-db.sh`.**

```bash
source .env

podman rm -f $JRI_CONTAINER
podman rmi localhost/jri:$JRI_VERSION
podman build \
  --build-arg JRI_VERSION=$JRI_VERSION \
  --build-arg JRI_JASPER=$JRI_JASPER \
  -t jri:$JRI_VERSION .
podman run -d \
  --name $JRI_CONTAINER \
  --network $PODMAN_NETWORK \
  -p $JRI_HOST_PORT:8080 \
  --env-file .env \
  -e OC_JASPER_CONFIG_HOME=/opt/jri \
  -v "$(pwd)/reports:/opt/jri/reports:z" \
  --restart on-failure:3 \
  localhost/jri:$JRI_VERSION
```

---

## Re-despliegue completo (contenedor + base de datos)

Usar al partir desde cero: ambiente nuevo, schema borrado o cambio de credenciales.

```bash
source .env

# 1. Limpiar
podman rm -f $JRI_CONTAINER
podman rmi localhost/jri:$JRI_VERSION

# Opcional: forzar descarga fresca de la imagen base
podman rmi docker.io/library/tomcat:10-jre17-temurin

# 2. Build
podman build \
  --build-arg JRI_VERSION=$JRI_VERSION \
  --build-arg JRI_JASPER=$JRI_JASPER \
  -t jri:$JRI_VERSION .

# 3. Contenedor
podman run -d \
  --name $JRI_CONTAINER \
  --network $PODMAN_NETWORK \
  -p $JRI_HOST_PORT:8080 \
  --env-file .env \
  -e OC_JASPER_CONFIG_HOME=/opt/jri \
  -v "$(pwd)/reports:/opt/jri/reports:z" \
  --restart on-failure:3 \
  localhost/jri:$JRI_VERSION

# 4. Base de datos
bash scripts/init-db.sh
```

---

## Gestión de reportes

Los reportes `.jrxml` se sirven desde `reports/` en el host (volumen montado). Los cambios son inmediatos sin reiniciar el contenedor.

```bash
# Agregar un reporte propio
cp mi_reporte.jrxml reports/

# Confirmarlo dentro del contenedor
source .env && podman exec $JRI_CONTAINER ls /opt/jri/reports/
```

Los reportes de demo (`reports/demo/`) se copian automáticamente al primer arranque si el directorio está vacío.

---

## Comandos de operación

```bash
source .env

# Logs en tiempo real
podman logs -f $JRI_CONTAINER

# Log de la aplicación JRI
podman exec $JRI_CONTAINER tail -f /opt/jri/logs/JasperReportsIntegration.log

# Log de Tomcat
podman exec $JRI_CONTAINER tail -f /usr/local/tomcat/logs/catalina.$(date +%Y-%m-%d).log

# Reiniciar sin rebuild
podman restart $JRI_CONTAINER

# Estado del contenedor
podman ps --filter name=$JRI_CONTAINER

# Verificar configuración activa en Oracle
podman exec $ORACLE_CONTAINER \
  sqlplus -s ${ORACLE_APP_SCHEMA}/${ORACLE_APP_PWD}@localhost:${ORACLE_PORT}/${ORACLE_SERVICE} <<'EOF'
SELECT conf_id, conf_protocol, conf_server, conf_port, conf_context_path
FROM xlib_jasperreports_conf;
exit
EOF
```

---

## Problemas conocidos

### `ORA-24247: network access denied by access control list (ACL)`

El paso 4 del `init-db.sh` actualiza `XLIB_JASPERREPORTS_CONF` para apuntar al nombre del contenedor JRI. Si se saltó ese paso o se cambió el nombre del contenedor, corregir manualmente:

```sql
UPDATE xlib_jasperreports_conf
SET conf_server = '<JRI_CONTAINER>',
    conf_port   = '8080'
WHERE conf_id = 'MAIN';
COMMIT;
```

### Check 4 (Install Tomcat) muestra ❌ en la página de estado

Falso positivo. El test apunta a `http://<JRI_CONTAINER>:8080` (raíz de Tomcat) que retorna 404 porque el único contexto disponible es `/jri`. La propia página de JRI indica que puede ignorarse si los demás checks requeridos (*) pasan.

### Los reportes de demo no cargan

El seed automático solo se ejecuta si `reports/` está vacío **al iniciar** el contenedor. Si ya existe el contenedor y el directorio quedó vacío después:

```bash
source .env
podman rm -f $JRI_CONTAINER
rm -rf reports/*
# El próximo arranque detecta el directorio vacío y hace el seed
podman run -d ... localhost/jri:$JRI_VERSION
```

---

## Créditos

- **JasperReportsIntegration** — proyecto open source creado y mantenido por [@daust](https://github.com/daust) (Dietmar Aust, Opal Consulting). Licencia BSD-3-Clause.
  Repositorio: https://github.com/daust/JasperReportsIntegration
