# Escalabilidad del ISP RADIUS y plan de pruebas de carga

Fecha: 2026-11-26. Basado en la configuración real del repo: `freeradius/radiusd.conf`, `freeradius/sql`, `db/init/01-schema.sql`, `db/exporter/queries.yml`, `facturacion/*.sh`, `mikrotik/r1.rsc`, `grafana/mktxp`, `grafana/prometheus`. También usa mediciones del lab de hoy: Prometheus, `pg_settings` y tamaños de tablas.

Donde un valor no se pudo verificar en el repo o en el lab, está marcado como **supuesto**.

---

## 0. Resumen

- **Hoy el límite duro no es el software: es la configuración de R1.** `pool-pppoe` tiene **91 direcciones** (`mktxp_ip_pool_total`), así que R1 no puede tener más de 91 abonados conectados. El CHR tiene 256 MB y 1 vCPU.
- **El tráfico RADIUS de un ISP real es casi todo accounting.** Con 10 000 abonados, los Interim cada 5 min son **~33 pedidos/s constantes, ~88 millones por mes**. El SLO se dimensionó para **20 000 pedidos/mes** (bitácora 18/11), y el lab tiene unos 400.
- **Consecuencia para el monitoreo:** el SLI 1 mezcla autenticación y accounting, porque `/radius monitor` de R1 los cuenta juntos. A escala, que **ningún abonado nuevo pueda entrar** (por ejemplo, Access-Request sin respuesta mientras el accounting anda) puede quedar diluido en menos de 1 % de errores y **no disparar el aviso urgente** (cálculo en 1.3). Hay que separar el SLI de autenticación.
- **Cuellos de botella probables, en orden de aparición al crecer:**
  1. consultas del exporter que recorren `radacct` y `radpostauth` enteras cada 15 s;
  2. `radpostauth` sin retención;
  3. pool de 32 conexiones/hilos de FreeRADIUS en una tormenta de reconexión, con el timeout de R1 (3 s): si la cola lo supera, R1 reenvía y duplica la carga;
  4. métricas por abonado de mktxp (24 series por sesión, medido);
  5. PostgreSQL y FreeRADIUS como puntos únicos de falla;
  6. `suspender.sh`, que manda los Disconnect de a uno.
- **Plan de pruebas:** staging aparte, idéntico a producción, con tres generadores: RADIUS directo (pyrad, radclient o radperf), PPPoE de punta a punta (**BNG Blaster**) y base (pgbench con las consultas reales). Son 11 escenarios con criterios de aprobación atados a los SLO. En producción solo se usan **tráfico espejo** (módulo `replicate` de FreeRADIUS hacia staging) y una **sonda sintética** de baja frecuencia.
- **En este lab se puede probar** el crecimiento de datos (lo más valioso y barato), la carga RADIUS directa a escala chica y los escenarios de falla. **No se puede medir capacidad real.**

---

## 1. Análisis de escalabilidad

### 1.1 Supuestos del modelo

| Parámetro | Valor | Fuente |
|---|---|---|
| Interim-Update | 5 min | `mikrotik/r1.rsc`: `/ppp aaa set interim-update=5m` |
| Sesiones por abonado | 1 PPPoE siempre conectada | diseño del lab |
| Logins por abonado por día | 1,5 (reinicios de CPE, cortes, renovación) | **supuesto** |
| Hora pico | 10 % de los logins del día | **supuesto** |
| Tormenta de reconexión | todos los abonados de un NAS reconectan en 2 min (corte de luz, reinicio del NAS) | **supuesto**: depende del reintento de los CPE |
| Paquetes RADIUS por login | 3: Access-Request + Start + Stop de la sesión anterior | medido (bitácora 21/11: "una reconexión suma 3") |
| Sentencias SQL por login | ~8: 5 SELECT de authorize (radcheck, radusergroup, radgroupcheck, radgroupreply, radreply) + INSERT radpostauth + INSERT Start + UPDATE Stop | consultas estándar de rlm_sql; **supuesto** en el detalle |
| Sentencias SQL por Interim | 1 UPDATE por `acctuniqueid` (índice UNIQUE) | `01-schema.sql` |
| Tamaño por fila de radacct | ~0,8 KB con índices (lab: 227 B de heap promedio en filas cortas; 5 índices) | medido + **supuesto** |

