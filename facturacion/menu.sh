#!/bin/bash
# Menú interactivo del ISP (corre en la VM db).
# Antes de cada operación muestra en qué NIVEL actúa:
#   [FACTURACIÓN]  esquema facturacion (el negocio)
#   [RADIUS]       tablas de FreeRADIUS (quién entra y con qué plan)
#   [R1]           orden al router vía FreeRADIUS (CoA / Disconnect)
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PSQL_FACT=(docker exec -i postgres psql -U facturacion -d radius -v ON_ERROR_STOP=1)
PSQL_ADMIN=(docker exec -i postgres psql -U postgres -d radius -v ON_ERROR_STOP=1)

if [ -t 1 ] && tput colors >/dev/null 2>&1; then
  B=$(tput bold); N=$(tput sgr0)
  AM=$(tput setaf 3); CY=$(tput setaf 6); MG=$(tput setaf 5); RJ=$(tput setaf 1)
else
  B=""; N=""; AM=""; CY=""; MG=""; RJ=""
fi
FACT="${AM}${B}[FACTURACIÓN]${N}"
RAD="${CY}${B}[RADIUS]${N}"
NAS="${MG}${B}[R1]${N}"

nivel() {    # nivel "<niveles>" "<explicación>"
  echo
  echo "${B}Nivel:${N} $1"
  echo "  $2"
  echo
}
pausa() { echo; read -rp "Enter para volver al menú... " _; }
fallo() { echo; echo "${RJ}${B}La operación falló.${N} Mirá el mensaje de arriba."; }

menu() {
  clear
  cat <<EOF
${B}================ ISP — Gestión ================${N}
 Niveles: $FACT  $RAD  $NAS

 ${B}Consultas${N}
  1) Ver servicios (cliente, plan, estado, grupo)   $FACT $RAD
  2) Ver sesiones activas y consumo                 $RAD
  3) Ver últimos intentos de login                  $RAD
  4) Ver facturas impagas                           $FACT

 ${B}ABM${N}
  5) Alta de cliente                                $FACT
  6) Alta de servicio (conexión)                    $FACT $RAD
  7) Cambiar plan                                   $FACT $RAD $NAS
  8) Cambiar contraseña                             $RAD
  9) Baja de servicio                               $FACT $RAD $NAS

 ${B}Cobranza${N}
 10) Emitir factura                                 $FACT
 11) Registrar pago                                 $FACT
 12) Correr suspensión de morosos                   $FACT $RAD $NAS
 13) Correr rehabilitación                          $FACT $RAD

  0) Salir
${B}===============================================${N}
EOF
}

ver_servicios() {
  nivel "$FACT + $RAD (lectura)" "Cruza los servicios de facturación con su grupo en radusergroup."
  "${PSQL_FACT[@]}" <<'SQL' || fallo
SELECT c.nombre AS cliente, s.radius_username AS usuario, t.nombre AS plan,
       e.nombre AS estado, r.groupname AS grupo_radius
FROM facturacion.servicio s
JOIN facturacion.cliente c        ON c.id = s.cliente_id
JOIN facturacion.tiposervicio t   ON t.id = s.tiposervicio_id
JOIN facturacion.estadoservicio e ON e.id = s.estadoservicio_id
LEFT JOIN radusergroup r          ON r.username = s.radius_username
ORDER BY c.nombre, s.radius_username;
SQL
}

ver_sesiones() {
  nivel "$RAD (lectura de radacct)" "Sesiones abiertas: las mantiene R1 y las reporta por accounting (Start / Interim)."
  "${PSQL_FACT[@]}" <<'SQL' || fallo
SELECT username AS usuario, host(nasipaddress) AS router, host(framedipaddress) AS ip,
       to_char(acctstarttime AT TIME ZONE 'America/Argentina/Mendoza', 'DD/MM HH24:MI') AS inicio,
       acctsessiontime AS seg,
       round(acctinputoctets / 1e6, 2) AS subida_mb,
       round(acctoutputoctets / 1e6, 2) AS bajada_mb
FROM radacct
WHERE acctstoptime IS NULL
ORDER BY acctstarttime;
SQL
}

ver_intentos() {
  nivel "$RAD (lectura de radpostauth, como administrador)" "Cada Access-Accept / Access-Reject que decidió FreeRADIUS."
  "${PSQL_ADMIN[@]}" <<'SQL' || fallo
SELECT username AS usuario, reply AS respuesta,
       to_char(authdate AT TIME ZONE 'America/Argentina/Mendoza', 'DD/MM HH24:MI:SS') AS cuando
FROM radpostauth
ORDER BY id DESC
LIMIT 15;
SQL
}

ver_impagas() {
  nivel "$FACT (lectura)" "Facturas sin fecha de pago. Vencida = la toma el job de suspensión."
  "${PSQL_FACT[@]}" <<'SQL' || fallo
SELECT f.id, s.radius_username AS usuario, f.monto, f.fecha_vencimiento AS vence,
       CASE WHEN f.fecha_vencimiento < CURRENT_DATE THEN 'VENCIDA' ELSE 'al día' END AS situacion
FROM facturacion.factura f
JOIN facturacion.servicio s ON s.id = f.servicio_id
WHERE f.fecha_pago IS NULL
ORDER BY f.fecha_vencimiento;
SQL
}

