# Bitácora — Proyecto final ASL: RADIUS, accounting y monitoreo

Registro de lo que investigamos, probamos, decidimos y lo que falló. La idea es poder contestar en la defensa *por qué* está cada cosa y *cómo* diagnosticamos los problemas.

---

## 2026-11-18 — Investigación inicial y preparación del lab (Joaquín)

**Mi parte:** integración del MikroTik (R1) como servidor PPPoE con RADIUS.

### Conceptos que repasé

- **RADIUS = AAA.** Autenticación (¿es quien dice ser?), autorización (¿con qué condiciones entra?), accounting (¿qué hizo mientras estuvo conectado?).
- **El MikroTik es el NAS, o sea, el *cliente* RADIUS.** El abonado nunca le habla al RADIUS: le habla por PPPoE al MikroTik, y el MikroTik consulta al RADIUS (Access-Request → Access-Accept / Access-Reject). Puertos UDP 1812 (auth) y 1813 (accounting).
- **Shared secret:** NAS y RADIUS comparten un secreto. Con él se firman los paquetes y se ofusca la contraseña en PAP. Si no coincide, FreeRADIUS descarta los paquetes y el NAS solo ve timeouts.
- **Accounting:** el NAS manda **Start** (se conecta), **Interim-Update** (periódico, con contadores *acumulados*) y **Stop** (totales + motivo de corte). Quien mide el consumo es el NAS: cada sesión PPPoE es una interfaz dinámica (`<pppoe-usuario>`) con contadores.
- **En la base (`radacct`) una sesión es UNA fila:** el Start hace `INSERT`, los Interim y el Stop hacen `UPDATE` por `acctuniqueid`. Los valores intermedios se pisan → no queda historia minuto a minuto. *(Ojo para el tablero de Grafana.)*
- **Otras tablas de FreeRADIUS:** `radcheck` / `radreply` (por usuario), `radusergroup` + `radgroupcheck` / `radgroupreply` (por grupo = plan), `nas` (clientes autorizados), `radpostauth` (cada intento de login, aceptado o rechazado).
- **PAP vs CHAP:**
  - PAP: la contraseña viaja en claro de abonado a NAS, pero se puede guardar hasheada en la base.
  - CHAP: desafío-respuesta, la contraseña no viaja; pero RADIUS tiene que recalcular `MD5(id + contraseña + desafío)`, así que necesita la contraseña **en claro** en la base. Protege contra replay, no contra fuerza bruta offline (MD5 es rápido).
  - **Decisión tentativa: CHAP.** Mitigación: PostgreSQL aislado en la red de Docker, usuario de base con permisos mínimos, contraseñas fuertes.
- EAP **no aplica**: es para 802.1X, no para PPPoE.

### Estado inicial de R1 (antes de tocar nada)

| Qué | Valor |
|---|---|
| ether1 | red UTM **gestion**, sin IP |
| ether2 | red UTM **lan1**, `192.168.1.1/24` con DHCP |
| ether3 | red UTM **acceso**, con `vlan-acceso` `100.64.1.1/24` |
| PPPoE | funcionando con usuarios **locales** (`/ppp secret`): `abonado1`, `abonado2`, perfil `plan-50m` |
| `plan-50m` | `local-address=100.64.0.1`, `remote-address=pool-pppoe`, `rate-limit=50M/50M` |
| `/ppp aaa` | `use-radius=no`, `accounting=yes` (solo local), `interim-update=0s` (sin Interim) |

Mapeo red UTM ↔ interfaz hecho comparando MACs (UTM *Edit → Network* vs `/interface print`), porque el orden en UTM no garantiza el número de ether.

### Decisiones

1. **FreeRADIUS en Docker sobre una VM Debian**, no instalado con `apt` (el enunciado pide Docker y además ocuparía 1812/1813 en el host).
2. **No usar Docker en la Mac:** Docker Desktop corre los contenedores en una VM oculta y puede cambiar la IP de origen de los paquetes. FreeRADIUS identifica al NAS por IP de origen + secret, así que podría rechazar a R1 sin error claro. En una VM Linux, el DNAT de Docker conserva la IP de origen.
3. **La VM de FreeRADIUS va en la red "gestion"**, separada de abonados (acceso) y de lan1. Argumento: el RADIUS no queda alcanzable desde la red de abonados, como en un ISP real.
   - Direccionamiento gestion: `10.10.10.0/24` → R1 `10.10.10.1`, VM `10.10.10.10`.
   - La VM conserva su interfaz Shared Network (`192.168.64.15`) para internet y SSH. **La interfaz de gestión no lleva gateway** (si no, se rompe la ruta por defecto).
4. **Ir por escalones:** primero FreeRADIUS solo con usuarios en archivo, después sumar PostgreSQL. Así, si algo falla, se sabe en qué tramo.

### Problemas y cómo los diagnosticamos

**1. `apt install` fallaba con "Temporary failure resolving 'deb.debian.org'".**
- `ping 8.8.8.8` → OK; `ping deb.debian.org` → falla ⇒ hay internet, falla el DNS.
- `/etc/resolv.conf` apuntaba a `192.168.64.1` (la Mac como DNS de la Shared Network de UTM), que no respondía.
- Primer arreglo: `nameserver 8.8.8.8` en `/etc/resolv.conf`. Alcanzó para instalar Docker.
- **Volvió a fallar** después de reiniciar la VM (para agregarle la interfaz de gestión): `docker-compose up` no podía bajar la imagen (`lookup registry-1.docker.io on 192.168.64.1:53 ... connection refused`). El cliente DHCP había pisado `/etc/resolv.conf`.
- Arreglo persistente: `supersede domain-name-servers 8.8.8.8, 1.1.1.1;` en `/etc/dhcp/dhclient.conf`. Lección: un arreglo a mano sobre un archivo que genera otro servicio no sobrevive a un reinicio.

**1b. `docker-compose up` → `PermissionError: [Errno 13] Permiso denegado`.**
- El usuario no estaba en el grupo `docker` (o la sesión era anterior al `usermod`). Solución: `usermod -aG docker $USER` y volver a entrar por SSH.

**2. Ping de la VM a R1 en gestion: "Destination Host Unreachable" desde 10.10.10.10.**
- Que el error venga de la *propia* IP indica que falló ARP: nadie contestó "yo tengo 10.10.10.1".
- `/ip address print` en R1 → la `10.10.10.1/24` no estaba (el `add` no se había aplicado).
- Solución: volver a agregarla. Ping OK.

### Escalón 1: FreeRADIUS en Docker (sin base)