### 1.2 Tráfico estimado

| | 1 000 abonados | 10 000 abonados | 50 000 abonados |
|---|---|---|---|
| Interim (accounting/s, constante) | 3,3 | 33 | 167 |
| Logins en hora pico (auth/s) | 0,04 | 0,4 | 2,1 |
| **Tormenta de reconexión** (auth/s, más igual cantidad de Start/s) | **8** | **83** | **417** |
| SQL en la tormenta (sentencias/s) | ~70 | ~670 | ~3 300 |
| Pedidos RADIUS por mes (contador de R1) | ~8,8 M | ~88 M | ~440 M |
| Filas nuevas de radacct por mes | 45 000 (~36 MB) | 450 000 (~360 MB) | 2,25 M (~1,8 GB) |
| radacct a 12 meses | ~0,5 M filas, ~0,4 GB | ~5,4 M filas, ~4,3 GB | ~27 M filas, ~22 GB |
| UPDATEs de Interim por día (versiones muertas para autovacuum) | 290 000 | 2,9 M | 14 M |
| radpostauth por mes (sin CPE mal configurados) | 45 000 | 450 000 | 2,25 M |

**Lectura:**
- En condiciones normales el sistema hace muy poco: el login es raro y el Interim es una escritura chica.
- El dimensionamiento lo dictan dos eventos: la **tormenta de reconexión** (picos 200 veces mayores que la hora pico) y la **acumulación de datos** (radacct, radpostauth y la basura que dejan los UPDATE).
- Con 50 000 abonados habría varios NAS: un BRAS típico atiende entre 4 000 y 16 000 sesiones (**supuesto**). La tormenta de un NAS es menor que la de toda la red, salvo un corte de energía regional.

**Caso radpostauth patológico:** un CPE con la contraseña mal configurada reintenta cada 10–30 s y genera **3 000 a 8 000 filas por día él solo**. Con 1 % de CPE mal configurados en 10 000 abonados (100 equipos) son **~500 000 filas/día**: más que todo el accounting.

### 1.3 Por qué el SLI 1 deja de servir a escala

R1 cuenta en un solo contador las respuestas de autenticación y las de accounting (bitácora 21/11). Con 10 000 abonados, en una hora hay ~120 000 Interim y ~625 logins (×3 paquetes).

Si FreeRADIUS deja de contestar **solo los Access-Request** (por ejemplo, authorize trabado en una tabla bloqueada) y el accounting sigue andando:

- errores ≈ 625 / 122 000 ≈ **0,5 %** → tasa de quema ≈ 5;
- **no llega a 14,4: no hay aviso urgente**, y el ticket recién después de 6 h;
- mientras tanto, **ningún abonado que se reconecte puede entrar**.

Es el mismo tipo de punto ciego que ya está documentado para "base caída → rejects", pero ahora producido por el volumen.

**Mitigación:**
- Un SLI de autenticación propio: `freeradius_total_access_requests` contra `accepts + rejects` del lado del servidor, más los timeouts de R1.
- Una **sonda sintética** que hace un Access-Request cada 30–60 s con un usuario de prueba. Mide la experiencia de login aunque no haya logins reales, y de paso resuelve el problema de bajo tráfico del lab.

### 1.4 Cuellos de botella, uno por uno

Para cada uno: por qué pasa, cómo se vería en lo que ya monitoreamos, y qué hacer.

#### a) Hilos de FreeRADIUS y pool de conexiones SQL

- **Configuración real:** `radiusd.conf` → `thread pool { start_servers = 5, max_servers = 32, ... }`, `max_request_time = 30`, `max_requests = 16384`. `freeradius/sql` → `pool { start = ${thread[pool].start_servers}, max = ${thread[pool].max_servers} ... }`, o sea **hasta 32 conexiones a PostgreSQL**, una por hilo. PostgreSQL tiene `max_connections = 100` (medido).
- **Por qué es un límite:**
  - Cada pedido ocupa un hilo durante todo su viaje a la base. Con ~8 sentencias de ~1 ms, un login ocupa un hilo ~5–10 ms, así que 32 hilos dan **~3 000–6 000 pedidos/s teóricos** (**supuesto**: depende de la latencia real de la base).
  - Alcanza para la tormenta de 10 000 abonados. **No alcanza si la base se pone lenta**: con 100 ms por consulta, la capacidad cae 100 veces.
