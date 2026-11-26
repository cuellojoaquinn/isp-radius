-- radpostauth sin contraseñas (auditoría de dashboards, bitácora 26/11).
--
-- La consulta post-auth de FreeRADIUS guarda en radpostauth.pass la contraseña
-- de cada intento de login: en claro con PAP, el desafío CHAP en hexa. Nadie la
-- usa (ni el menú de facturación, ni el exportador, ni los dashboards) y los
-- usuarios grafana y exporter la podían leer.
--
-- 1) Un trigger la descarta antes de guardarla: no hace falta tocar la consulta
--    de FreeRADIUS (vive en la imagen) y vale para cualquiera que inserte.
-- 2) Se borran las que ya estaban.
-- 3) grafana y exporter leen solo las otras columnas (permiso por columna).
--
-- Aplicar en una base existente (sin borrar nada):
--   vagrant ssh db -c "docker exec -i postgres psql -U postgres -d radius < /vagrant/db/init/08-radpostauth-sin-password.sql"

CREATE OR REPLACE FUNCTION radpostauth_sin_password() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.pass := NULL;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS radpostauth_sin_password ON radpostauth;
CREATE TRIGGER radpostauth_sin_password
  BEFORE INSERT OR UPDATE ON radpostauth
  FOR EACH ROW EXECUTE FUNCTION radpostauth_sin_password();

UPDATE radpostauth SET pass = NULL WHERE pass IS NOT NULL;

REVOKE SELECT ON radpostauth FROM grafana, exporter;
GRANT SELECT (id, username, reply, calledstationid, callingstationid, authdate, class)
  ON radpostauth TO grafana, exporter;