- `docker-compose.yml` con la imagen `freeradius/freeradius-server:latest-3.2`, en modo `-X` (debug), puertos `1812/udp` y `1813/udp` publicados.
- Montamos solo dos archivos sobre la config de la imagen:
  - `clients.conf`: cliente `r1` (`10.10.10.1` + secret) y cliente `dockernet` (`172.16.0.0/12`, para probar desde la VM: los paquetes que salen del host hacia el contenedor llegan con IP de origen de la red de Docker, no `127.0.0.1`).
  - `mods-config/files/authorize`: `abonado1 Cleartext-Password := "secreto1"` (solo check, sin reply por ahora).
- Prueba local con `radtest abonado1 secreto1 127.0.0.1 0 testing123` (paquete `freeradius-utils` en la VM: solo trae herramientas cliente) → **Access-Accept** ✅. Por defecto `radtest` usa PAP (se ve `User-Password` en el pedido).
- Con contraseña incorrecta → **Access-Reject** ✅.
- Con CHAP (`radtest -t chap ...`) → **Access-Accept** ✅ (en el pedido viaja `CHAP-Password`, no `User-Password`). Confirma que con `Cleartext-Password` en el servidor CHAP funciona.
- Quién busca al usuario: el módulo `files` (sección `authorize`) lee `mods-config/files/authorize` y carga la contraseña; después `pap`/`chap` (sección `authenticate`) compara. Con PostgreSQL, el que busca pasa a ser el módulo `sql` contra `radcheck`; el resto del flujo no cambia.
- Los warnings de `perl: Setting locale failed` durante `apt` son por locale `es_AR.UTF-8` no generado en la VM; no afectan.

### Paso 2a: alta del RADIUS en R1

- `/radius add address=10.10.10.10 secret=... service=ppp authentication-port=1812 accounting-port=1813` (mismo secret que el cliente `r1` en `clients.conf`, y reinicio del contenedor tras cambiarlo).
- `service=ppp`: el RADIUS se usa solo para PPP/PPPoE (no para el login del router, hotspot, etc.).
- `require-message-auth=yes-for-request-resp` viene por defecto en RouterOS 7 nuevo: exige el atributo `Message-Authenticator` en pedidos y respuestas (mitigación de la vulnerabilidad **BlastRADIUS**, 2024). FreeRADIUS 3.2 lo manda en el Access-Accept (se vio en `radtest`), así que son compatibles.
- Ojo: el MikroTik **busca primero en `/ppp secret` local** y solo consulta RADIUS si no encuentra al usuario. Para probar la integración hay que sacar a abonado1 de la lista local.

### Paso 2b: primera autenticación real por RADIUS ✅ (con un problema)

- Activamos `/ppp aaa set use-radius=yes interim-update=5m` y el log `radius,debug`.
- **Problema:** `/radius monitor` daba `requests: 0` y la sesión de abonado1 no tenía la marca `R`. Causas: (1) la sesión había arrancado antes del cambio (cambiar `/ppp aaa` no re-autentica a los ya conectados) y (2) abonado1 seguía habilitado en `/ppp secret`, que tiene prioridad sobre RADIUS.
- **Solución:** `/ppp secret disable [find name=abonado1]` + `/ppp active remove [find name=abonado1]` para forzar la reconexión.
- **Resultado:** sesión con marca `R`, `requests: 3 / accepts: 3 / timeouts: 0`, RTT 10 ms. En el log de R1 se ve el flujo completo:
  1. `Access-Request` → 10.10.10.10:1812 con `User-Name`, `Calling-Station-Id` (MAC del abonado), `NAS-Port-Id = vlan-acceso`, `Acct-Session-Id = 81500001`, `NAS-IP-Address = 10.10.10.1`, `Message-Authenticator`.
  2. `Access-Accept`.
  3. `Accounting-Request` con `Acct-Status-Type = 7` (**Accounting-On**: el NAS avisa que arrancó a mandar accounting, para que el servidor cierre sesiones viejas que hayan quedado abiertas).
  4. `Accounting-Request` con `Acct-Status-Type = 1` (**Start**) y el mismo `Acct-Session-Id` → así se enlazan auth y accounting de la misma sesión.
- **Hallazgo 1:** el abonado negoció **MS-CHAPv2**, no CHAP (`MS-CHAP-Challenge` / `MS-CHAP2-Response` en el pedido; `MS-CHAP2-Success` y claves MPPE en la respuesta). El servidor PPPoE ofrece varios métodos y el cliente eligió el más fuerte que tenía. FreeRADIUS lo resolvió con el módulo `mschap` usando el `Cleartext-Password`.
- **Hallazgo 2 (problema):** la sesión quedó con `ADDRESS 0.0.0.0` y el Start llegó con `Framed-IP-Address = 0.0.0.0`. Antes la IP y la velocidad salían del perfil `plan-50m`, que estaba asignado en el `/ppp secret` local. Con RADIUS, el Access-Accept no dice ni perfil, ni pool, ni velocidad.

## 2026-11-19 — Direccionamiento y caída del RADIUS

### Decisión: quién define el plan

- **Velocidad → RADIUS** (`Mikrotik-Rate-Limit` en el reply; con la base, en `radgroupreply`). Es una regla de negocio: cambiar un plan es tocar una fila y aplica a todos los routers. Además, Grafana puede cruzar consumo (accounting) con plan.
- **Pool de IPs → router** (perfil por defecto del servidor PPPoE). Es un recurso de red propio de cada router.
- Descartadas: `Mikrotik-Group` (la lógica del plan queda repartida por los routers) y mandar también el pool por RADIUS (`Framed-Pool` es solo un *nombre* que tiene que existir en cada router: no se gana nada).

### Fix del 0.0.0.0

- Causa confirmada: el servidor PPPoE usaba el perfil `default`, que no tiene `local-address` ni `remote-address`. Con usuarios locales no se notaba porque el `/ppp secret` les asignaba `plan-50m`.
- Creamos el perfil `pppoe-base-radius` (`local-address=100.64.0.1`, `remote-address=pool-pppoe`, **sin** `rate-limit`) y lo pusimos como `default-profile` del servidor PPPoE `isp` (sobre `vlan-acceso`).
- Dato: RouterOS reparte las IPs del pool **desde el final del rango** (`pool-pppoe` = `100.64.0.10-100.64.0.100`, por eso el primero recibe la `.100`).
- Se descartó "borrar todos los perfiles y rehacer el DHCP": el DHCP de R1 sirve a lan1 y no participa en PPPoE (la IP del abonado se asigna por IPCP desde el perfil), y `plan-50m` lo sigue usando abonado2.
- El servidor PPPoE tiene tildados mschap2, mschap1, chap y pap → por eso el cliente negoció MS-CHAPv2. Pendiente decidir si se restringe a CHAP.

### Prueba no planeada: el RADIUS caído

