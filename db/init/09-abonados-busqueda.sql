-- Dashboard "Abonados" (bitácora 27/11): buscar un abonado y listar los que tienen
-- problemas sin recorrer tablas enteras, aunque haya miles de abonados y años de
-- accounting.
--
-- Aplicar en una base existente (no borra nada):
--   vagrant ssh db -c "docker exec -i postgres psql -U postgres -d radius < /vagrant/db/init/09-abonados-busqueda.sql"

-- Índices para las consultas del dashboard (el esquema de FreeRADIUS no los trae)
CREATE INDEX IF NOT EXISTS radacct_usuario_inicio_idx ON radacct (username, acctstarttime DESC);  -- ficha, última sesión
CREATE INDEX IF NOT EXISTS radacct_ip_idx             ON radacct (framedipaddress);              -- buscar por IP
CREATE INDEX IF NOT EXISTS radacct_mac_idx            ON radacct (callingstationid);             -- buscar por MAC
CREATE INDEX IF NOT EXISTS radacct_fin_idx            ON radacct (acctstoptime);                 -- cortes de las últimas 24 h
CREATE INDEX IF NOT EXISTS radpostauth_fecha_idx      ON radpostauth (authdate);                 -- rechazos de la última hora

-- Grafana busca también por nombre del cliente y muestra su estado en facturación.
-- Solo lectura y solo las columnas necesarias: nada de facturas ni importes.
GRANT USAGE ON SCHEMA facturacion TO grafana;
GRANT SELECT (id, nombre) ON facturacion.cliente TO grafana;
GRANT SELECT (cliente_id, tiposervicio_id, estadoservicio_id, radius_username) ON facturacion.servicio TO grafana;
GRANT SELECT (id, nombre) ON facturacion.estadoservicio TO grafana;
GRANT SELECT (id, nombre, radius_groupname) ON facturacion.tiposervicio TO grafana;