- **El amplificador: el timeout de R1.** Verificado en el lab (26/11): `/radius print` muestra `timeout=3s`, que coincide con lo que dice el SLI 2 en `slo.yml`. El export no lo lista porque en RouterOS 7.20 es el valor por defecto.
  - Si en una tormenta la cola hace que la respuesta tarde más de 3 s, R1 **reenvía**. Duplica la carga justo cuando el servidor está saturado (tormenta de reintentos) y genera rechazos espurios: R1 da el login por fallido y el CPE vuelve a empezar.
- **Síntoma en lo que ya existe:**
  - Componentes: colas `freeradius_queue_len_auth/acct` crecen, reenvíos y RTT suben.
  - SLI 2 (sin reenvíos) cae.
  - PostgreSQL: conexiones por usuario `radius` llegan a 32.
- **Mitigación:**
  - Subir `max_servers` y el pool en conjunto, medido en la prueba E3.
  - Timeout de R1 acorde a la latencia medida en tormenta (1–3 s).
  - `max_connections` y/o **PgBouncer** delante de PostgreSQL si hay varios FreeRADIUS.
  - Separar el accounting del camino crítico (punto e).

#### b) Índices de radacct

- **Lo que hay** (`01-schema.sql`):
  - PK `radacctid`, UNIQUE `acctuniqueid`;
  - `radacct_active_session_idx` (`acctuniqueid` WHERE `acctstoptime IS NULL`);
  - `radacct_bulk_close` (`nasipaddress, acctstarttime` WHERE abiertas), que sirve para el Accounting-On;
  - `radacct_start_user_idx` (`acctstarttime, username`);
  - `class`.
- **Comentados:** `radacct_active_user_idx` y `radacct_stop_user_idx`.
- **Faltan para el uso que le damos:**
  - Búsquedas **por usuario**: el nuevo dashboard Abonados, `suspender.sh` (`LEFT JOIN radacct ON username ... AND acctstoptime IS NULL`) y soporte. El índice existente empieza por `acctstarttime`, así que `WHERE username = ...` termina en seq scan. Proponer `(username, acctstarttime DESC)`.
  - Consultas por fecha de cierre (SLI 3 por ventana): `(acctstoptime)`, el `radacct_stop_user_idx` comentado.
- **UPDATE de Interim y basura:** cada Interim crea una versión nueva de la fila. Los Interim no tocan columnas indexadas, así que pueden ser **HOT updates**, pero solo si hay lugar en la página. Con el `fillfactor` por defecto (100) casi nunca lo hay. Proponer `ALTER TABLE radacct SET (fillfactor = 70)` y autovacuum más agresivo en radacct.
- **Síntoma:**
  - PostgreSQL: "Consulta activa más larga" sube y "Escrituras en radacct" se mantiene, pero crecen la latencia y el tamaño de radacct más rápido que las filas.
  - **Hoy no se mide** `n_dead_tup` ni el porcentaje de HOT updates: agregarlos.
- **Mitigación a 12+ meses:** **particionar radacct por mes** (`acctstarttime`) y mover lo viejo a un archivo (tabla histórica o export), manteniendo en caliente solo los meses que usa facturación.

#### c) Consultas del exporter que recorren tablas enteras

`db/exporter/queries.yml` corre en **cada scrape (15 s)**:

| Consulta | Qué hace | Costo |
|---|---|---|
| `radius_sesiones_cerradas` | `GROUP BY` de **todas** las sesiones cerradas | recorre radacct entera |
| `radius_radacct` | `SELECT count(*) FROM radacct` | recorre radacct entera |
| `radius_postauth` | `GROUP BY reply` de **todo** radpostauth | recorre radpostauth entera |
| `radius_sesiones_activas` | `count` de abiertas | barato (abiertas ≈ abonados) |