- Al reconectar a abonado1 no volvía. Causa: al reiniciar la VM, **el contenedor de FreeRADIUS no había arrancado solo** (el compose no tenía política de reinicio).
- **Qué le pasa al abonado si el RADIUS se cae:**
  - El orden de PPPoE es descubrimiento → LCP → **autenticación** → IPCP (IP). Sin respuesta del RADIUS, R1 agota el timeout y los reintentos, lo toma como rechazo y corta antes de IPCP: **los que intentan conectarse no entran** y no reciben IP.
  - abonado1 no cae a la lista local porque está deshabilitado en `/ppp secret`. abonado2 (local) sí podría entrar.
  - **Los que ya estaban conectados siguen funcionando**: R1 no los re-autentica. Se pierde el accounting (Interim/Stop no llegan).
- Al levantar el contenedor, abonado1 se conectó y recibió IP del pool ✅.

### Decisión: PostgreSQL y Grafana en VMs separadas

- Alternativa evaluada: PostgreSQL en la misma VM y el mismo compose que FreeRADIUS (llega por la red interna de Docker, sin exponer 5432; más simple de reproducir).
- **Elegimos separar:** VM `db` (PostgreSQL en Docker) y VM `grafana` (Grafana en Docker, a cargo de otro integrante), ambas en la red de gestión. Motivos: roles separados como en un ISP real, Grafana consume la base desde otra máquina de todos modos, y una caída de una VM no tumba a las otras.
- Costo asumido: la base **expone 5432** en gestion. Mitigación: publicar el puerto solo en la IP de gestión (no en la Shared Network), `pg_hba.conf` restringido a las IPs de FreeRADIUS y Grafana, y usuarios de base separados (`radius` con escritura sobre las tablas de FreeRADIUS, `grafana` solo lectura).
- Direccionamiento gestion: R1 `.1`, freeradius `.10`, db `.20`, grafana `.30`.

### VM `db`: PostgreSQL en Docker

- VM Debian con dos interfaces (Shared + gestion), hostname `db`, `10.10.10.20/24` sin gateway, DNS persistente y Docker, siguiendo la misma receta que freeradius pero aplicando las lecciones desde el principio.
- `~/db/`:
  - `init/01-schema.sql`: esquema oficial de FreeRADIUS para PostgreSQL, sacado de la propia imagen (`docker cp freeradius:/etc/raddb/mods-config/sql/main/postgresql/schema.sql`), para que coincida con la versión del módulo `sql`.
  - `init/02-usuarios.sql`: rol `radius` (SELECT sobre config; SELECT/INSERT/UPDATE sobre `radacct`, `radpostauth`, `nasreload`; secuencias; **sin DELETE**) y rol `grafana` (solo SELECT sobre `radacct`, `radpostauth`, `radusergroup`, `radgroupreply`, `nas`; **sin acceso a `radcheck`**, donde están las contraseñas en claro).
  - `pg_hba.conf`: `local` trust (solo dentro del contenedor); `radius` solo desde `10.10.10.10/32` y `grafana` solo desde `10.10.10.30/32`, ambos con `scram-sha-256`. El superusuario `postgres` no tiene regla `host` → no entra por red.
  - `docker-compose.yml`: `postgres:16`, `restart: unless-stopped`, `POSTGRES_DB=radius`, `-c hba_file=...` (reemplaza el `pg_hba` permisivo de la imagen), puerto publicado **solo en `10.10.10.20:5432`**, volumen `pgdata` para persistir.
- Los scripts de `/docker-entrypoint-initdb.d` corren solo con el volumen vacío: para reintentar hay que `docker-compose down -v` (borra datos).
- Verificado: roles `postgres`, `radius` y `grafana` creados (`\du`). Como los `GRANT` del script están antes de crear `grafana`, que exista `grafana` confirma que las tablas también se crearon.

- Prueba de conexión desde freeradius (`psql -h 10.10.10.20 -U radius -d radius`, cliente `postgresql-client`):
  - Primer intento: `password authentication failed for user "radius"`. Lectura: red, puerto y `pg_hba` OK (si no, el error sería `no pg_hba.conf entry`); solo fallaba la contraseña (había quedado la de ejemplo del script).
  - Cambio con `ALTER ROLE radius PASSWORD ...` en la base **y** en `02-usuarios.sql` (para que el script siga siendo la fuente si se recrea la base).
  - Segundo intento: OK, `radcheck` vacía.
- DNS de la VM freeradius volvió a fallar: la línea `supersede` nunca se había guardado (solo estaba el ejemplo comentado). El DNS de la Mac falla porque estamos en la red de la facultad (`frm-intranet40`). Se agregó y se verificó con `grep "^supersede"`.

### FreeRADIUS → PostgreSQL (módulo `sql`)

- Datos cargados en la base: `radcheck` (abonado1, `Cleartext-Password`), `radusergroup` (abonado1 → `plan-50m`), `radgroupreply` (`plan-50m` → `Mikrotik-Rate-Limit := 50M/50M`). La velocidad está en el **plan**, no en el usuario.
- Módulo: copiamos `mods-available/sql` de la imagen y cambiamos `dialect = "postgresql"`, `driver = "rlm_sql_${dialect}"` (por defecto venía `rlm_sql_null`), `server = 10.10.10.20`, `port = 5432` (venía 3306, el de MySQL), `login = radius` (nunca el superusuario), `radius_db = radius`. Se nos había duplicado `radius_db`; se dejó una sola.
- Lo montamos en `mods-enabled/sql`. El sitio `default` ya llama a `-sql` en authorize/accounting/post-auth: el `-` significa "si el módulo existe". Por eso antes no hacía nada.
- Vaciamos `mods-config/files/authorize` para que, si abonado1 entra, sea sí o sí por la base.
- Log al arrancar: driver `rlm_sql_postgresql` cargado y pool de conexiones abierto contra `10.10.10.20` como `radius`, sin errores. En el log se ve la query de Start: `INSERT INTO radacct ... ON CONFLICT (AcctUniqueId) DO UPDATE` (el upsert por id de sesión).
- **Ojo seguridad:** en modo `-X` el log imprime la contraseña de la base. `-X` es para el lab/diagnóstico; en producción no se corre en debug.
- Dato: en la imagen `/etc/raddb` y `/etc/freeradius` son la misma config (el log muestra `/etc/freeradius/...`).

### ✅ Integración completa R1 ↔ FreeRADIUS ↔ PostgreSQL

- `radtest -t chap` → Access-Accept con `Mikrotik-Rate-Limit = "50M/50M"` (sale del grupo `plan-50m` en `radgroupreply`). `radpostauth` registra los intentos solo.
- Reconexión de abonado1 desde R1: sesión con marca `R`, IP `100.64.0.100` del pool (perfil `pppoe-base-radius`) y cola dinámica `<pppoe-abonado1>` con `max-limit=50M/50M` → R1 aplica la velocidad que vino de la base.
- Cada pieza responde por su parte: R1 = acceso + pool; FreeRADIUS = decisión AAA; PostgreSQL = abonados, planes y accounting.

