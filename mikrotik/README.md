# MikroTik

| Archivo | Equipo |
|---|---|
| `r1.rsc` | R1: NAS / servidor PPPoE `isp` sobre `vlan-acceso`, solo CHAP, RADIUS en `10.10.10.10` |
| `r1-monitoreo.rsc` | R1: usuario `monitor` (grupo `monitoreo`: `read,api,test`) solo desde `10.10.10.30`, y API limitada a esa IP |
| `r2-abonado1.rsc` | R2: abonado1, cliente PPPoE `wan-pppoe` sobre `vlan-acceso` (VLAN 100) |

En VirtualBox, `scripts/crear-chr.sh r1|r2` crea el router y `scripts/configurar-chr.sh r1|r2` aplica estos archivos por consola serie (ver README principal). El script completa lo que el export oculta (secret del RADIUS, contraseñas) y resuelve tres diferencias entre un CHR nuevo y un export:

- **Renames ether2 ↔ ether3:** el export los intercambia con dos `set ... name=`; en un CHR nuevo el primero choca con el nombre existente. Se renombra antes a un nombre temporal.
- **dhcp-client de fábrica en ether1:** el export no lo menciona (solo describe lo agregado), así que en R1 quedaría pidiendo DHCP en gestión y en R2 el `add` choca. Se borra antes.
- **`/port set 1`:** el CHR de VirtualBox tiene un solo puerto serie. Se saltea.

**Por qué `test` en el usuario de monitoreo:** `/radius monitor` responde `not enough permissions` con solo `read,api`. `test` habilita comandos de diagnóstico (ping, monitor) pero no cambiar configuración (eso es `write`).

Guardar acá el export de R1:

```
/export file=r1
```

y bajar `r1.rsc` desde *Files*. En RouterOS 7, `/export` oculta los datos sensibles por defecto (secret del RADIUS, contraseñas de `/ppp secret`), así que se puede subir tal cual. **No usar `show-sensitive`** para el archivo del repo.

Configuración clave de R1 para RADIUS:

```
/ip address add address=10.10.10.1/24 interface=ether1 comment="gestion"
/radius add address=10.10.10.10 secret=<RADIUS_SECRET_R1> service=ppp \
    authentication-port=1812 accounting-port=1813 timeout=3s
/ppp profile add name=pppoe-base-radius local-address=100.64.0.1 remote-address=pool-pppoe
/interface pppoe-server server set [find service-name=isp] default-profile=pppoe-base-radius
/ppp aaa set use-radius=yes accounting=yes interim-update=5m
/radius incoming set accept=yes port=3799   # acepta Disconnect/CoA de FreeRADIUS
/system logging add topics=radius,debug action=memory
```
