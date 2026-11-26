#!/bin/bash
# Abonados de demo que se conectan y generan tráfico en tiempo real (DEMO.md, demo en vivo).
#
# Cada router abonado (R2 y R3) lleva varias conexiones PPPoE, una por abonado: para R1 y
# FreeRADIUS es igual que si fueran equipos distintos (login, sesión, IP, cola y accounting
# propios). R1 acepta varias sesiones desde el mismo equipo (one-session-per-host=no).
#
#   alta [N]        da de alta abonado3..abonado(2+N) POR FACTURACIÓN (facturacion.alta_servicio,
#                   la misma función que usa el menú): cliente, plan y usuario en RADIUS. N=10.
#   conectar [N]    configura su conexión PPPoE en R2 (pares) y R3 (impares)
#   trafico on|off [N]  prende o apaga el tráfico de los abonados de demo
#   estado          quién está conectado en R1, con qué IP y hace cuánto
#   desconectar     saca las conexiones y el tráfico de demo de R2 y R3
#   borrar          desconectar + borra los abonados de demo de la base (no toca radacct)
#
# Perfiles de tráfico. La licencia gratuita del CHR limita CADA INTERFAZ a 1 Mbit/s en
# total, y todos los abonados de un router comparten una (vlan-acceso; en R1, la que va a
# los abonados también es una sola). Pasarse satura el enlace: se pierden los keepalive de
# PPPoE y las sesiones se caen ("peer is not responding"). Presupuesto: ~500 kbit/s en total.
#   liviano     mensajería: un paquete de 300 B por segundo (~2 kbit/s)
#   navegacion  ráfagas: 3 s a ~200 kbit/s por minuto, desfasadas entre abonados
#   streaming   constante: ~100 kbit/s
# Mientras corre, se pausa el tráfico de fondo de abonado1 y abonado2 (scheduler "trafico").
# El tráfico es ping hacia R1 (100.64.0.1) por la conexión de cada abonado: R2 y R3 no
# tienen salida a internet. Se ve en R1, en la interfaz <pppoe-abonadoN>.
#
# Contraseñas: al azar, de prueba, en mikrotik/demo-abonados.env (no se sube al repo).
set -euo pipefail
cd "$(dirname "$0")/../.."
CLAVES=mikrotik/demo-abonados.env
leer() { grep "^$1=" "$2" | cut -d= -f2-; }

N=${2:-10}
[[ "${1:-}" == trafico ]] && N=${3:-10}
usuarios() { for i in $(seq 3 $((2 + N))); do echo "abonado$i"; done; }
num() { echo "${1#abonado}"; }
router_de() { if (( $(num "$1") % 2 == 0 )); then echo r2; else echo r3; fi; }
plan_de() { if (( $(num "$1") % 4 == 0 )); then echo plan-10m; else echo plan-50m; fi; }
perfil_de() { case $(( $(num "$1") % 3 )) in 0) echo liviano ;; 1) echo navegacion ;; 2) echo streaming ;; esac; }

consola() {   # consola r2|r3|r1 < comandos
  local rol=$1
  CHR_ADMIN_PASSWORD="$(leer "${rol^^}_ADMIN_PASSWORD" mikrotik/.env)" \
    scripts/chr-console.py "$HOME/VirtualBox VMs/isp-radius_$rol/consola.sock"
}

clave_de() {
  touch "$CLAVES"; chmod 600 "$CLAVES"
  local c; c=$(leer "$1" "$CLAVES" || true)
  if [ -z "$c" ]; then c=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 12); echo "$1=$c" >> "$CLAVES"; fi
  echo "$c"
}

ping_de() {   # comando de ping según el perfil (ver el presupuesto de tráfico arriba)
  local u=$1 n; n=$(num "$1")
  case $(perfil_de "$u") in
    liviano)    echo "/ping 100.64.0.1 interface=pppoe-$u size=300 count=55 interval=1s" ;;
    navegacion) echo ":delay $(( (n * 7) % 50 ))s; /ping 100.64.0.1 interface=pppoe-$u size=1000 count=75 interval=40ms" ;;
    streaming)  echo "/ping 100.64.0.1 interface=pppoe-$u size=1000 count=700 interval=80ms" ;;
  esac
}