### Accounting verificado

- `radacct` mostró dos filas de abonado1: la sesión 1 (16:02–16:41, 2360 s, causa **`NAS-Request`**, que es lo que reporta MikroTik al sacar la sesión con `/ppp active remove`; esperábamos `Admin-Reset`) y la sesión 2, abierta por la reconexión automática, con su primer Interim exactamente 300 s después.
- La sesión 1 empezó **antes** de habilitar el módulo `sql`: el Start se perdió, pero el primer Interim no encontró fila para el `UPDATE` y FreeRADIUS la **creó**, calculando el inicio como hora del Interim menos `Acct-Session-Time`. El accounting se recupera aunque se pierda un Start.
- Tráfico generado desde el abonado (MikroTik) con `/ping 100.64.0.1 size=1400 interval=0.2` o `/tool bandwidth-test` (este último además muestra el tope de 50 Mbps de la cola).
- Las horas en la base están en UTC; `db/acct.sh` las muestra en hora local y los bytes en MB.

## Repo y Vagrant

- El equipo trabaja en **Linux + VirtualBox**; Joaquín en Mac Apple Silicon + UTM. El Vagrantfile apunta a **VirtualBox** (`debian/bookworm64`) y crea `db`, `freeradius` y `grafana` en la red interna `gestion`. R1 y los abonados (CHR) se importan a mano: no hay boxes de CHR prácticas para Vagrant.
- **Secretos fuera del repo:** `freeradius/.env` y `db/.env` (en `.gitignore`), con `.env.example` versionados.
  - FreeRADIUS lee los secretos con `$ENV{...}` en `clients.conf` y en el módulo `sql`.
  - Los usuarios de la base se crean con `init/02-usuarios.sh` (y no `.sql`) para poder usar variables de entorno.
  - El export de R1 en RouterOS 7 oculta los datos sensibles por defecto.
- El módulo `sql` y el esquema del repo salen de FreeRADIUS **3.2.10** (la misma versión que corre el contenedor), con los cambios documentados arriba.

### Pendientes

- [x] Paso 1: FreeRADIUS en Docker con usuario de prueba en archivo + probar con `radtest`.
- [x] Dar de alta el RADIUS en R1 (`/radius`) y activar `use-radius` + `interim-update`.
- [x] Decidir quién define el plan: velocidad por RADIUS (`Mikrotik-Rate-Limit`), pool en el router (19/11).
- [x] Probar qué pasa con los abonados si se cae el RADIUS (conectado vs conectándose) (19/11; medido con alertas el 23/11).
- [x] Sumar PostgreSQL (coordinar esquema con quien hace Grafana).
- [x] Repo + Vagrant (VirtualBox) + secretos en .env.
- [x] Monitoreo: Prometheus, Alertmanager, Grafana y exporters (20–23/11).

## 2026-11-19 (tarde) — Configs de MikroTik al repo

- `mikrotik/r1.rsc` (R1, NAS) y `mikrotik/r2-abonado1.rsc` (R2, abonado1: `pppoe-client` `wan-pppoe` sobre `vlan-acceso`, VLAN 100, `add-default-route=yes`). En RouterOS 7, `/export` oculta secretos por defecto; se quitó además el `system id`.
- **Incidente:** se pegó por error el export de R2 en la terminal de R1, que lo ejecutó como comandos. R1 quedó con identity `R2`, un `pppoe-client` `wan-pppoe` (user abonado1, sin contraseña) y un `dhcp-client` en `ether1` (gestión).
  - Detección: prompt `[admin@R2]` con las IPs de R1 (`/ip address print`) y `/system history print`: todos los cambios a la misma hora, segundos después del export.
  - El rename de ether2→ether3 falló (el nombre ya existía) y las direcciones quedaron intactas; abonado1 nunca se cayó.
  - Reversión: `remove` del `wan-pppoe` y del `dhcp-client`, `/system identity set name=R1`. Lección: `/export` es inofensivo, pero su salida es ejecutable; no pegarla en otra terminal.
- En el export de R1 se ve que el servidor PPPoE quedó con **`authentication=chap`** (decisión aplicada) y que ya no hay usuarios en `/ppp secret`: toda la autenticación pasa por RADIUS.
- Dato: en R1 los nombres de ether2/ether3 están intercambiados respecto de su `default-name` (`set [find default-name=ether3] name=ether2`), por eso el orden de las NICs en UTM no coincidía con el número de ether y hubo que mapear por MAC.
- **Decisión:** se eliminaron los usuarios locales de R1 (`/ppp secret`): los abonados los gestiona solo FreeRADIUS. abonado2 se migra a la base (`radcheck` + `radusergroup` → `plan-50m`). Consecuencia asumida: si el RADIUS se cae, ningún abonado nuevo puede entrar (no hay respaldo local).
- **Prueba automática:** `scripts/test.sh`, que Vagrant corre al final del `vagrant up` de la VM freeradius (y se repite con `vagrant provision freeradius --provision-with test`). Verifica Accept/Reject con PAP y CHAP, el plan que vuelve de la base, la conexión `radius` → PostgreSQL, que `radius` no tenga DELETE, que `grafana` sea rechazado por `pg_hba` desde otra IP y que los intentos queden en `radpostauth`.

## 2026-11-20 — Diseño: suspensión por falta de pago

Discusión de diseño (todavía sin implementar).

- **Separación de responsabilidades:** las reglas de negocio (deuda, vencimiento, pagos) **no van en las tablas de FreeRADIUS** ni se modifica su esquema, porque el módulo `sql` tiene queries que dependen de él. Viven en un **sistema de facturación** con su propia base.
- **Contrato acotado entre los dos:** facturación escribe en la base de RADIUS **solo con atributos que RADIUS ya entiende**, usando un usuario de base propio (`facturacion`) con permisos mínimos (por ejemplo, solo `radusergroup`). No se crea ningún módulo de FreeRADIUS.
- **Quién mira el calendario:** FreeRADIUS es **reactivo**, solo actúa cuando le llega un pedido. Por eso la detección la hace un **proceso en segundo plano de facturación** (por ejemplo, diario). Riesgo a cubrir: si el proceso falla, nadie es suspendido y nadie se entera, así que hace falta un log o una alerta.
- **Qué significa suspender en RADIUS:** mover al abonado al grupo **`moroso`**, que **rechaza** el acceso. Rehabilitar es devolverlo a su plan; el **plan contratado lo recuerda facturación**, no RADIUS.
  - Consecuencia asumida: el abonado queda sin servicio y sin aviso de por qué. Mejora posible (fuera de alcance): dejarlo entrar y redirigirlo a una página de pago (*walled garden*).
