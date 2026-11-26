# R1 = NAS / servidor PPPoE del ISP
# Export de RouterOS 7.20.4 — /export oculta el secret del RADIUS.
# Para recrearlo: agregar secret=<RADIUS_SECRET_R1> en /radius.
#
/interface ethernet
set [ find default-name=ether3 ] name=ether2
set [ find default-name=ether2 ] name=ether3
/interface vlan
add interface=ether3 name=vlan-acceso vlan-id=100
/ip pool
add name=pool-dhcp ranges=192.168.1.100-192.168.1.200
add name=pool-ipoe ranges=100.64.1.10-100.64.1.100
add name=pool-pppoe ranges=100.64.0.10-100.64.0.100
/ip dhcp-server
add address-pool=pool-dhcp interface=ether2 name=dhcp-lan1
add address-pool=pool-ipoe interface=vlan-acceso name=dhcp-acceso
/port
set 0 name=serial0
set 1 name=serial1
/ppp profile
add local-address=100.64.0.1 name=plan-50m rate-limit=50M/50M remote-address=\
    pool-pppoe
add local-address=100.64.0.1 name=pppoe-base-radius remote-address=pool-pppoe
/interface pppoe-server server
add authentication=chap default-profile=pppoe-base-radius disabled=no \
    interface=vlan-acceso service-name=isp
/ip address
add address=192.168.1.1/24 comment="LAN1 (DHCP)" interface=ether2 network=\
    192.168.1.0
add address=100.64.1.1/24 comment="acceso IPoE" interface=vlan-acceso network=\
    100.64.1.0
add address=10.10.10.1/24 comment=gestion interface=ether1 network=10.10.10.0
/ip dhcp-server network
add address=100.64.1.0/24 dns-server=100.64.1.1 gateway=100.64.1.1
add address=192.168.1.0/24 dns-server=192.168.1.1 gateway=192.168.1.1
/ppp aaa
set interim-update=5m use-radius=yes
/radius
add address=10.10.10.10 service=ppp
# Acepta Disconnect/CoA de FreeRADIUS (órdenes de corte de facturación); faltaba en el export
/radius incoming
set accept=yes port=3799
/system identity
set name=R1
/system logging
add topics=radius,debug
