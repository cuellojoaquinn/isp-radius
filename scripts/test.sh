#!/bin/bash
# Prueba automática del laboratorio. Corre en la VM freeradius.
#   - FreeRADIUS responde y decide bien (Accept / Reject, PAP / CHAP, plan)
#   - La base acepta a FreeRADIUS y aplica los permisos mínimos y pg_hba
# Uso manual: vagrant provision freeradius --provision-with test
set -u

ENV_FILE=/vagrant/freeradius/.env
[ -f "$ENV_FILE" ] || { echo "Falta $ENV_FILE"; exit 1; }
set -a; . "$ENV_FILE"; set +a

PASS=0; FAIL=0
ok()   { echo "  [OK]    $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FALLA] $1"; FAIL=$((FAIL+1)); }

# Espera a que FreeRADIUS esté listo (hasta 60 s)
echo "Esperando a FreeRADIUS..."
for i in $(seq 1 30); do
  docker logs freeradius 2>&1 | grep -q "Ready to process requests" && break
  sleep 2
done

radius() {  # radius <metodo> <usuario> <contraseña>
  radtest -t "$1" "$2" "$3" 127.0.0.1 0 "$RADIUS_SECRET_LOCAL" 2>&1
}

expect_radius() {  # expect_radius <descripcion> <metodo> <usuario> <contraseña> <Accept|Reject> [texto extra esperado]
  local out; out=$(radius "$2" "$3" "$4")
  if echo "$out" | grep -q "Received Access-$5" && { [ -z "${6:-}" ] || echo "$out" | grep -q "$6"; }; then
    ok "$1"
  else
    bad "$1"; echo "$out" | sed 's/^/          /' | tail -5
  fi
}

echo
echo "== FreeRADIUS =="
expect_radius "abonado1 con CHAP -> Accept con plan 50M"   chap abonado1 secreto1 Accept 'Mikrotik-Rate-Limit = "50M/50M"'
expect_radius "abonado1 con PAP -> Accept"                 pap  abonado1 secreto1 Accept
expect_radius "abonado2 con CHAP -> Accept"                chap abonado2 secreto2 Accept
expect_radius "contraseña incorrecta -> Reject"            chap abonado1 incorrecta Reject
expect_radius "usuario inexistente -> Reject"              chap abonado99 cualquiera Reject

echo
echo "== PostgreSQL =="
PGHOST=${DB_HOST:-10.10.10.20}

if PGPASSWORD="$DB_RADIUS_PASSWORD" psql -h "$PGHOST" -U radius -d radius -tAc "SELECT count(*) FROM radcheck;" >/dev/null 2>&1; then
  ok "usuario radius se conecta desde freeradius"
else
  bad "usuario radius se conecta desde freeradius"
fi

out=$(PGPASSWORD="$DB_RADIUS_PASSWORD" psql -h "$PGHOST" -U radius -d radius -tAc "DELETE FROM radacct WHERE false;" 2>&1)
echo "$out" | grep -qi "permission denied" && ok "usuario radius NO puede borrar accounting (sin DELETE)" \
                                          || bad "usuario radius NO puede borrar accounting (sin DELETE)"

out=$(PGPASSWORD=x psql -h "$PGHOST" -U grafana -d radius -tAc "SELECT 1;" 2>&1)
echo "$out" | grep -q "no pg_hba.conf entry" && ok "usuario grafana rechazado desde la IP de freeradius (pg_hba)" \
                                             || bad "usuario grafana rechazado desde la IP de freeradius (pg_hba)"

n=$(PGPASSWORD="$DB_RADIUS_PASSWORD" psql -h "$PGHOST" -U radius -d radius -tAc \
    "SELECT count(*) FROM radpostauth WHERE authdate > now() - interval '5 minutes';" 2>/dev/null)
[ "${n:-0}" -gt 0 ] 2>/dev/null && ok "los intentos quedaron registrados en radpostauth ($n en los últimos 5 min)" \
                                || bad "los intentos quedaron registrados en radpostauth"

echo
echo "Resultado: $PASS OK, $FAIL con falla"
[ "$FAIL" -eq 0 ]