- **Cortar al que ya está conectado:** cambiar el grupo solo afecta la **próxima** autenticación. Para cortar en el momento, **Disconnect-Message** (RFC 5176) hacia R1 por `/radius incoming` (UDP 3799), que solo acepta órdenes de IPs conocidas y con secret. Alternativa: **CoA** para cambiar atributos en caliente sin desconectar.
- **Quién manda el Disconnect:**
  - A) Facturación directo a R1: simple, pero cada router tiene que confiar en facturación, y facturación tiene que conocer la red.
  - B) Facturación → FreeRADIUS → R1: los routers confían solo en RADIUS, y RADIUS sabe **en qué router está el abonado** (`radacct.nasipaddress` de la sesión abierta).

Flujo resultante:

```
1. Facturación (job diario) detecta: abonado venció y no pagó
2. Facturación → base RADIUS: radusergroup plan-50m → moroso (usuario facturacion)
3. Disconnect-Request → R1 :3799 (sesión abierta según radacct)
4. El abonado reconecta → FreeRADIUS lee "moroso" → Access-Reject
5. Paga → facturación lo devuelve a su plan contratado
```

**Decisión de implementación (lab):**
- Datos de facturación en un **esquema propio dentro de la misma base `radius`** (no otra VM ni otra base). Motivos: menos conexiones y configuración; JOINs simples con `radacct`/`radusergroup`; y, sobre todo, la suspensión puede ser **una sola transacción** (registrar la suspensión + mover a `moroso`). Costo asumido: si la base cae, caen RADIUS y facturación juntos.
- La separación real la dan los **permisos** del usuario `facturacion` (contrato acotado), no el esquema en sí.
- El **job** es un proceso que corre en la **VM db** y se conecta a la base (no vive dentro de PostgreSQL).
- Pendiente: definir las tablas mínimas del esquema y los `GRANT` exactos del usuario `facturacion`.

## 2026-11-20 al 23 — Monitoreo: Prometheus, Alertmanager y Grafana

**Parte:** monitoreo y alertas. Qué mostrar viene de la investigación del 18/11 (bitácora en Drive): SRE de Google, cuatro señales doradas por componente, SLIs/SLOs con presupuesto de error y alertas por síntoma.

### Decisiones de arquitectura

- **Prometheus no es una capa delante de PostgreSQL.** Es una base de series de tiempo: guarda una foto de cada métrica cada 15 s. Los datos de negocio (quién se conectó, cuánto consumió) se consultan en `radacct` por SQL. Prometheus resuelve lo que la base no tiene: **historia** de contadores que solo existen "ahora" (`/radius monitor` de R1 es acumulado desde que arrancó el router; sin Prometheus no hay ventana de 5 min ni de 30 días).
- **Alertmanager en lugar de las alertas de Grafana.** Las reglas viven en Prometheus (YAML en el repo, con tests) y Alertmanager agrupa, inhibe y rutea. Motivos: el aviso no depende de Grafana (la pieza más pesada), y a futuro el sistema de logs (Loki) y el agente de diagnóstico se enchufan al mismo punto (Loki manda sus alertas a Alertmanager; el agente recibe un webhook con etiquetas para consultar Prometheus/Loki). Costo: los SLI que viven en SQL (3 y 4) se pasan a Prometheus con consultas propias de postgres-exporter.
- **Etiquetas comunes** `instance` (db, freeradius, grafana, r1) y `service` (radius, db, pppoe, monitoreo) desde ahora, para cruzar métricas con logs cuando esté Loki.
- **Qué va en cada VM:** cada exporter vive junto a lo que mide (postgres-exporter en db, freeradius-exporter en freeradius) y entra por la red interna de Docker; lo que lee R1 por la API (mktxp, r1-exporter) va en la VM grafana. Todos los puertos de exporters se publican solo en la IP de gestión.
- **Sin canal de aviso por ahora** (Telegram queda para más adelante): las alertas se ven en Alertmanager y Grafana. Las rutas `page`/`ticket` ya están armadas; sumar un canal es agregar un receiver.

### Fuentes de cada indicador

| SLI | Fuente | Exporter |
|---|---|---|
| 1 disponibilidad `(accepts+rejects)/requests` | `/radius monitor` de R1 | r1-exporter (propio) |
| 2 latencia `1 - resends/requests` | `/radius monitor` de R1 | r1-exporter |
| 3 estabilidad (cortes normales) | `radacct.acctterminatecause` | postgres-exporter (`queries.yml`) |
| 4 frescura del accounting | `radacct.acctupdatetime` de sesiones abiertas | postgres-exporter |

- **mktxp no cubre RADIUS ni PPP** (verificado dentro de la imagen 2.1.0, no solo en el README): se usa para CPU, memoria, interfaces, pool y colas. `/radius monitor` y `/ppp active` los lee un exporter propio en Python (`grafana/r1-exporter/`), por la misma API binaria (8728) que mktxp: en R1 se habilita un solo servicio.
- **freeradius-exporter** (sin imagen oficial; se compila desde el tag 0.2.0) consulta el virtual server `status`. El README dice "3.0.x" pero funciona con 3.2. Permite cruzar lo que vio el NAS con lo que recibió el servidor: en una reconexión real, R1 mandó 3 pedidos y FreeRADIUS registró 1 de auth y 2 de accounting.

### Problemas y cómo los diagnosticamos

**1. El SLI 3 daba `NaN` con dos cortes registrados.** `increase()` necesita dos muestras: una serie que *aparece* con valor 1 toma ese 1 como punto de partida. En producción, el primer corte de cada causa nueva no se contaría nunca. Arreglo: la consulta devuelve siempre las 10 causas conocidas, en 0 si no hubo cortes. Verificado: un corte `NAS-Reboot` pasó de 0 a 1 y se contó. (`increase()` dio 1,077 y no 1: extrapola a toda la ventana.)

**2. `/radius monitor` por la API daba `not enough permissions (9)`** con un usuario `read,api` que sí podía leer `/radius print` y `/ppp active`. Se probó comando por comando desde el contenedor: el `monitor` pide la policy `test` (diagnóstico, no cambia configuración).

**3. Etiqueta `service` pisada.** La métrica de sesiones PPP usaba una etiqueta `service`, que choca con la que agrega Prometheus: aparecía como `exported_service`. Se renombró a `ppp_service`.

**4. mktxp en bucle de reinicio:** `cp: can't stat '/etc/mktxp/_mktxp.conf'`. Ese archivo no está en la imagen: lo crea mktxp la primera vez que arranca (en una prueba anterior se había visto porque antes se corrió `mktxp --help`). Se dejó que lo cree solo.

**5. Vagrant no arrancaba ninguna VM** (`VBoxManage ... E_ACCESSDENIED`): había una VM `<inaccessible>` registrada en VirtualBox cuyo directorio ya no existía, y Vagrant consulta todas. Se desregistró (no había disco que borrar).

