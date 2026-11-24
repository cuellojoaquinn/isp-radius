#!/bin/bash
# Usuario del sistema de facturación: maneja su esquema y, en RADIUS,
# solo puede cambiar el grupo de un abonado y ver si tiene sesión abierta.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<EOSQL
CREATE ROLE facturacion LOGIN PASSWORD '${FACTURACION_DB_PASSWORD}';

-- Su esquema: leer, crear y modificar, sin borrar
GRANT USAGE ON SCHEMA facturacion TO facturacion;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA facturacion TO facturacion;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA facturacion TO facturacion;

-- RADIUS: solo cambiar el grupo (permiso por columna)...
GRANT SELECT ON radusergroup TO facturacion;
GRANT UPDATE (groupname) ON radusergroup TO facturacion;

-- ...y ver si hay sesión abierta y en qué NAS
GRANT SELECT ON radacct TO facturacion;
EOSQL
