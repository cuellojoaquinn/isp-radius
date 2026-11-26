# R3 = abonado2 (MikroTik CHR como cliente PPPoE)
# Misma configuración que R2 (r2-abonado1.rsc) con el usuario abonado2.
# Como en un export, no lleva la contraseña del pppoe-client:
# scripts/configurar-chr.sh r3 la completa desde mikrotik/.env (R3_PPPOE_PASSWORD).
#
/interface ethernet
set [ find default-name=ether2 ] name=ether3
/interface vlan
add interface=ether3 name=vlan-acceso vlan-id=100
/interface pppoe-client
add add-default-route=yes disabled=no interface=vlan-acceso name=wan-pppoe \
    user=abonado2
/port
set 0 name=serial0
set 1 name=serial1
/ip dhcp-client
add interface=ether1
/system identity
set name=R3