### R1 y R2 reproducibles (VirtualBox)

- `scripts/crear-chr.sh r1|r2` crea el CHR 7.20.4 con las NICs en el orden que esperan los exports; `scripts/configurar-chr.sh r1|r2` aplica `mikrotik/*.rsc` por consola serie (socket unix local, sin red: el router no tiene IP todavía) y completa lo que el export oculta desde los `.env`.
- **Tres diferencias entre un CHR nuevo y un export**, descubiertas al aplicar los exports en limpio:
  - El intercambio de nombres ether2 ↔ ether3 del export choca en el primer `set` (el mismo choque que el incidente del 19/11): se renombra antes a un nombre temporal. Por lo mismo, R2 va con 2 NICs (con una tercera, su rename a ether3 choca).
  - Un CHR nuevo trae un `dhcp-client` en ether1 y el export no lo menciona (solo describe lo agregado): R1 habría quedado pidiendo DHCP en la red de gestión. Se borra antes de aplicar el export.
  - La consola de 80 columnas recorta las líneas largas y el script perdía el prompt: se entra como `admin+cte1000w` (sin colores, sin detección de terminal, ancho 1000).
- R2: NIC1 desconectada. En UTM salía a internet por `dhcp-client`; acá daría una segunda ruta por defecto compitiendo con la de PPPoE.

### Hallazgo: `/radius monitor` cuenta también el accounting

Cada reconexión de abonado1 sumó 3 requests y 3 accepts: Stop de la sesión vieja + Access-Request + Start. Eso explicó el "1 request, 1 accept" que R1 mostraba al arrancar sin abonados: era el `Accounting-On`. Para el SLI 1 está bien (un accounting sin respuesta también es el servicio fallando), pero "accepts" de MikroTik no son solo Access-Accept.

### Alertas

- **Síntoma, tasa de quema multiventana** (SRE workbook): *page* si la tasa de quema supera 14,4 en 1 h **y** en 5 min (2 % del presupuesto mensual en una hora); *ticket* si supera 6 en 6 h y en 30 min. La ventana corta hace que la alerta se apague apenas se resuelve.
- **Saturación al 80 %:** disco, conexiones de PostgreSQL, pool `pool-pppoe`.
- **Causas no alertan**, salvo quedarse ciego (exporter caído, R1 sin API): RTT, CPU, bad-replies van a los dashboards y a los runbooks.
- **Inhibiciones:** un page de un SLO calla el ticket del mismo SLO; si cae el node-exporter de una VM, se callan las demás caídas de esa VM.
- **Tests** (`grafana/prometheus/tests/reglas_test.yml`, `promtool test rules`): RADIUS caído → page; servicio sano, sin tráfico o sin sesiones → nada; sesión sin Interim 15 min → page; pool al 82 % → ticket.
- Con poco tráfico, una ventana sin pedidos da `NaN` y la alerta no dispara: no hay pedidos fallando, no hay síntoma.

### Prueba: FreeRADIUS caído, ahora medido

- Se apagó el contenedor de FreeRADIUS y se forzó la reconexión de abonado1. `AutenticacionQuemaRapida` pasó a *firing* a los **2 min 30 s** y llegó a Alertmanager ("Los abonados no se pueden autenticar (67.86% de pedidos sin respuesta en 1 h)").
- El cruce NAS/servidor diagnosticó solo: R1 con 21 timeouts en 5 min, FreeRADIUS con 0 pedidos recibidos y `freeradius_up = 0`. El runbook se corrigió para distinguir "servidor caído" (`freeradius_up == 0`) de "red" (`freeradius_up == 1` y no llegan pedidos).
- El target `freeradius` seguía `up`: el que responde es el exporter, no el servidor. Por eso el estado del servidor se mira con `freeradius_up`.

### Prueba no planeada: reinicio de la computadora (23/11)

- Las VMs no arrancan solas. Al levantar todo, `AccountingDesactualizado` pasó por *pending*: la sesión de abonado1 había quedado abierta en `radacct` sin Stop (R1 se apagó de golpe). R1 mandó `Accounting-On` al arrancar y FreeRADIUS la cerró; el `for: 15m` evitó un aviso falso.
- R1 registró 2 timeouts al arrancar aunque FreeRADIUS ya estaba arriba: R1 manda sus primeros pedidos antes de que la interfaz de gestión esté lista.
- Orden de arranque: primero `vagrant up` (servidores), después R1 y R2. Al revés, R2 intenta conectarse sin servidor y el SLI 1 registra fallas.

### Pendientes

- [ ] Canal de aviso (Telegram) y, a futuro, webhook del agente de diagnóstico.
- [ ] Sistema de logs centralizado (Loki) con las mismas etiquetas `instance`/`service`.
- [ ] Borrar las sesiones `prueba-N` de `radacct` antes de la defensa (hace un salto falso de 24 h en el SLI 3).

## 2026-11-23 — Modelo de datos de facturación (esquema `facturacion`)

Diseño conversado tabla por tabla (todavía sin implementar):

```
cliente         id, ...
tiposervicio    id, nombre, precio, radius_groupname UNIQUE      -- catálogo de planes
estadoservicio  id, nombre UNIQUE, radius_groupname (NULL = usar el del plan)
servicio        id, cliente_id → cliente, tiposervicio_id → tiposervicio,
                estadoservicio_id → estadoservicio, radius_username UNIQUE
factura         id, servicio_id → servicio, monto, fecha_creacion,
                fecha_vencimiento, fecha_pago (NULL = impaga)
```