alta_cliente() {
  nivel "$FACT" "Solo crea la persona. No toca RADIUS: eso pasa al dar de alta un servicio."
  read -rp "Nombre del cliente: " nombre
  [ -z "$nombre" ] && { echo "Cancelado."; return; }
  "${PSQL_FACT[@]}" -v n="$nombre" <<'SQL' || fallo
INSERT INTO facturacion.cliente (nombre) VALUES (:'n') RETURNING id, nombre;
SQL
}

alta_servicio() {
  nivel "$FACT + $RAD" "Función alta_servicio: crea el servicio y el abonado (radcheck + radusergroup) en una sola transacción."
  "${PSQL_FACT[@]}" -c "SELECT nombre AS clientes FROM facturacion.cliente ORDER BY nombre;" \
                    -c "SELECT radius_groupname AS plan, nombre, precio FROM facturacion.tiposervicio ORDER BY precio;" || { fallo; return; }
  read -rp "Cliente (nombre exacto): " cliente
  read -rp "Plan (ej. plan-50m): " plan
  read -rp "Usuario PPPoE: " usuario
  read -rsp "Contraseña (mín. 8): " pass; echo
  "$DIR/alta.sh" "$cliente" "$plan" "$usuario" "$pass" || fallo
}

cambiar_plan() {
  nivel "$FACT + $RAD + $NAS" "Cambia el plan contratado y el grupo; si está conectado, R1 aplica la velocidad en caliente (CoA)."
  "${PSQL_FACT[@]}" -c "SELECT radius_groupname AS plan, nombre, precio FROM facturacion.tiposervicio ORDER BY precio;" || { fallo; return; }
  read -rp "Usuario: " usuario
  read -rp "Plan nuevo: " plan
  "$DIR/cambiar_plan.sh" "$usuario" "$plan" || fallo
}

cambiar_password() {
  nivel "$RAD" "Actualiza radcheck vía función. Vale desde la próxima autenticación."
  read -rp "Usuario: " usuario
  read -rsp "Contraseña nueva (mín. 8): " pass; echo
  "$DIR/cambiar_password.sh" "$usuario" "$pass" || fallo
}

baja_servicio() {
  nivel "$FACT + $RAD + $NAS" "Estado inactivo + grupo baja (rechaza). Si está conectado, Disconnect a R1."
  read -rp "Usuario a dar de baja: " usuario
  read -rp "¿Confirmás la baja de '$usuario'? (s/N): " ok
  [ "$ok" = "s" ] || { echo "Cancelado."; return; }
  "$DIR/baja.sh" "$usuario" || fallo
}

emitir_factura() {
  nivel "$FACT" "Crea una factura con el precio vigente del plan (se copia al monto)."
  read -rp "Usuario: " usuario
  read -rp "Días hasta el vencimiento [10]: " dias
  dias=${dias:-10}
  "${PSQL_FACT[@]}" -v u="$usuario" -v d="$dias" <<'SQL' || fallo
INSERT INTO facturacion.factura (servicio_id, monto, fecha_vencimiento)
SELECT s.id, t.precio, CURRENT_DATE + :'d'::int
FROM facturacion.servicio s
JOIN facturacion.tiposervicio t ON t.id = s.tiposervicio_id
WHERE s.radius_username = :'u'
RETURNING id, monto, fecha_vencimiento AS vence;
SQL
}

registrar_pago() {
  nivel "$FACT" "Completa fecha_pago de las facturas impagas. NO rehabilita: eso lo hace el job (opción 13 o cron)."
  read -rp "Usuario que pagó: " usuario
  "${PSQL_FACT[@]}" -v u="$usuario" <<'SQL' || fallo
UPDATE facturacion.factura f SET fecha_pago = CURRENT_DATE
FROM facturacion.servicio s
WHERE s.id = f.servicio_id AND s.radius_username = :'u' AND f.fecha_pago IS NULL
RETURNING f.id, f.monto, f.fecha_vencimiento AS vencia;
SQL
}

correr_suspension() {
  nivel "$FACT + $RAD + $NAS" "Job: activos con factura vencida -> moroso (facturación y RADIUS) + Disconnect si están conectados."
  "$DIR/suspender.sh" || fallo
}

correr_rehabilitacion() {
  nivel "$FACT + $RAD" "Job: morosos sin facturas vencidas impagas -> activo y de vuelta al grupo de su plan."
  "$DIR/rehabilitar.sh" || fallo
}

while true; do
  menu
  read -rp "Opción: " op
  case "$op" in
    1)  ver_servicios ;;
    2)  ver_sesiones ;;
    3)  ver_intentos ;;
    4)  ver_impagas ;;
    5)  alta_cliente ;;
    6)  alta_servicio ;;
    7)  cambiar_plan ;;
    8)  cambiar_password ;;
    9)  baja_servicio ;;
    10) emitir_factura ;;
    11) registrar_pago ;;
    12) correr_suspension ;;
    13) correr_rehabilitacion ;;
    0)  exit 0 ;;
    *)  echo "Opción inválida" ;;
  esac
  pausa
done
