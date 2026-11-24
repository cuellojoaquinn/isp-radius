-- Datos de prueba de facturación.
-- Incluye una factura VENCIDA e impaga de abonado1: la primera corrida de
-- facturacion/suspender.sh lo va a suspender (es a propósito, para la demo).

INSERT INTO facturacion.estadoservicio (nombre, radius_groupname) VALUES
  ('activo',   NULL),       -- usa el grupo de su plan
  ('moroso',   'moroso'),   -- rechaza
  ('inactivo', 'baja');     -- rechaza

INSERT INTO facturacion.tiposervicio (nombre, precio, radius_groupname)
VALUES ('Plan 50 megas', 10000, 'plan-50m');

INSERT INTO facturacion.cliente (nombre) VALUES ('Juan Pérez'), ('María Gómez');

INSERT INTO facturacion.servicio (cliente_id, tiposervicio_id, estadoservicio_id, radius_username)
SELECT c.id, t.id, e.id, x.usuario
FROM (VALUES ('Juan Pérez', 'abonado1'), ('María Gómez', 'abonado2')) AS x(cliente, usuario)
JOIN facturacion.cliente c        ON c.nombre = x.cliente
JOIN facturacion.tiposervicio t   ON t.radius_groupname = 'plan-50m'
JOIN facturacion.estadoservicio e ON e.nombre = 'activo';

-- abonado1: una pagada y una vencida ayer, impaga
INSERT INTO facturacion.factura (servicio_id, monto, fecha_creacion, fecha_vencimiento, fecha_pago)
SELECT s.id, t.precio, v.creacion, v.vencimiento, v.pago
FROM facturacion.servicio s
JOIN facturacion.tiposervicio t ON t.id = s.tiposervicio_id
CROSS JOIN (VALUES
  (CURRENT_DATE - 60, CURRENT_DATE - 31, CURRENT_DATE - 35),
  (CURRENT_DATE - 30, CURRENT_DATE - 1,  NULL::date)
) AS v(creacion, vencimiento, pago)
WHERE s.radius_username = 'abonado1';

-- abonado2: al día (vence en el futuro)
INSERT INTO facturacion.factura (servicio_id, monto, fecha_creacion, fecha_vencimiento)
SELECT s.id, t.precio, CURRENT_DATE - 5, CURRENT_DATE + 10
FROM facturacion.servicio s
JOIN facturacion.tiposervicio t ON t.id = s.tiposervicio_id
WHERE s.radius_username = 'abonado2';