Con 10 000 abonados a un año (5,4 M filas, ~4 GB) son tres recorridos completos cada 15 s:

- I/O constante que compite con FreeRADIUS;
- el scrape se alarga y, si pasa el `scrape_timeout` (10 s por defecto), `up{job="postgres"} = 0`;
- eso dispara `TargetCaido`, deja huecos en SLI 3/4 y pone el mapa en gris.

Hoy el scrape dura **0,05 s** (medido).

- **Síntoma:** `scrape_duration_seconds{job="postgres"}` creciendo (ya existe; falta graficarlo y alertarlo), la consulta más larga en PostgreSQL y la CPU de la VM db.
- **Mitigación:**
  - Contadores mantenidos por **trigger** en una tabla chica (`sesiones_cerradas_por_causa`), que conserva la semántica de contador que necesita `increase()`.
  - Para `filas`, usar la estimación de `pg_class.reltuples`.
  - El postgres_exporter puede cachear por consulta (`cache_seconds`, **supuesto**: verificar en v0.17.1).
  - Con radacct particionada, contar solo la partición actual.

#### d) radpostauth sin retención

- Crece con **cada intento de login, también los rechazados**, y nadie la borra: el usuario `radius` no tiene DELETE, a propósito, para que el exporter pueda tratarla como contador.
- Con CPE mal configurados es la tabla que más crece (1.2).
- **Hallazgo de seguridad (resuelto el 26/11):** `radpostauth.pass` se guardaba en todas las filas y el rol `grafana` podía leerlo. Ahora un trigger lo descarta y `grafana`/`exporter` leen solo las otras columnas (`db/init/08-radpostauth-sin-password.sql`).
- **Síntoma:** "Tamaño de radacct / disco" no lo muestra (solo mide radacct). La alerta `PosibleFuerzaBruta` (Loki) ve los reintentos.
- **Mitigación:**
  - Retención de 30–90 días con un job de limpieza (rol propio con DELETE) o particionado por mes con `DROP PARTITION`.
  - Pasar el SLI de logins al log o a un contador por trigger, para que no dependa de que la tabla nunca se borre.

#### e) Un solo PostgreSQL para RADIUS y facturación

- Es un punto único de falla asumido (bitácora 20/11): si cae, no entra nadie nuevo, **se pierde el accounting** de los conectados (los Interim y Stop fallan) y facturación no corre.
- **A escala, la pérdida de accounting es el problema más caro:** el consumo es lo que se factura.
- **Síntoma:** `pg_up = 0`, `FreeradiusSinBase` (log), mapa en rojo, SLI 4 cae.
- **Mitigación, de más barata a más completa:**
  1. **Accounting con buffer** (`detail` + sitio virtual `buffered-sql` de FreeRADIUS): FreeRADIUS escribe el accounting en un archivo local y otro proceso lo vuelca a SQL. Si la base cae, el accounting espera en disco y no se pierde.
  2. **Réplica en streaming** con failover (Patroni o similar), y authorize leyendo de la réplica.
  3. Dejar la facturación pesada (reportes) en la réplica para que no compita con RADIUS.

#### f) Un solo FreeRADIUS

- R1 tiene un único `/radius`. FreeRADIUS no guarda estado propio (todo está en la base), así que escalar horizontalmente es fácil: **segundo FreeRADIUS** y segunda entrada `/radius` en R1. RouterOS prueba en orden al vencer el timeout.
- **Síntoma de que hace falta:** `freeradius_up = 0`, `AutenticacionQuemaRapida`, el mapa.
- **Costo:** el doble de conexiones a la base (por eso PgBouncer), y CoA/Disconnect configurados en los dos.

#### g) Suspensión masiva (`facturacion/suspender.sh`)

- El UPDATE es atómico y está bien. Pero después recorre los suspendidos **de a uno**, con un `radclient` por usuario.
- radclient usa por defecto timeout 3 s y 3 reintentos (**supuesto**: defaults de radclient `-t 3 -r 3`):
  - con R1 respondiendo, ~decenas de ms por usuario: 500 suspendidos ≈ medio minuto;
  - **con R1 o FreeRADIUS sin responder**, ~12 s por usuario: **500 suspendidos ≈ 100 min**, y el cron siguiente puede pisarse con este.
