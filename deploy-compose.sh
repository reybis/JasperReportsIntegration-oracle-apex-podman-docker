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

# ── Verificar podman-compose ──────────────────────────────────
if ! command -v podman-compose &>/dev/null; then
  echo "ERROR: podman-compose no está instalado." >&2
  echo "       Instalar con: pip3 install podman-compose" >&2
  exit 1
fi

# ── Preparar volumen de reportes ──────────────────────────────
mkdir -p "$SCRIPT_DIR/reports"

# ── Bajar stack existente y reconstruir ───────────────────────
echo ">>> Bajando stack existente (si existe)"
podman-compose down --rmi local 2>/dev/null || true

echo ">>> Build e inicio con podman-compose"
podman-compose up -d --build

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
podman-compose logs --tail 30 >&2
exit 1
