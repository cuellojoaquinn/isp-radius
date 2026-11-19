# Proyecto final ASL — RADIUS, accounting y monitoreo

ISP de laboratorio: los abonados se conectan por **PPPoE** a un **MikroTik (R1)**, que autentica contra **FreeRADIUS**; los abonados, planes y el accounting viven en **PostgreSQL**, y **Grafana** muestra el estado del router y de los abonados.

- Topología y flujos: [`topologia.html`](topologia.html)
- Qué investigamos, decidimos y qué falló: [`BITACORA.md`](BITACORA.md)

## Estructura

```
├── Vagrantfile            VMs db, freeradius y grafana (VirtualBox)
├── scripts/base.sh        provisión común: DNS fijo + Docker
├── freeradius/            compose, clients.conf, módulo sql, .env.example
├── db/                    compose, pg_hba.conf, init/ (esquema, usuarios, datos), .env.example
├── grafana/               compose de Grafana (pendiente)
└── mikrotik/              export de R1
```

## Redes

| Red | Rango | Qué hay |
|---|---|---|
| gestion | `10.10.10.0/24` | R1 `.1`, freeradius `.10`, db `.20`, grafana `.30` |
| acceso | `100.64.1.0/24` (vlan-acceso) | abonados PPPoE; pool `100.64.0.10–100` |
| lan1 | `192.168.1.0/24` | LAN de R1 con DHCP |

## Levantar el laboratorio (Linux + VirtualBox)

Requisitos: VirtualBox y Vagrant.

1. **Secretos.** Copiar y completar (los `.env` no se suben al repo):

   ```bash
   cp freeradius/.env.example freeradius/.env
   cp db/.env.example db/.env
   ```

   `DB_RADIUS_PASSWORD` (freeradius) y `RADIUS_DB_PASSWORD` (db) tienen que ser iguales.

2. **VMs de servidores** (en este orden: la base primero):

   ```bash
   vagrant up db freeradius grafana
   ```

3. **R1 (MikroTik CHR)**: importar el CHR en VirtualBox y poner el adaptador de `ether1` en *Red interna* `gestion`. Aplicar la config de [`mikrotik/README.md`](mikrotik/README.md) usando el mismo `RADIUS_SECRET_R1`.

4. **Abonados**: MikroTik con `pppoe-client` en la red de acceso.

> Joaquín corre el lab en Mac (Apple Silicon) con UTM: sus VMs están armadas a mano con la misma configuración; el Vagrantfile apunta a VirtualBox.

## Verificar

Al terminar `vagrant up`, la VM freeradius corre sola [`scripts/test.sh`](scripts/test.sh) y muestra un resumen `[OK]` / `[FALLA]`: Accept y Reject (PAP y CHAP), el plan devuelto desde la base, la conexión de FreeRADIUS a PostgreSQL, que el usuario `radius` no pueda borrar accounting, que `grafana` sea rechazado desde una IP no autorizada y que los intentos queden en `radpostauth`. Para repetirla:

```bash
vagrant provision freeradius --provision-with test
```

Pruebas puntuales a mano:

```bash
# En freeradius: autenticación contra la base (CHAP)
vagrant ssh freeradius -c "radtest -t chap abonado1 secreto1 127.0.0.1 0 \$(grep RADIUS_SECRET_LOCAL /vagrant/freeradius/.env | cut -d= -f2)"

# En db: accounting legible
vagrant ssh db -c "bash /vagrant/db/acct.sh"
```

En R1: `/ppp active print` (marca `R`), `/queue simple print` (cola `50M/50M`), `/radius monitor 0 once`.

## Notas

- Los scripts de `db/init/` corren **solo con el volumen vacío**. Para reinicializar: `docker-compose down -v` (borra los datos).
- FreeRADIUS corre en modo `-X` (debug) para el laboratorio: el log muestra paquetes y la contraseña de la base.