- Los Disconnect pasan por el proxy de FreeRADIUS (`r1-coa`): cola `freeradius_queue_len_proxy`.
- **Síntoma:** Logs → jobs de facturación ("ATENCIÓN: no se pudo cortar"); nodo Facturación y conexión Facturación → FreeRADIUS en el mapa.
- **Mitigación:**
  - Un solo `radclient` con todos los pedidos en un archivo y paralelismo (`-p N`).
  - Timeout corto.
  - Límite de tiempo total.
  - Lock (`flock`) para que no corran dos a la vez.

#### h) Cardinalidad de métricas por abonado (mktxp)

- `interface = True` y `queue = True` en mktxp: **24 series por interfaz `<pppoe-abonado>`** (medido), más las de la cola dinámica de cada abonado.
- Hoy Prometheus tiene 8 571 series. Con 10 000 abonados serían **~300 000 series más**, solo de esto, en una VM de 2 GB (**supuesto**: unos KB de RAM por serie activa).
- Además, mktxp consulta por la API de R1 la lista entera de interfaces cada 15 s, lo que carga la CPU del NAS.
- **Síntoma:** `prometheus_tsdb_head_series`, memoria de la VM grafana, CPU de R1, `scrape_duration_seconds{job="r1-mktxp"}`.
- **Mitigación:**
  - Apagar interfaces y colas por abonado en mktxp. Dejar solo las físicas y agregadas.
  - Sacar el **consumo por abonado de radacct** (los Interim ya lo traen cada 5 min) para el dashboard Abonados.

#### i) Logs

- Volumen moderado: con 10 000 abonados, ~1 línea de FreeRADIUS y ~4–5 de R1 por login, ≈ 75 000 líneas/día ≈ 15 MB/día (**supuesto**).
- Las etiquetas de Loki no llevan usuario, así que la cardinalidad está bien.
- **Riesgos:**
  - CPE en bucle de rechazos ("Login incorrect" cada pocos segundos);
  - alguien que deja FreeRADIUS en `-X` (cientos de líneas por pedido);
  - el journal de cada VM está topeado en 500 MB.
- **Síntoma:** Logs → "Líneas por servicio" con un salto de volumen.
- **Mitigación:** límites de ingesta por tenant en Loki, y una alerta de volumen.

#### j) Límites del NAS del lab

- `pool-pppoe` tiene 91 direcciones (alerta `PoolPppoeCasiAgotado` al 80 %).
- El CHR tiene 256 MB y 1 vCPU.
- Si el CHR usa la licencia gratuita, está limitado a 1 Mbit/s por interfaz (**supuesto**: no verifiqué la licencia).
- En producción, el NAS y su pool son lo primero que se dimensiona.

---

## 2. Plan de pruebas de carga para producción

### 2.1 Principios

1. **Nunca se carga el FreeRADIUS ni la base de producción.** Se prueba en **staging**: misma versión de RouterOS en el NAS, misma imagen y configuración de FreeRADIUS, PostgreSQL de la misma versión y tamaño, **datos del tamaño de producción** (anonimizados) y **el mismo stack de monitoreo**. Así los dashboards y alertas actuales son el instrumento de medición, y la prueba también los valida.
2. **Aislamiento:**
   - shared secret, IP y clientes (`clients.conf`) propios de staging;
   - los generadores **no** se dan de alta como clientes en producción;
   - checklist antes de cada corrida: a qué IP apunta, qué secret usa.
3. **El generador no puede ser el cuello de botella:** se monitorea su CPU y su red. Si satura, la medición no vale.
4. **Se corta solo:** cada escenario tiene una condición de corte automática y un "botón rojo" (matar el generador).
5. **Lo que sí se hace en producción:**
   - **Tráfico espejo:** el módulo `replicate` de FreeRADIUS copia el accounting real hacia staging sin esperar respuesta. Staging recibe el patrón real sin afectar a nadie.
   - **Sonda sintética:** un Access-Request cada 30–60 s con un usuario de prueba. Es carga despreciable y da un SLI de login continuo (ver 1.3).
   - Pruebas de falla (por ejemplo, failover del segundo FreeRADIUS) **solo en ventana de mantenimiento**, anunciada y con vuelta atrás escrita.

