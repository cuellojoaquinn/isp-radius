#!/bin/bash
# Job de rehabilitación (corre en la VM db): servicios morosos SIN ninguna
# factura vencida impaga -> activo y de vuelta al grupo de su plan.
# No hace falta Disconnect: el próximo intento del router del abonado ya entra.
set -euo pipefail
log() { echo "$(date '+%F %T') $*"; }

log "Inicio"

RESULT=$(docker exec -i postgres psql -U facturacion -d radius -tA -F ' ' -v ON_ERROR_STOP=1 <<'SQL'
WITH activo AS (
  SELECT id, radius_groupname FROM facturacion.estadoservicio WHERE nombre = 'activo'
),
al_dia AS (
  SELECT s.id, s.radius_username, t.radius_groupname AS grupo_plan
  FROM facturacion.servicio s
  JOIN facturacion.estadoservicio e ON e.id = s.estadoservicio_id
  JOIN facturacion.tiposervicio t   ON t.id = s.tiposervicio_id
  WHERE e.nombre = 'moroso'
    AND NOT EXISTS (
      SELECT 1 FROM facturacion.factura f
      WHERE f.servicio_id = s.id
        AND f.fecha_vencimiento < CURRENT_DATE
        AND f.fecha_pago IS NULL
    )
),
upd_servicio AS (
  UPDATE facturacion.servicio s SET estadoservicio_id = a.id
  FROM al_dia d, activo a
  WHERE s.id = d.id
  RETURNING s.radius_username, COALESCE(a.radius_groupname, d.grupo_plan) AS grupo
),
upd_radius AS (
  UPDATE radusergroup r SET groupname = u.grupo
  FROM upd_servicio u
  WHERE r.username = u.radius_username
  RETURNING r.username, r.groupname
)
SELECT username, groupname FROM upd_radius;
SQL
)

if [ -z "$RESULT" ]; then
  log "Sin servicios para rehabilitar"
  exit 0
fi

while read -r usuario grupo; do
  log "Rehabilitado: $usuario -> $grupo"
done <<< "$RESULT"

log "Fin"
