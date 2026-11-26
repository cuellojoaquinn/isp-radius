#!/bin/bash
# Demo de facturación: le crea al abonado una factura VENCIDA e impaga (venció ayer).
# El menú no puede (la base exige vencimiento >= emisión): se emite con fecha de hace 30 días.
# Después: suspender.sh lo suspende y le corta la sesión; pagar con el menú (opción 11) y
# rehabilitar.sh lo vuelve a activar.
# Uso: scripts/demo/deuda.sh abonado1
set -euo pipefail
U=${1:?Uso: $0 <usuario>}
cd "$(dirname "$0")/../.."
vagrant ssh db -c "docker exec -i postgres psql -U facturacion -d radius -v ON_ERROR_STOP=1 -v u=$U" <<'SQL'
INSERT INTO facturacion.factura (servicio_id, monto, fecha_creacion, fecha_vencimiento)
SELECT s.id, t.precio, CURRENT_DATE - 30, CURRENT_DATE - 1
FROM facturacion.servicio s JOIN facturacion.tiposervicio t ON t.id = s.tiposervicio_id
WHERE s.radius_username = :'u'
RETURNING id AS factura, monto, fecha_vencimiento AS vencio;
SQL