### 2.2 Herramientas

| Capa | Herramienta | Para qué |
|---|---|---|
| RADIUS directo (sin NAS) | **Script propio con `pyrad` + asyncio** (recomendado), `radclient -f pedidos.txt -p N`, o **radperf** (NetworkRADIUS) | Tasa controlada de Access-Request y Accounting (Start/Interim/Stop) con usuarios distintos. Mide latencia (p50/p99) y pérdidas. radclient paraleliza pero no controla la tasa |
| PPPoE de punta a punta | **BNG Blaster** (rtbrick, open source) | Emula miles de clientes PPPoE contra el NAS y mide sesiones por segundo y tiempos de conexión: la tormenta real. Alternativas más pobres: `pppd` + `rp-pppoe` en interfaces macvlan, o varios CHR (caros en RAM) |
| Base | **pgbench con scripts propios** | Reproducir las consultas reales de authorize/accounting (las de `queries.conf` de rlm_sql) y las del exporter, con datos de tamaño real |
| Fallas | `tc netem` (latencia y pérdida en la red de gestión), `docker stop`, `pg_sleep`/locks | Base lenta, red con pérdida, servicio caído |
| Datos | SQL con `generate_series` | Usuarios y su historia (2.3) |

### 2.3 Datos de prueba

- **Usuarios:** N filas en `radcheck` (`Cleartext-Password`) y `radusergroup` (planes repartidos), con `generate_series`. En facturación, por la función `facturacion.alta_servicio()` en un bucle, para respetar las validaciones y la atomicidad. Unos cuantos clientes con facturas vencidas, para la suspensión masiva.
- **Historia:** radacct con 6 y 12 meses sintéticos (1,5 sesiones por abonado por día, causas con la proporción real: mayoría User-Request y NAS-Request, algunas Lost-Carrier). radpostauth con el mismo período, más un 1 % de "CPE en bucle de rechazo".
- **Medir el tamaño resultante** contra la tabla de 1.2 para calibrar el modelo.

### 2.4 Escenarios

Para cada uno: objetivo, cómo se genera, qué se mira (paneles que ya existen), criterio de aprobación y corte.

**Criterio general de aprobación,** salvo que se indique otro:
- SLI 1 (respondidos) ≥ 99,9 % y SLI 2 (sin reenvío) ≥ 99 % en la ventana de la prueba;
- **p99 de latencia del servidor < timeout de R1** (3 s, verificado en el lab);
- colas de FreeRADIUS que vuelven a 0;
- consulta más larga < 1 s;
- CPU < 70 % y memoria < 80 % en las VMs.

**Corte automático,** salvo otro:
- SLI 1 < 99 % durante 5 min;
- conexiones a PostgreSQL > 90 %;
- disco libre < 15 %;
- generador > 80 % de CPU.

