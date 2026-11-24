-- Datos de prueba del laboratorio: planes y abonados.

-- Plan: la velocidad se define por grupo (radgroupreply), no por usuario.
INSERT INTO radgroupreply (groupname, attribute, op, value)
VALUES ('plan-50m', 'Mikrotik-Rate-Limit', ':=', '50M/50M');

-- abonado1 (contraseña en claro: CHAP/MS-CHAP la necesitan así)
INSERT INTO radcheck (username, attribute, op, value)
VALUES ('abonado1', 'Cleartext-Password', ':=', 'secreto1');
INSERT INTO radusergroup (username, groupname, priority)
VALUES ('abonado1', 'plan-50m', 1);

-- abonado2
INSERT INTO radcheck (username, attribute, op, value)
VALUES ('abonado2', 'Cleartext-Password', ':=', 'secreto2');
INSERT INTO radusergroup (username, groupname, priority)
VALUES ('abonado2', 'plan-50m', 1);

-- Grupos que rechazan el acceso (suspensión y baja). Condición por grupo en radgroupcheck.
INSERT INTO radgroupcheck (groupname, attribute, op, value) VALUES
  ('moroso', 'Auth-Type', ':=', 'Reject'),
  ('baja',   'Auth-Type', ':=', 'Reject');
