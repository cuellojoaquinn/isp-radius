#!/bin/bash
# Demo de seguridad: R3 (abonado2) intenta conectarse con una contraseña equivocada
# durante N minutos (por defecto 5) y después se le devuelve la correcta.
# Lo que se ve: en Abonados (abonado2) los "Login incorrect" con el motivo y la MAC; con
# más de 20 rechazos en 5 min suena PosibleFuerzaBruta (ticket, sale del log).
# Uso: scripts/demo/fuerza-bruta.sh [minutos]
set -euo pipefail
MIN=${1:-5}
cd "$(dirname "$0")/../.."
leer() { grep "^$1=" mikrotik/.env | cut -d= -f2-; }
export CHR_ADMIN_PASSWORD="$(leer R3_ADMIN_PASSWORD)"
SOCK="$HOME/VirtualBox VMs/isp-radius_r3/consola.sock"
restaurar() {
  printf '/interface pppoe-client set [find] password="%s"\n' "$(leer R3_PPPOE_PASSWORD)" \
    | scripts/chr-console.py "$SOCK" >/dev/null 2>&1
  echo "R3: contraseña correcta restaurada; abonado2 vuelve a conectarse."
}
trap restaurar EXIT
printf '/interface pppoe-client set [find] password="incorrecta-demo"\n' | scripts/chr-console.py "$SOCK" >/dev/null 2>&1
echo "R3 con contraseña equivocada durante $MIN min (Ctrl+C para cortar antes)..."
sleep $((MIN * 60))
