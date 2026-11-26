#!/bin/bash
# Aplica la configuración del repo a un CHR recién creado (scripts/crear-chr.sh),
# por la consola serie. Lo que los exports ocultan se completa desde los .env.
#
#   r1  mikrotik/r1.rsc (+ secret del RADIUS) y mikrotik/r1-monitoreo.rsc
#   r2  mikrotik/r2-abonado1.rsc (+ contraseña PPPoE de abonado1) y mikrotik/abonado-trafico.rsc
#   r3  mikrotik/r3-abonado2.rsc (+ contraseña PPPoE de abonado2) y mikrotik/abonado-trafico.rsc
#
# Secretos (no se suben al repo):
#   mikrotik/.env     R1_ADMIN_PASSWORD, R2_ADMIN_PASSWORD, R3_ADMIN_PASSWORD  admin de cada router
#                     R2_PPPOE_PASSWORD   contraseña de abonado1 (= radcheck, db/init/03-datos.sql)
#                     R3_PPPOE_PASSWORD   contraseña de abonado2 (ídem)
#   freeradius/.env   RADIUS_SECRET_R1    shared secret R1 <-> FreeRADIUS
#   grafana/.env      R1_API_PASSWORD     usuario monitor de R1 (exporters)
#
# Uso: scripts/configurar-chr.sh r1|r2|r3
set -euo pipefail
cd "$(dirname "$0")/.."

ROL=${1:?Uso: $0 r1|r2|r3}
SOCK="$HOME/VirtualBox VMs/isp-radius_$ROL/consola.sock"
leer() { grep "^$2=" "$1" | cut -d= -f2-; }
requiere() { for f in "$@"; do [ -f "$f" ] || { echo "Falta $f (copiar desde .env.example)"; exit 1; }; done; }

case "$ROL" in
  r1)
    requiere mikrotik/.env freeradius/.env grafana/.env
    ADMIN=$(leer mikrotik/.env R1_ADMIN_PASSWORD)
    SECRET=$(leer freeradius/.env RADIUS_SECRET_R1)
    API_PASS=$(leer grafana/.env R1_API_PASSWORD)
    generar() {
      # El export intercambia los nombres de ether2/ether3; en un CHR nuevo el
      # primer rename choca con el nombre existente (ver bitácora 19/11, incidente).
      echo '/interface ethernet set [find default-name=ether2] name=tmp-ether2'
      # El export oculta el secret: se agrega a la línea del /radius.
      # El CHR de VirtualBox tiene un solo puerto serie: se saltea "set 1 name=serial1".
      sed -e "s|^add address=10.10.10.10 service=ppp\$|add address=10.10.10.10 service=ppp secret=\"$SECRET\" timeout=3s|" \
          -e "/^set 1 name=serial1\$/d" mikrotik/r1.rsc
      sed "s|^add name=monitor group=monitoreo|add name=monitor password=\"$API_PASS\" group=monitoreo|" mikrotik/r1-monitoreo.rsc
    }
    ;;
  r2)
    requiere mikrotik/.env
    ADMIN=$(leer mikrotik/.env R2_ADMIN_PASSWORD)
    PPPOE=$(leer mikrotik/.env R2_PPPOE_PASSWORD)
    generar() {
      # El export oculta la contraseña del pppoe-client (la línea viene partida con "\").
      sed -e "s|^    user=abonado1\$|    user=abonado1 password=\"$PPPOE\"|" \
          -e "/^set 1 name=serial1\$/d" mikrotik/r2-abonado1.rsc
      cat mikrotik/abonado-trafico.rsc
    }
    ;;
  r3)
    requiere mikrotik/.env
    ADMIN=$(leer mikrotik/.env R3_ADMIN_PASSWORD)
    PPPOE=$(leer mikrotik/.env R3_PPPOE_PASSWORD)
    generar() {
      sed -e "s|^    user=abonado2\$|    user=abonado2 password=\"$PPPOE\"|" \
          -e "/^set 1 name=serial1\$/d" mikrotik/r3-abonado2.rsc
      cat mikrotik/abonado-trafico.rsc
    }
    ;;
  *) echo "Rol desconocido: $ROL (r1, r2 o r3)"; exit 2 ;;
esac

export CHR_ADMIN_PASSWORD="$ADMIN"    # chr-console.py lo usa para el login
{
  # Contraseña de admin: se fija siempre (el primer login la pide, pero así queda explícito)
  echo "/user set admin password=\"$ADMIN\""
  # Un CHR nuevo trae un dhcp-client en ether1 de fábrica. El export solo describe
  # lo que hay que agregar: sin esto, R1 quedaría pidiendo DHCP en gestion (no está
  # en su export) y en R2 el "add" del export choca con el existente.
  echo '/ip dhcp-client remove [find]'
  generar
} | python3 scripts/chr-console.py "$SOCK"
