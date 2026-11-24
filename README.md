# Proyecto final ASL — RADIUS, accounting y monitoreo

ISP de laboratorio: los abonados se conectan por **PPPoE** a un **MikroTik (R1)**, que autentica contra **FreeRADIUS**; los abonados, planes y el accounting viven en **PostgreSQL**. El monitoreo sigue las prácticas de SRE de Google: **Prometheus** recolecta métricas de todos los componentes y evalúa alertas por SLO, **Alertmanager** las agrupa y **Grafana** las muestra.

- Topología y flujos: [`topologia.html`](topologia.html)
- Qué investigamos, decidimos y qué falló: [`BITACORA.md`](BITACORA.md)

## Estructura

```
├── Vagrantfile              VMs db, freeradius y grafana (VirtualBox)
├── scripts/
│   ├── base.sh              provisión común: DNS fijo + Docker
│   ├── test.sh              prueba automática del lab (corre al levantar freeradius)
│   ├── crear-chr.sh         crea R1 o R2 (MikroTik CHR) en VirtualBox
│   ├── configurar-chr.sh    aplica mikrotik/*.rsc por consola serie
│   └── chr-console.py       ejecuta comandos de RouterOS por la consola serie
├── freeradius/              compose, clients.conf, módulo sql, virtual server status, exporter
├── db/                      compose, pg_hba.conf, init/ (esquema, usuarios, datos), exporter/queries.yml
├── grafana/                 monitoreo: Prometheus (reglas y tests), Alertmanager, Grafana
│   │                        (datasources y dashboards), mktxp y r1-exporter
└── mikrotik/                exports de R1 y R2, usuario de monitoreo de R1
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
   for d in freeradius db grafana mikrotik; do cp $d/.env.example $d/.env; done
   ```

   Tienen que coincidir:

   | Valor | En |
   |---|---|
   | contraseña del usuario `radius` | `DB_RADIUS_PASSWORD` (freeradius) = `RADIUS_DB_PASSWORD` (db) |
   | contraseña del usuario `grafana` | `GRAFANA_DB_PASSWORD` (db) = `GRAFANA_DB_PASSWORD` (grafana) |
   | contraseña PPPoE de abonado1 | `R2_PPPOE_PASSWORD` (mikrotik) = `radcheck` (`db/init/03-datos.sql`) |

2. **VMs de servidores** (en este orden: la base primero):

   ```bash
   vagrant up db freeradius grafana
   ```

3. **R1 y R2 (MikroTik CHR 7.20.4).** No hay boxes de CHR prácticas para Vagrant: los crean estos scripts, que bajan la imagen oficial, arman la VM con las NICs en el orden que esperan los exports y aplican `mikrotik/*.rsc` por la consola serie (completando lo que el export oculta desde los `.env`):

   ```bash
   scripts/crear-chr.sh r1 && scripts/configurar-chr.sh r1   # NAS / servidor PPPoE
   scripts/crear-chr.sh r2 && scripts/configurar-chr.sh r2   # abonado1 (pppoe-client)
   ```

   Comandos sueltos en un router:

   ```bash
   CHR_ADMIN_PASSWORD=$(grep ^R1_ADMIN_PASSWORD mikrotik/.env | cut -d= -f2) \
     scripts/chr-console.py ~/"VirtualBox VMs/isp-radius_r1/consola.sock" -c '/ppp active print'
   ```

### Después de reiniciar la computadora

Las VMs no arrancan solas. Primero los servidores y **después** los routers: si R1 arranca antes que FreeRADIUS, R2 intenta conectarse sin servidor y el SLI de disponibilidad registra fallas (ver bitácora 23/11).

```bash
vagrant up db freeradius grafana
VBoxManage startvm isp-radius_r1 --type headless
VBoxManage startvm isp-radius_r2 --type headless
```

Si R1 se apagó con abonados conectados, la sesión queda abierta en `radacct` (sin Stop). Al arrancar, R1 manda `Accounting-On` y FreeRADIUS la cierra.

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

## Monitoreo

La red `gestion` es interna de VirtualBox: el Vagrantfile redirige las interfaces web a `localhost` del host.

| Qué | URL |
|---|---|
| Grafana (usuario `admin`, contraseña en `grafana/.env`) | http://localhost:3000 |
| Prometheus (targets, reglas, alertas) | http://localhost:9090 |
| Alertmanager (alertas activas, silencios) | http://localhost:9093 |

**Dashboards** (carpeta *ISP RADIUS*, provisionados desde `grafana/dashboards/`):

- **Servicio RADIUS (SLOs)** — síntomas: los 4 SLIs, presupuesto de error, tasa de quema, alertas activas.
- **Componentes** — causas: cuatro señales doradas de R1 (cliente RADIUS y servidor PPPoE) y FreeRADIUS, incluido el cruce *NAS vs servidor*.
- **PostgreSQL** — cuatro señales doradas de la base, estado del accounting y últimas sesiones (SQL directo).
- **Infraestructura** — CPU, memoria, disco y red de las VMs.

**Qué mide quién:**

| Exporter | VM | Fuente | Para |
|---|---|---|---|
| r1-exporter (propio) | grafana | `/radius monitor`, `/ppp active` de R1 (API 8728) | SLI 1 y 2, sesiones |
| mktxp | grafana | R1 (API 8728) | CPU, memoria, interfaces, pool, colas |
| freeradius-exporter | freeradius | Status-Server (18121, red interna) | lo que recibió y respondió el servidor |
| postgres-exporter | db | `pg_stat_*` y `db/exporter/queries.yml` | base, SLI 3 y 4 |
| node-exporter | las tres | sistema operativo | disco, memoria, CPU |

**Alertas** (`grafana/prometheus/rules/`): por síntoma con tasa de quema multiventana (`slo.yml`), saturación al 80 % (`saturacion.yml`) y monitoreo ciego (`infraestructura.yml`). Cada una tiene un `runbook` con el diagnóstico. Todavía sin canal de aviso: se ven en Alertmanager y en Grafana.

Tests de las reglas con series sintéticas:

```bash
docker run --rm --entrypoint promtool -v "$PWD/grafana/prometheus:/etc/prometheus:ro" \
  prom/prometheus:v3.5.0 test rules /etc/prometheus/tests/reglas_test.yml
```

Prometheus relee su configuración y reglas sin reiniciar: `curl -X POST localhost:9090/-/reload`.

## Notas

- Los scripts de `db/init/` corren **solo con el volumen vacío**. Para reinicializar: `docker-compose down -v` (borra los datos).
- FreeRADIUS corre en modo `-X` (debug) para el laboratorio: el log muestra paquetes y la contraseña de la base. También muestra un Status-Server cada 15 s (lo consulta el exporter).
- `db/init/04-exporter.sh` crea el usuario `exporter`. En una base que ya existía, aplicarlo a mano: `vagrant ssh db -c "docker exec -i postgres bash < /vagrant/db/init/04-exporter.sh"`.
- En `radacct` hay sesiones de prueba (`Acct-Session-Id` `prueba-N`) generadas con `radclient` el 20/11. Borrarlas hace bajar contadores del SLI 3 y Prometheus lo toma como reinicio (salto falso de 24 h).