| # | Escenario | Objetivo | Cómo se genera | Qué se mira | Aprueba si |
|---|---|---|---|---|---|
| E1 | **Humo** | Que la medición funcione | 1 login/s + Interim de 100 sesiones, 10 min (pyrad) | Todos los paneles se mueven y las alertas no disparan | Los números del generador coinciden con FreeRADIUS y R1 (±1 %) |
| E2 | **Hora pico sostenida** ×2 | Margen en un día normal | Para 10 000: 1 auth/s + 70 acct/s durante 1 h | SLI 1/2, colas, RTT, conexiones PG, consulta más larga, CPU | Criterio general |
| E3 | **Escalones hasta romper** | Encontrar la capacidad | Subir la tasa ×1,5 cada 5 min hasta que falle el criterio | Lo mismo, más qué recurso se satura primero (hilos, conexiones, CPU de la base, disco) | Capacidad = último escalón que pasó × 0,7. **Debe superar la tormenta de 2.1 del tamaño objetivo** |
| E4 | **Tormenta de reconexión** | Que un corte de luz no se convierta en un incidente largo | BNG Blaster: N sesiones arriba, cortarlas todas y reconectar a la tasa máxima de los CPE. Variante: reinicio del NAS (Accounting-On + cierre masivo con `radacct_bulk_close`) | Tiempo hasta reconectar el 100 %, reenvíos (SLI 2), rechazos espurios (rejects que no son de contraseña), sesiones fantasma en radacct, pool | 10 000 sesiones reconectadas en < 5 min (**objetivo a acordar**), 0 rechazos espurios, 0 sesiones fantasma |
| E5 | **Accounting de N sesiones** | Aguante de escritura y basura | N sesiones simuladas con Interim cada 5 min, 2 h | Escrituras en radacct, % HOT updates y `n_dead_tup` (**agregar al exporter**), autovacuum, SLI 4 | SLI 4 ≥ 99 %, `n_dead_tup` estable, sin crecimiento de la consulta más larga |
| E6 | **Base lenta y base caída** | Comportamiento ante falla de la dependencia | Durante E2: `tc netem delay 200ms` hacia la base; después `docker stop postgres` 10 min | `FreeradiusSinBase`, mapa, SLI 1 (punto ciego), accounting perdido (Stop/Interim que no llegaron a radacct) | Las alertas disparan en < 3 min. Con buffered-sql, 0 accounting perdido. Sin él, **se mide cuánto se pierde** y eso justifica el cambio |
| E7 | **Caída de un FreeRADIUS** (con dos) | Failover | Durante E2, `docker stop` del primero | Reenvíos (pico esperado), tiempo hasta que R1 pasa al segundo, SLI 1 | SLI 1 no baja del SLO en la ventana de 1 h |
| E8 | **Suspensión masiva** | Que facturación termine a tiempo y corte a todos | 5–10 % de los abonados con factura vencida y sesión abierta (BNG Blaster). `suspender.sh`. Variante: con R1 inaccesible | Duración del job, "Órdenes de corte enviadas/confirmadas", cola proxy de FreeRADIUS, CPU de R1 | Termina en < 10 min y 100 % de Disconnect-ACK. Con R1 caído, termina igual dentro de su límite y lo informa |
| E9 | **Crecimiento de datos** (6 y 12 meses) | Que el monitoreo y las consultas aguanten el volumen | Cargar la historia sintética de 2.3 | `scrape_duration_seconds{job="postgres"}`, consulta más larga, dashboards Abonados y PostgreSQL (tiempo de carga), `suspender.sh` | Scrape < 2 s, ningún panel tarda > 3 s, consultas de facturación < 1 s |
| E10 | **CPE en bucle de rechazo** | Que un error de configuración masivo no tumbe nada | 1 % de clientes con contraseña mala reintentando cada 10 s, 2 h | `PosibleFuerzaBruta`, crecimiento de radpostauth, volumen de logs, SLI 1 (los rejects cuentan como buenos) | Alerta de ticket, sin degradar a los demás, crecimiento acotado por la retención |
| E11 | **Soak (24–72 h)** | Fugas y efectos lentos | E2 constante + Interim de N sesiones + jobs de facturación con su cron | Memoria de FreeRADIUS y PostgreSQL, basura, disco (días hasta llenarse), Prometheus (series), Loki (volumen) | Memoria estable, disco proyectado > 90 días, sin alertas espurias |

**Orden de ejecución:**
1. E1 → E2 → E3: calibrar y encontrar la capacidad.
2. E9: cargar los datos; desde ahí todo corre sobre la base "vieja".
3. E5 → E4: escritura, luego tormenta.
4. E6 → E7: fallas.
5. E8 → E10: casos de negocio.
6. E11: al final, con la configuración que haya salido de los anteriores.

Después de cada cambio de configuración (pool, timeout, índices) se repiten E3 y E4 para confirmar la mejora.

### 2.5 Cambios de monitoreo para aguantar producción

