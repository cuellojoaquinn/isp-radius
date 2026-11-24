#!/bin/bash
# Uso: cambiar_plan.sh <usuario> <plan>    ej: cambiar_plan.sh abonado1 plan-10m
# Si el servicio está activo y conectado, aplica la velocidad nueva en caliente (CoA).
set -euo pipefail
source "$(dirname "$0")/.env"
RADIUS=${RADIUS_COA:-10.10.10.10:3799}
USUARIO=${1:?Uso: cambiar_plan.sh <usuario> <plan>}; PLAN=${2:?falta el plan}

RESULT=$(docker exec -i postgres psql -U facturacion -d radius -tA -F ' ' -v ON_ERROR_STOP=1 \
         -v u="$USUARIO" -v p="$PLAN" <<'SQL'
SELECT * FROM facturacion.cambiar_plan(:'u', :'p');
SQL
)
echo "Plan de $USUARIO cambiado a $PLAN"

if [ -z "$RESULT" ]; then
  echo "  sin sesión activa (o servicio no activo): se aplica en la próxima conexión"
  exit 0
fi

read -r NAS RATE <<< "$RESULT"
salida=$(printf 'User-Name = %s\nMikrotik-Rate-Limit = "%s"\nMessage-Authenticator = 0x00\n' "$USUARIO" "$RATE" \
         | radclient -x "$RADIUS" coa "$RADIUS_SECRET_FACTURACION" 2>&1 || true)
if echo "$salida" | grep -q "CoA-ACK"; then
  echo "  velocidad cambiada en caliente a $RATE en $NAS (CoA-ACK)"
else
  echo "  ATENCIÓN: no se pudo aplicar en caliente; se aplica en la próxima conexión"
fi
