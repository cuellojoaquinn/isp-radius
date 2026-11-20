# R1 — acceso de solo lectura para el monitoreo (VM grafana, 10.10.10.30).
# Los exporters leen el router por la API binaria (8728): mktxp y el exporter
# de RADIUS. La contraseña del usuario la agrega scripts/configurar-chr.sh
# desde grafana/.env (R1_API_PASSWORD).
#
/user group
# "test" hace falta para /radius monitor (con solo read,api da "not enough permissions").
# No permite cambiar configuración (eso es "write").
add name=monitoreo policy=read,api,test comment="exporters de Prometheus (solo lectura)"
/user
add name=monitor group=monitoreo address=10.10.10.30/32 comment="VM grafana"
/ip service
set api address=10.10.10.30/32