alta() {
  local sql=""
  for u in $(usuarios); do
    local n; n=$(num "$u")
    sql+="INSERT INTO facturacion.cliente (nombre) SELECT 'Cliente demo $n'
            WHERE NOT EXISTS (SELECT 1 FROM facturacion.cliente WHERE nombre = 'Cliente demo $n');
          SELECT '$u' AS abonado, '$(plan_de "$u")' AS plan,
                 facturacion.alta_servicio(c.id, '$(plan_de "$u")', '$u', '$(clave_de "$u")') AS servicio
            FROM facturacion.cliente c
           WHERE c.nombre = 'Cliente demo $n'
             AND NOT EXISTS (SELECT 1 FROM facturacion.servicio WHERE radius_username = '$u');
"
  done
  echo "$sql" | vagrant ssh db -c "docker exec -i postgres psql -U facturacion -d radius -v ON_ERROR_STOP=1 -tA -q" \
    | grep -v '^$' | sed 's/|/ /g; s/^/  alta: /' || true
  echo "Abonados de demo en facturación y RADIUS: $(usuarios | head -1)..$(usuarios | tail -1)"
}

conectar() {
  for r in r2 r3; do
    local cmds=""
    for u in $(usuarios); do
      [ "$(router_de "$u")" = "$r" ] || continue
      cmds+="/interface pppoe-client remove [find name=pppoe-$u]
/interface pppoe-client add name=pppoe-$u interface=vlan-acceso user=$u password=$(clave_de "$u") add-default-route=no use-peer-dns=no disabled=no comment=\"demo isp-radius\"
"
    done
    [ -n "$cmds" ] && printf '%s' "$cmds" | consola "$r" >/dev/null 2>&1 && echo "$r: conexiones PPPoE configuradas"
  done
}

trafico() {
  local accion=${1:?trafico on|off}
  for r in r2 r3; do
    local cmds="/system scheduler remove [find name~\"^trafico-abonado\"]
"
    if [ "$accion" = on ]; then
      cmds+="/system scheduler disable [find name=trafico]
"
      for u in $(usuarios); do
        [ "$(router_de "$u")" = "$r" ] || continue
        cmds+="/system scheduler add name=trafico-$u interval=1m start-time=startup on-event=\"$(ping_de "$u")\" comment=\"demo isp-radius ($(perfil_de "$u"))\"
"
      done
    fi
    [ "$accion" = off ] && cmds+="/system scheduler enable [find name=trafico]
"
    printf '%s' "$cmds" | consola "$r" >/dev/null 2>&1
    echo "$r: tráfico de demo $accion"
  done
}

estado() {
  printf '/ppp active print terse\n' | consola r1 2>/dev/null | grep -o 'name=[^ ]* .*address=[^ ]* uptime=[^ ]*' \
    | sed -E 's/ service=[^ ]*//; s/ caller-id=[^ ]*//; s/ encoding=[^ ]*//; s/ session-id=[^ ]*//; s/ limit-bytes-[a-z]*=[^ ]*//g' | sort -V
}

desconectar() {
  for r in r2 r3; do
    printf '/system scheduler remove [find name~"^trafico-abonado"]\n/system scheduler enable [find name=trafico]\n/interface pppoe-client remove [find comment="demo isp-radius"]\n' \
      | consola "$r" >/dev/null 2>&1
    echo "$r: sin abonados de demo"
  done
}

borrar() {
  desconectar
  # todos los que creó el script (están en el archivo de claves), no solo los N por defecto
  local lista; lista=$( { usuarios; [ -f "$CLAVES" ] && cut -d= -f1 "$CLAVES"; } | sort -u | sed "s/.*/'&'/" | paste -sd,)
  vagrant ssh db -c "docker exec -i postgres psql -U postgres -d radius -v ON_ERROR_STOP=1 -q" <<SQL
DELETE FROM facturacion.factura WHERE servicio_id IN (SELECT id FROM facturacion.servicio WHERE radius_username IN ($lista));
DELETE FROM facturacion.servicio WHERE radius_username IN ($lista);
DELETE FROM facturacion.cliente WHERE nombre LIKE 'Cliente demo %';
DELETE FROM radusergroup WHERE username IN ($lista);
DELETE FROM radcheck WHERE username IN ($lista);
SQL
  rm -f "$CLAVES"
  echo "Abonados de demo borrados de la base (sus sesiones quedan en radacct como historia)."
}

case "${1:-}" in
  alta) alta ;;
  conectar) conectar ;;
  trafico) trafico "${2:-}" ;;
  estado) estado ;;
  desconectar) desconectar ;;
  borrar) borrar ;;
  *) sed -n '2,25p' "$0"; exit 2 ;;
esac
