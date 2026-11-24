#!/bin/bash
# Uso: cambiar_password.sh <usuario> <contraseña-nueva>
set -euo pipefail
USUARIO=${1:?Uso: cambiar_password.sh <usuario> <contraseña>}; PASS=${2:?falta la contraseña}
docker exec -i postgres psql -U facturacion -d radius -tA -v ON_ERROR_STOP=1 \
  -v u="$USUARIO" -v pw="$PASS" >/dev/null <<'SQL'
SELECT facturacion.cambiar_password(:'u', :'pw');
SQL
echo "Contraseña de $USUARIO cambiada (vale desde la próxima autenticación)"
