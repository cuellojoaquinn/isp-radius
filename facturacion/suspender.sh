#!/bin/bash
# Job de suspensión por falta de pago (corre en la VM db).
# 1) En UNA sentencia: servicios activos con factura vencida e impaga -> moroso
#    en facturación y en RADIUS (no pueden quedar desincronizados).
# 2) Disconnect firmado vía FreeRADIUS solo a los que tienen sesión abierta.
set -euo pipefail
source "$(dirname "$0")/.env"          # RADIUS_SECRET_FACTURACION
RADIUS=${RADIUS_COA:-10.10.10.10:3799}
log() { echo "$(date '+%F %T') $*"; }

log "Inicio"

RESULT=$(docker exec -i postgres psql -U facturacion -d radius -tA -F ' ' -v ON_ERROR_STOP=1 <<'SQL'
WITH moroso AS (
  SELECT id, radius_groupname FROM facturacion.estadoservicio WHERE nombre = 'moroso'
),
vencidos AS (
  SELECT DISTINCT s.id, s.radius_username, t.radius_groupname AS grupo_plan
  FROM facturacion.factura f
  JOIN facturacion.servicio s       ON s.id = f.servicio_id
  JOIN facturacion.estadoservicio e ON e.id = s.estadoservicio_id
  JOIN facturacion.tiposervicio t   ON t.id = s.tiposervicio_id
  WHERE f.fecha_vencimiento < CURRENT_DATE
    AND f.fecha_pago IS NULL
    AND e.nombre = 'activo'
),
upd_servicio AS (
  UPDATE facturacion.servicio s SET estadoservicio_id = m.id
  FROM vencidos v, moroso m
  WHERE s.id = v.id
  RETURNING s.radius_username, COALESCE(m.radius_groupname, v.grupo_plan) AS grupo
),
upd_radius AS (
  UPDATE radusergroup r SET groupname = u.grupo
  FROM upd_servicio u
  WHERE r.username = u.radius_username
  RETURNING r.username
)
SELECT u.username, COALESCE(host(a.nasipaddress), '-')
FROM upd_radius u
LEFT JOIN radacct a ON a.username = u.username AND a.acctstoptime IS NULL;
SQL
)

if [ -z "$RESULT" ]; then
  log "Sin servicios para suspender"
  exit 0
fi

while read -r usuario nas; do
  log "Suspendido: $usuario"
  if [ "$nas" = "-" ]; then
    log "  sin sesión abierta: no hace falta Disconnect"
    continue
  fi
  # Message-Authenticator: FreeRADIUS lo exige (protección BlastRADIUS)
  salida=$(printf 'User-Name = %s\nMessage-Authenticator = 0x00\n' "$usuario" \
           | radclient -x "$RADIUS" disconnect "$RADIUS_SECRET_FACTURACION" 2>&1 || true)
  if echo "$salida" | grep -q "Disconnect-ACK"; then
    log "  sesión en $nas cortada (Disconnect-ACK)"
  else
    log "  ATENCIÓN: no se pudo cortar la sesión en $nas"
  fi
done <<< "$RESULT"

log "Fin"
