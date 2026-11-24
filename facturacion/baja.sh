#!/bin/bash
# Uso: baja.sh <usuario>
# Pasa el servicio a inactivo (grupo baja, rechaza) y corta la sesión si está conectado.
set -euo pipefail
source "$(dirname "$0")/.env"
RADIUS=${RADIUS_COA:-10.10.10.10:3799}
USUARIO=${1:?Uso: baja.sh <usuario>}

NAS=$(docker exec -i postgres psql -U facturacion -d radius -tA -v ON_ERROR_STOP=1 \
      -v u="$USUARIO" <<'SQL'
SELECT facturacion.baja_servicio(:'u');
SQL
)
echo "Baja registrada: $USUARIO"

if [ -z "$NAS" ]; then
  echo "  sin sesión abierta: no hace falta Disconnect"
  exit 0
fi

salida=$(printf 'User-Name = %s\nMessage-Authenticator = 0x00\n' "$USUARIO" \
         | radclient -x "$RADIUS" disconnect "$RADIUS_SECRET_FACTURACION" 2>&1 || true)
if echo "$salida" | grep -q "Disconnect-ACK"; then
  echo "  sesión en $NAS cortada"
else
  echo "  ATENCIÓN: no se pudo cortar la sesión en $NAS"
fi
