#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Cargar variables ──────────────────────────────────────────
if [[ ! -f .env ]]; then
  echo "ERROR: .env no encontrado. Copia .env.sample y ajusta las variables." >&2
  exit 1
fi
set -a; source .env; set +a

# ── Limpieza previa ───────────────────────────────────────────
if podman container exists "$JRI_CONTAINER" 2>/dev/null; then
  echo ">>> Eliminando contenedor existente: $JRI_CONTAINER"
  podman rm -f "$JRI_CONTAINER"
fi

if podman image exists "localhost/jri:$JRI_VERSION" 2>/dev/null; then
  echo ">>> Eliminando imagen existente: localhost/jri:$JRI_VERSION"
  podman rmi "localhost/jri:$JRI_VERSION"
fi

# ── Build ─────────────────────────────────────────────────────
echo ">>> Build imagen jri:$JRI_VERSION"
podman build \
  --build-arg JRI_VERSION="$JRI_VERSION" \
  --build-arg JRI_JASPER="$JRI_JASPER" \
  -t "jri:$JRI_VERSION" \
  .

# ── Preparar volumen de reportes ──────────────────────────────
mkdir -p "$SCRIPT_DIR/reports"

# ── Iniciar contenedor ────────────────────────────────────────
echo ">>> Iniciando contenedor $JRI_CONTAINER"
podman run -d \
  --name "$JRI_CONTAINER" \
  --network "$PODMAN_NETWORK" \
  -p "${JRI_HOST_PORT}:8080" \
  --env-file .env \
  -e OC_JASPER_CONFIG_HOME=/opt/jri \
  -v "$SCRIPT_DIR/reports:/opt/jri/reports:z" \
  --restart on-failure:3 \
  "localhost/jri:$JRI_VERSION"

# ── Verificar ─────────────────────────────────────────────────
echo ">>> Esperando que JRI arranque..."
for i in $(seq 1 12); do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${JRI_HOST_PORT}/jri" 2>/dev/null || true)
  if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "302" ]]; then
    echo ">>> JRI disponible — http://localhost:${JRI_HOST_PORT}/jri  [HTTP $HTTP_CODE]"
    exit 0
  fi
  echo "    intento $i/12 — HTTP $HTTP_CODE — esperando 5s..."
  sleep 5
done

echo "ERROR: JRI no respondió en 60s. Revisando logs:" >&2
podman logs --tail 30 "$JRI_CONTAINER" >&2
exit 1
