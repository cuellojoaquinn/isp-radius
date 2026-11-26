# Proyecto final ASL — RADIUS, accounting y monitoreo

ISP de laboratorio: los abonados se conectan por **PPPoE** a un **MikroTik (R1)**, que autentica contra **FreeRADIUS**; los abonados, planes y el accounting viven en **PostgreSQL**. El monitoreo sigue las prácticas de SRE de Google: **Prometheus** recolecta métricas de todos los componentes y evalúa alertas por SLO, **Alertmanager** las agrupa y **Grafana** las muestra.

- Topología y flujos: [`topologia.html`](topologia.html)
- Qué investigamos, decidimos y qué falló: [`BITACORA.md`](BITACORA.md)
- Cómo mostrar cada parte en la demo: [`DEMO.md`](DEMO.md)
- Escalabilidad y plan de pruebas de carga: [`docs/escalabilidad.md`](docs/escalabilidad.md)

## Estructura

```
├── Vagrantfile              VMs db, freeradius y grafana (VirtualBox)
├── scripts/
│   ├── base.sh              provisión común: DNS fijo, Docker y logs al journal
│   ├── test.sh              prueba automática del lab (corre al levantar freeradius)
│   ├── crear-chr.sh         crea R1, R2 o R3 (MikroTik CHR) en VirtualBox
│   ├── configurar-chr.sh    aplica mikrotik/*.rsc por consola serie
│   ├── chr-console.py       ejecuta comandos de RouterOS por la consola serie
│   ├── configurar-avisos.sh pide el token de Telegram y la clave del agente (sin mostrarlos)
│   └── demo/                deuda vencida y fuerza bruta, para la demo (DEMO.md)
├── freeradius/              compose, clients.conf, módulo sql, virtual server status, exporter
├── db/                      compose, pg_hba.conf, init/ (esquema, usuarios, datos), exporter/queries.yml
├── grafana/                 monitoreo: Prometheus (reglas y tests), Alertmanager, Grafana
│   │                        (datasources y dashboards), mktxp, r1-exporter, Loki (logs y
│   │                        sus reglas) y el syslog de R1
├── alloy/                   recolector de logs (Alloy), config compartida por las tres VMs
├── diagnostico/             agente de diagnóstico con IA (API de Claude), corre en la VM grafana
├── facturacion/             scripts de alta, baja, planes, suspensión y rehabilitación (cron)
└── mikrotik/                exports de R1, R2 (abonado1) y R3 (abonado2), tráfico de prueba, monitoreo de R1
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
   | contraseña PPPoE de abonado2 | `R3_PPPOE_PASSWORD` (mikrotik) = `radcheck` (`db/init/03-datos.sql`) |

2. **VMs de servidores** (en este orden: la base primero):

   ```bash
   vagrant up db freeradius grafana
   ```

3. **R1, R2 y R3 (MikroTik CHR 7.20.4).** No hay boxes de CHR prácticas para Vagrant: los crean estos scripts, que bajan la imagen oficial, arman la VM con las NICs en el orden que esperan los exports y aplican `mikrotik/*.rsc` por la consola serie (completando lo que el export oculta desde los `.env`):

   ```bash
   scripts/crear-chr.sh r1 && scripts/configurar-chr.sh r1   # NAS / servidor PPPoE
   scripts/crear-chr.sh r2 && scripts/configurar-chr.sh r2   # abonado1 (pppoe-client)
   scripts/crear-chr.sh r3 && scripts/configurar-chr.sh r3   # abonado2 (pppoe-client)
   ```

   R2 y R3 traen un scheduler `trafico` (`mikrotik/abonado-trafico.rsc`) que genera tráfico de fondo hacia R1 (~220 kbit/s, 30 s de cada minuto), para que el accounting y la "Velocidad del abonado" (dashboard Abonados) tengan datos. Para ver el tope del plan, lanzar a mano un `/tool bandwidth-test` desde el abonado. Para apagarlo: `/system scheduler disable trafico`.

   ```bash
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
VBoxManage startvm isp-radius_r3 --type headless
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

**Dashboards** (carpeta *ISP RADIUS*, provisionados desde `grafana/dashboards/`). Uno por pregunta:

- **Mapa** — ¿dónde está el problema? Dependencias del servicio (abonados → R1 → FreeRADIUS → PostgreSQL, y facturación) con la salud de cada conexión: verde sano, amarillo degradado, rojo falla, gris = no sé o no lo medimos. Click en un nodo: sus logs y dashboards. El modelo vive en `grafana/prometheus/rules/topologia.yml` (con tests) y es solo vista: no alerta.
- **Servicio** — ¿anda bien para los abonados? Los 4 SLIs contra sus objetivos (cada porcentaje con su muestra), alertas activas, presupuesto de error en pedidos (usados / permitidos), velocidad de gasto y cómo terminaron las sesiones.
- **Abonados** — ¿qué le pasa a *este* abonado? (se elige arriba). Si está conectado, plan o suspensión, consumo, velocidad, sesiones con la causa de corte, intentos de login con el motivo y sus logs en R1 y facturación. Vista de soporte.
- **Componentes** — ¿qué pieza falla? R1 como cliente RADIUS, FreeRADIUS, R1 como servidor PPPoE y los jobs de facturación.
- **PostgreSQL** — ¿la base aguanta? Conexiones, consultas lentas, bloqueos, errores y espacio.
- **Infraestructura** — ¿las máquinas aguantan? Las 3 VMs y R1: fuentes de datos, procesador, memoria, disco, reinicios y red.
- **Logs** — exploración: volumen y errores por máquina, FreeRADIUS, PostgreSQL, R1, facturación y sistema, con un buscador de texto.

Siguen criterios comunes (bitácora 26/11): títulos con la pregunta, estados en palabras, todo por minuto, cantidades enteras, porcentajes con su muestra y nombres del lab en lugar de los del sistema.

Todos tienen links entre sí que conservan el rango de tiempo: de un pico en un gráfico se salta a los logs de ese momento.

**Qué mide quién:**

| Exporter | VM | Fuente | Para |
|---|---|---|---|
| r1-exporter (propio) | grafana | `/radius monitor`, `/ppp active` de R1 (API 8728) | SLI 1 y 2, sesiones |
| mktxp | grafana | R1 (API 8728) | CPU, memoria, interfaces, pool, colas |
| freeradius-exporter | freeradius | Status-Server (18121, red interna) | lo que recibió y respondió el servidor |
| postgres-exporter | db | `pg_stat_*` y `db/exporter/queries.yml` | base, SLI 3 y 4 |
| node-exporter | las tres | sistema operativo | disco, memoria, CPU |

**Logs** (Loki, 14 días). Las métricas cuentan; los logs dicen quién y por qué.

```
contenedores ─stdout─► Docker ─journald─► journal de la VM ◄─ Alloy ─┐
kernel, dockerd, ssh ─────────────────────► (500 MB / 14 d)          ├─► Loki (VM grafana) ◄── Grafana
R1 ─syslog UDP 1514─► Alloy de la VM grafana ────────────────────────┘     │ ruler
                                                                            ├─ métricas ─► Prometheus
                                                                            └─ alertas ──► Alertmanager
```

- Etiquetas: `instance` y `service` (las mismas que en Prometheus), `container` o `unit` (sistema), y en R1 `topic` (`ppp`, `radius`, `sistema`). Usuario, MAC e IP **no** son etiquetas: se filtran en el texto (`{container="freeradius"} |= "abonado1"`).
- FreeRADIUS corre sin `-X`: una línea por login con el motivo (`Login incorrect (chap: Password comparison failed ...)`), sin contraseñas.
- Reglas sobre los logs (`grafana/loki/rules/fake/radius.yml`): métricas `radius:sql_errores`, `radius:login_ok`, `radius:login_incorrecto`; alertas `FreeradiusSinBase` (page) y `PosibleFuerzaBruta` (ticket).
- **Punto ciego del SLI 1 que cubren los logs:** con PostgreSQL caído FreeRADIUS no deja de responder, rechaza a todos (`Invalid user`), y para el SLI 1 un reject es una respuesta. Solo el log (`Error: rlm_sql ...`) lo muestra.

**Alertas** (`grafana/prometheus/rules/` y `grafana/loki/rules/`): por síntoma con tasa de quema multiventana (`slo.yml`), saturación al 80 % (`saturacion.yml`) y monitoreo ciego (`infraestructura.yml`). Cada una tiene un `runbook` con el diagnóstico. Además, eventos (`eventos.yml`, todos ticket): R1 o una VM reiniciada, jobs de facturación que no corren o fallan, orden de corte sin confirmar. Las alertas *page* exigen al menos 3 pedidos fallidos (con el tráfico del lab, uno solo no es un incidente).

**Avisos** (`grafana/alertmanager/`):
- *page* → **Telegram** y el **agente de diagnóstico**; *ticket* → Telegram. El mensaje trae el resumen y el runbook.
- Se configura una vez con `scripts/configurar-avisos.sh`, que pide el token del bot y la `ANTHROPIC_API_KEY` sin mostrarlos y los guarda en archivos ignorados por git. Sin eso, las alertas se ven en Alertmanager (http://localhost:9093) y en Grafana.
- **Agente de diagnóstico** (`diagnostico/`, contenedor en la VM grafana): con la API de Claude, investiga cada alerta urgente con herramientas de **solo lectura** (mapa, alertas, Prometheus, Loki) y manda un diagnóstico corto (qué pasa, causa con evidencia, qué hacer, confianza) a Telegram y a su log. También se le puede preguntar a mano: `vagrant ssh grafana -c 'docker exec diagnostico python agente.py "pregunta"'`.

Tests de las reglas con series sintéticas:

```bash
docker run --rm --entrypoint promtool -v "$PWD/grafana/prometheus:/etc/prometheus:ro" \
  prom/prometheus:v3.5.0 test rules /etc/prometheus/tests/reglas_test.yml /etc/prometheus/tests/topologia_test.yml
```

Prometheus relee su configuración y reglas sin reiniciar: `curl -X POST localhost:9090/-/reload`. Loki relee sus reglas solo (cada 1 min).

En VMs creadas antes de los logs: `vagrant provision <vm> --provision-with base` y en la VM `docker-compose up -d --force-recreate` (el log driver se fija al crear el contenedor).

## Notas

- Los scripts de `db/init/` corren **solo con el volumen vacío**. Para reinicializar: `docker-compose down -v` (borra los datos).
- FreeRADIUS corre **sin `-X`**: el log tiene una línea por login (`Login OK` / `Login incorrect` con el motivo) y los errores, sin contraseñas (`freeradius/radiusd.conf`, sección `log`). Se ve con `docker logs freeradius` o en Grafana (Loki). Para depurar un problema puntual con el detalle de cada paquete, en la VM freeradius: `docker-compose stop freeradius && docker-compose run --rm --service-ports freeradius -X` (Ctrl+C y `docker-compose up -d freeradius` para volver). Ojo: `-X` imprime la contraseña de la base y los secrets.
- `db/init/04-exporter.sh` crea el usuario `exporter`. En una base que ya existía, aplicarlo a mano: `vagrant ssh db -c "docker exec -i postgres bash < /vagrant/db/init/04-exporter.sh"`. Lo mismo con los scripts de facturación (`04` a `07`, el `05` necesita `FACTURACION_DB_PASSWORD` de `db/.env`) y con `08-radpostauth-sin-password.sql`.
- Los jobs de facturación se instalan en la VM db con `sed "s#^REPO=.*#REPO=/vagrant#" /vagrant/facturacion/crontab.txt | crontab -`.
- Las sesiones de prueba de `radacct` (`prueba-N`, generadas con `radclient` el 20/11) se borraron el 26/11. Los contadores del SLI 3 bajaron y Prometheus lo tomó como reinicio: hubo un salto falso en los cortes durante 24 h.

## Facturación (suspensión por falta de pago)

Jobs que suspenden a los abonados con facturas vencidas (los pasan al grupo `moroso` de RADIUS y cortan su sesión con un Disconnect vía FreeRADIUS) y los rehabilitan cuando pagan. Ver [`facturacion/README.md`](facturacion/README.md).
