#!/bin/bash
# Usuario de postgres_exporter (lo lee Prometheus, VM grafana).
#   pg_monitor: estadísticas del servidor (pg_stat_*), sin acceso a datos.
#   SELECT en radacct y radpostauth: para las consultas propias de los SLI 3 y 4
#   (queries.yml). Sin acceso a radcheck (contraseñas en claro).
#
# Corre solo con el volumen vacío. En una base ya creada, aplicarlo a mano:
#   vagrant ssh db -c "docker exec -i postgres bash < /vagrant/db/init/04-exporter.sh"
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname "${POSTGRES_DB:-radius}" <<EOSQL
CREATE ROLE exporter LOGIN PASSWORD '${EXPORTER_DB_PASSWORD}';
GRANT pg_monitor TO exporter;
GRANT SELECT ON radacct, radpostauth TO exporter;
EOSQL