1. **SLI de autenticación separado del de accounting** (1.3): contadores del lado de FreeRADIUS más la **sonda sintética**. El SLO se recalcula con el volumen real.
2. **Exporter sin recorridos completos** (1.4.c): contadores por trigger, estimaciones para `filas`, y alerta sobre `scrape_duration_seconds{job="postgres"}`.
3. **Métricas nuevas de la base:** `n_dead_tup`, % HOT updates, última vez de autovacuum en radacct, tamaño de radpostauth, WAL por minuto.
4. **Sacar las métricas por abonado de mktxp**; el consumo por abonado sale de radacct.
5. **Latencia del servidor como distribución:** hoy solo existe "RTT del último pedido" de R1, que es una muestra suelta. Para un p99 hace falta medirlo del lado de FreeRADIUS o con la sonda.
6. **Alertas de capacidad** (ticket):
   - pool del NAS, que ya existe;
   - conexiones a PostgreSQL, que ya existe;
   - **días hasta llenar el disco**;
   - **cola de FreeRADIUS sostenida > 0**;
   - volumen de logs anómalo.
7. Prometheus con más memoria o con remote-write a un almacenamiento de largo plazo si se pasan las ~100 000 series.

---

## 3. Qué se puede probar en este lab y qué no

**Recursos:**
- **Host:** 12 núcleos, 14 GB de RAM, ~13 GB en uso con todo el lab prendido.
- **VMs** de 1 vCPU: db (1 GB), freeradius (1 GB), grafana (2 GB).
- **CHR** de 256 MB y 1 vCPU, con un pool de 91 IPs.

| Se puede (y vale la pena) | Cómo | Qué aporta |
|---|---|---|
| **E9 crecimiento de datos** | Cargar radacct y radpostauth sintéticas en la VM db (disco virtual de ~100 GB; ojo con el disco real del host) | Es lo más valioso: los recorridos completos del exporter y los índices que faltan se ven igual en una VM chica. Es el cuello de botella más probable y el más barato de probar |
| E1, E2 y E3 a escala chica | pyrad o radclient desde la VM grafana hacia FreeRADIUS (cliente de prueba en `clients.conf`, solo en el lab) | Valida el método, los paneles y las alertas. Muestra **qué** se satura primero, no **cuánto** aguanta producción |
| E6 base lenta o caída, E7 (con un segundo contenedor de FreeRADIUS) | `tc netem`, `docker stop` | Comportamiento y alertas, que son independientes del tamaño |
| E8 suspensión masiva, en parte | Usuarios ficticios con facturas vencidas (sin sesión: prueba el SQL y el bucle). Con R1 inaccesible, mide el peor caso del bucle | La duración del bucle con timeouts. Necesita primero cargar el esquema `facturacion`, que falta en la base del lab |
| E10 CPE en bucle | radclient con contraseña mala en bucle | Crecimiento de radpostauth y la alerta `PosibleFuerzaBruta` |
| Sonda sintética | Contenedor chico con radclient cada 60 s | Además arregla el problema de bajo tráfico del SLO del lab |

| No se puede (o no sirve) | Por qué |
|---|---|
| Capacidad real (E3 con números para producción) | 1 vCPU por VM en un host compartido: los números son relativos (sirven para comparar antes y después de un cambio), no absolutos |
| Tormenta PPPoE real (E4) a escala | El pool tiene 91 IPs, el CHR 256 MB, y BNG Blaster necesitaría otra VM en la red de acceso con RAM que el host no tiene libre. A lo sumo, decenas de sesiones |
| Latencias de red realistas | La red interna de VirtualBox no se parece a un backbone. netem simula, pero no reemplaza |
| Soak de 72 h (E11) | Se puede dejar corriendo, pero el host es una notebook de trabajo; sirve para fugas groseras |
| Failover de PostgreSQL | No hay réplica. Habría que agregar otra VM |

**Recomendación para el TP:**
- Hacer **E9** (crecimiento a 12 meses de 10 000 abonados, ~4 GB) y medir el scrape del exporter antes y después de optimizar sus consultas.
- Hacer **E2/E3 a escala chica** para mostrar cómo responden los paneles.
- Documentar el resto como plan para producción, con la tabla de 1.2 como justificación del dimensionamiento.
