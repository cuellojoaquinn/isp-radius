# Tráfico de prueba de un abonado (R2 y R3).
# Cada minuto, 30 s de ping con paquetes de 1400 bytes (20 por segundo) a la
# dirección local de R1 en el túnel PPPoE (100.64.0.1): unos 220 kbit/s en cada
# sentido. Pasa por la cola del abonado, suma bytes en radacct (Interim cada 5 min)
# y se ve en Grafana ("Tráfico por abonado"). Liviano a propósito: es de fondo.
#
# Para ver el tope del plan (50M) durante la demo, lanzarlo a mano:
#   /tool bandwidth-test address=100.64.0.1 direction=both duration=30s user=... password=...
# Apagarlo:   /system scheduler disable trafico
#
/system scheduler
add name=trafico interval=1m on-event=\
    "/ping 100.64.0.1 size=1400 count=600 interval=50ms do-not-fragment" \
    comment="trafico de prueba del abonado (isp-radius)"
