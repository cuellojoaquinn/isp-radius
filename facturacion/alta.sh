#!/bin/bash
# Uso: alta.sh "<cliente>" <plan> <usuario> <contraseña>
#   ej: alta.sh "Juan Pérez" plan-50m abonado3 secreto33
set -euo pipefail
CLIENTE=${1:?Uso: alta.sh "<cliente>" <plan> <usuario> <contraseña>}
PLAN=${2:?falta el plan}; USUARIO=${3:?falta el usuario}; PASS=${4:?falta la contraseña}

ID=$(docker exec -i postgres psql -U facturacion -d radius -tA -v ON_ERROR_STOP=1 \
     -v c="$CLIENTE" -v p="$PLAN" -v u="$USUARIO" -v pw="$PASS" <<'SQL'
SELECT facturacion.alta_servicio(
  (SELECT id FROM facturacion.cliente WHERE nombre = :'c'), :'p', :'u', :'pw');
SQL
)
echo "Alta: servicio $ID para $CLIENTE ($USUARIO, $PLAN)"