Decisiones y por qué:
- **Un usuario de RADIUS representa una conexión, no una persona** → `radius_username` va en `servicio` (un cliente puede tener varias conexiones). `UNIQUE` para que dos servicios no compartan usuario (si no, al cortar uno se cortaría el otro).
- **Puentes con RADIUS:** `servicio.radius_username` ↔ `username` de `radcheck`/`radusergroup`; `tiposervicio.radius_groupname` ↔ `groupname` de `radusergroup`/`radgroupreply`. `UNIQUE` en el grupo: cada tipo de servicio tiene su propio grupo (consecuencia: "Plan 50 residencial" y "comercial" necesitarían dos grupos).
- **La factura apunta a `servicio`**: se corta solo el servicio vencido.
- **`fecha_vencimiento` como columna propia** (y no calculada): permite prórrogas sin tocar el job. Condición del job: `fecha_vencimiento < hoy AND fecha_pago IS NULL`.
- **Precio en `tiposervicio` + `monto` en `factura`**: el precio del plan es el vigente; el monto es una copia al emitir, para que un aumento no reescriba las facturas viejas.
- **Estado por servicio, tabla paramétrica `estadoservicio`** (activo / moroso / inactivo) en lugar de un `CHECK`: agregar estados es insertar una fila, y el estado puede llevar datos propios. Se descartó por alcance una tabla de **historia** de estados (mejora posible); parte de esa historia ya la dan `radpostauth` y `radacct`.
- **Regla del grupo de RADIUS:** el del estado si tiene (`moroso`); si es `NULL` (`activo`), el del plan contratado (`servicio` → `tiposervicio`). Rehabilitar = volver a `activo`; el plan contratado nunca se pierde.
- **Sin problema de sincronización entre bases:** el job cambia el estado en facturación y el grupo en `radusergroup` en **una sola transacción** (misma base, otro esquema). Fuente de verdad: facturación.
- **Estados y grupos de RADIUS:** `activo` → `NULL` (usa el plan); `moroso` → grupo `moroso`; `inactivo` (baja) → grupo **`baja`**, separado de `moroso` para que soporte distinga "debe" de "se dio de baja". `inactivo` no puede ser `NULL` porque lo dejaría entrar con su último plan.
- **Cómo rechaza un grupo:** con una **condición** en `radgroupcheck` (check = antes de decidir), no en `radgroupreply` (reply = solo después de aceptar): `Auth-Type := Reject` para `moroso` y `baja`, una fila por grupo.

### Paso 1 implementado: suspensión y rehabilitación a mano ✅

- `radgroupcheck`: `moroso` y `baja` con `Auth-Type := Reject`.
- **Suspensión:** `UPDATE radusergroup SET groupname='moroso' WHERE username='abonado1'`. R2 reintenta solo cada ~11 s y cada intento queda como `Access-Reject` en `radpostauth`.
  - Log de FreeRADIUS de esos pedidos: `chap: Auth-Type := CHAP` → **`sql: Auth-Type = Reject`** → `Found Auth-Type = Reject` → `rejecting user` → `Sent Access-Reject`. El rechazo viene de la condición del grupo y la contraseña ni se evalúa.
  - Se descartó que viniera del usuario: `radcheck` de abonado1 tenía solo `Cleartext-Password`.
- **Rehabilitación:** `UPDATE ... SET groupname='plan-50m'`. El siguiente reintento de R2 recibió `Access-Accept`, sin tocar R1.
- Ciclo completo activo → moroso → activo cambiando **una fila** en la base.
- Aprendizaje de diagnóstico: en la config por defecto, FreeRADIUS no escribe `Login OK/incorrect` (hace falta `auth = yes` en el log). En modo `-X` el motivo se lee en las líneas `sql: Auth-Type`, `Found Auth-Type` y `Sent Access-*`, filtrando por número de pedido.
- Pendiente: hubo Rejects a las 22:10 (antes de `moroso`) recién prendidas las VMs, con causa no confirmada.

### Paso 2: cortar sesiones activas (Disconnect / CoA)

- **CoA** (*Change of Authorization*, RFC 5176): órdenes del lado de RADIUS hacia el NAS sobre una sesión **ya abierta**. `CoA-Request` cambia atributos en caliente (por ejemplo, la velocidad) y `Disconnect-Request` corta la sesión. Las dos van por **UDP 3799**, con los roles invertidos: el NAS es el que responde (ACK/NAK).
- **Tramo 1 (FreeRADIUS → R1) ✅:** `/radius incoming set accept=yes port=3799` en R1. Prueba desde la VM freeradius: `radclient 10.10.10.1:3799 disconnect <secret>` → `Disconnect-ACK`, y R2 se reconectó solo. R1 solo acepta órdenes de los servidores cargados en `/radius` (`10.10.10.10`) y con el mismo shared secret. Primer intento fallido: se usó la contraseña del abonado en lugar del shared secret.
- **Decisión:** el Disconnect lo pide facturación **a FreeRADIUS**, que lo reenvía a R1 (proxy de CoA). Los routers confían solo en FreeRADIUS, y facturación no necesita conocer la red.
- **Tramo 2 (facturación → FreeRADIUS → R1), en curso:**
  - `proxy.conf`: `home_server r1-coa` (`type = coa`, `10.10.10.1:3799`, secret de R1, reintentos `irt/mrt/mrc/mrd`) y `home_server_pool r1-coa-pool`.
  - Sitio `coa` (plantilla de la imagen): `listen type = coa` en 3799 y `recv-coa { update control { &Home-Server-Pool := "r1-coa-pool" } }`. Se quitó `suffix` (no usamos realms).
- **Limitación conocida:** todas las órdenes van a `r1-coa-pool`. Con **varios routers**, habría que elegir el destino según **en qué NAS está la sesión abierta** (`radacct.nasipaddress` con `acctstoptime IS NULL`), con un pool por router o fijando el destino a partir de ese dato.
- **Decisión:** el job **consulta primero** `radacct` (sesión abierta: `acctstoptime IS NULL`) y manda el Disconnect solo si hay sesión. Esa misma consulta da el NAS (`nasipaddress`). Si no hay sesión, alcanza con el cambio de grupo (y si se mandara igual, R1 respondería `Disconnect-NAK`). Implica que el usuario `facturacion` necesita `SELECT` sobre `radacct`.
- Tramo 2, piezas restantes: `clients.conf` con el cliente `facturacion` (`10.10.10.20`, **secret propio**, distinto del de R1: si se roba, permite pedirle cortes a FreeRADIUS pero no hablarle directo a R1); compose con el puerto `3799/udp` publicado y los montajes `sites-enabled/coa` y `proxy.conf`. Verificado: `Listening on coa address * port 3799 bound to server coa`.
- **Problema:** `radclient` desde la VM db → `No reply from server`. Diagnóstico por tramos:
  1. `docker ps`: 3799/udp publicado ✅. `Listening on coa` ✅.
  2. `tcpdump -ni enp0s2 udp port 3799`: los paquetes **llegan** a la VM desde `10.10.10.20` ✅.
  3. `tcpdump -ni any`: Docker los reenvía al contenedor (`br-…` → `veth…` → `172.18.0.2`), conservando el origen ✅. No salía nada hacia R1 ni hacia `.20`: **FreeRADIUS los descartaba en silencio**.
  4. Log **sin filtro**: `Insecure packet from host 10.10.10.20: Packet does not contain required Message-Authenticator attribute`. Protección **BlastRADIUS**: FreeRADIUS exige la firma `Message-Authenticator`.
  - Los filtros de `grep` no lo mostraban porque el mensaje dice `Receive`, no `Received`. **Lección: si el filtro no muestra nada, mirar el log sin filtrar.**
  - Solución correcta: **firmar la orden** (`Message-Authenticator = 0x00` en el pedido; `radclient` la calcula con el secret). Se descartó `require_message_authenticator = no`, que baja la seguridad.
