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

# Logs de R1 hacia Loki: syslog RFC 3164 por UDP al Alloy de la VM grafana
# (grafana/alloy/syslog-r1.alloy). El formato syslog de RouterOS no lleva los
# tópicos: cada regla pone un prefijo (ppp, radius) que Alloy usa como etiqueta.
# Sin debug. Las reglas no se solapan (si no, R1 mandaría la línea dos veces).
/system logging action
add name=loki target=remote remote=10.10.10.30 remote-port=1514 remote-log-format=syslog syslog-time-format=bsd-syslog syslog-facility=local0
/system logging
add topics=ppp,!debug prefix=ppp action=loki
add topics=pppoe,!ppp,!debug prefix=ppp action=loki
add topics=radius,!debug prefix=radius action=loki
add topics=info,!ppp,!pppoe,!radius,!debug action=loki
add topics=warning,!ppp,!pppoe,!radius,!debug action=loki
add topics=error,!ppp,!pppoe,!radius,!debug action=loki
add topics=critical,!ppp,!pppoe,!radius,!debug action=loki