- **Tramo 2 ✅:** `printf 'User-Name = abonado1\nMessage-Authenticator = 0x00\n' | radclient 10.10.10.10:3799 disconnect <secret-facturacion>` desde la VM db → Disconnect-ACK, y abonado1 cortado vía FreeRADIUS → R1. **El job tiene que incluir `Message-Authenticator` en cada orden.**
- Repo actualizado: `freeradius/coa`, `freeradius/proxy.conf` (plantilla 3.2.10 + `r1-coa`), cliente `facturacion` y `RADIUS_SECRET_FACTURACION` en `.env.example`, puerto 3799 en el compose y `/radius incoming` en `mikrotik/README.md`.

### Pasos 3 a 5: facturación implementada ✅

- **Esquema `facturacion`** (`db/init/04-facturacion.sql`): tablas en orden de dependencias (cliente, tiposervicio, estadoservicio → servicio → factura). `CHECK` de importes no negativos y `fecha_vencimiento >= fecha_creacion`, y `DEFAULT CURRENT_DATE` en la creación.
- **Datos de prueba** (`06-facturacion-datos.sql`): estados, Plan 50 (`plan-50m`), dos clientes y una factura **vencida e impaga** de abonado1. Los ids se buscan por nombre, no se escriben a mano.
- **Usuario `facturacion`** (`05-facturacion-usuario.sh`): `SELECT/INSERT/UPDATE` en su esquema (sin `DELETE`); en RADIUS solo **`UPDATE (groupname)`** en `radusergroup` (permiso **por columna**) y `SELECT` en `radacct`; sin acceso a `radcheck`. Verificado: lo permitido funciona y `SELECT radcheck`, `UPDATE radusergroup SET username` y `DELETE` dan `permission denied`.
  - El job entra por `docker exec` (socket local del contenedor): no hace falta otra regla en `pg_hba`. Consecuencia: la regla `local trust` no pide contraseña, pero los permisos del rol se aplican igual.
- **Job `suspender.sh`:** una sola sentencia con CTEs (`vencidos` → `upd_servicio` → `upd_radius`) que cambia el estado y el grupo **atómicamente** y devuelve, con `LEFT JOIN radacct ... acctstoptime IS NULL`, quién tiene sesión y en qué NAS. Disconnect firmado (`Message-Authenticator`) solo a esos. Probado: abonado1 suspendido y cortado; segunda corrida → "Sin servicios para suspender".
- **Pago + `rehabilitar.sh`:** registrar el pago (`fecha_pago`) no rehabilita por sí solo. El job busca morosos **sin ninguna** factura vencida impaga (`NOT EXISTS`: si debe dos y paga una, sigue suspendido) y los pasa a `activo`; el `COALESCE` devuelve el **grupo del plan** porque `activo` tiene `NULL`. No necesita Disconnect. Probado: abonado1 reconectado con su cola de 50M.
- **cron** (VM db, hora `-03`): `suspender` diario a las 03:00; `rehabilitar` cada 5 min (el que paga quiere el servicio ya). Salida en `jobs.log`, la respuesta al riesgo del "job que falla en silencio". Problema: el comando de instalación se corrió dos veces y **duplicó las líneas** (cada job habría corrido dos veces). Se reemplazó el crontab completo (`crontab -` con la lista entera), que es idempotente.
- **En el repo:** los scripts leen el secret de `facturacion/.env` (junto al script), no de `~`. `crontab.txt` se instala con `crontab archivo` (reemplaza, no duplica).

### ABM de servicios con funciones de base ✅

- **Dilema:** el usuario `facturacion` solo puede cambiar el grupo en RADIUS; el **alta** (crear `radcheck`/`radusergroup`) y el **cambio de contraseña** no entran en ese contrato. Opciones: (1) ampliar sus permisos (facturación pasaría a manejar contraseñas), (2) un rol aparte de aprovisionamiento (pierde la atomicidad del alta), (3) **funciones `SECURITY DEFINER`**. **Elegida la 3:** el contrato sigue chico (solo esas funciones), el alta es una sola transacción (no quedan clientes "a medias") y las validaciones viven en un solo lugar.
- Funciona porque facturación y RADIUS son **la misma base con dos esquemas**: una función toca los dos en una transacción. Con bases separadas no se podría.
- **Seguridad de `SECURITY DEFINER`:** `SET search_path = pg_catalog, pg_temp` y tablas con esquema explícito (evita tablas trampa con el mismo nombre); `REVOKE ... FROM PUBLIC` + `GRANT EXECUTE ... TO facturacion` (por defecto cualquiera puede ejecutar funciones).
- **ABM de cliente** (la persona) = SQL común en su esquema, sin funciones. **ABM de servicio** (la conexión) = funciones `alta_servicio`, `cambiar_plan`, `cambiar_password` y `baja_servicio`.
- Decisiones dentro de las funciones: `cambiar_plan` sobre un moroso cambia el plan contratado pero **no** lo saca de `moroso` (cambiar de plan no es pagar); `baja_servicio` **no borra** la contraseña ni las facturas (el grupo `baja` rechaza, queda la historia y dar de baja no cancela la deuda).
- **La base no habla RADIUS:** `baja_servicio` devuelve el NAS con sesión abierta y `cambiar_plan` devuelve NAS + velocidad; el **script** manda el Disconnect o el CoA. `cambiar_plan` lee `radgroupreply` adentro de la función, sin dar ese permiso a `facturacion`.
- **CoA en caliente probado:** `radclient ... coa` con `Mikrotik-Rate-Limit` → `CoA-ACK`; R1 cambió la cola sin cortar la sesión (el uptime siguió). Para cambiar lo que devuelve una función hay que `DROP` + `CREATE` (y volver a dar los permisos).
- **Inyección SQL:** la primera versión de `baja.sh` pegaba el usuario dentro del SQL. En el repo, todos los scripts pasan los parámetros como variables de `psql` (`-v u=...`, `:'u'`).
- Plan 10 megas agregado (`radgroupreply` + `tiposervicio`): un plan nuevo es tarea del **administrador** (`postgres`), porque `facturacion` no tiene permisos sobre `radgroupreply`.
- **Mejora futura evaluada:** un frontend (Angular) para gestionar usuarios. Necesitaría una API intermedia (el navegador no habla con PostgreSQL) que llamaría a estas mismas funciones. Se dejó fuera de alcance para la defensa: la lógica ya está en las funciones, así que la arquitectura queda preparada.
- **Menú interactivo** (`facturacion/menu.sh`): todas las operaciones en un solo lugar, cada una etiquetada con los niveles que toca (FACTURACIÓN / RADIUS / R1). Agrega "emitir factura" manual (precio vigente del plan → `monto`). La consulta de `radpostauth` entra como `postgres`, porque `facturacion` no tiene ese permiso.
