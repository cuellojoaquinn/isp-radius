# Guía de la demo

Cada parte se puede mostrar sola: qué se muestra, cómo se provoca, qué mirar y cómo se vuelve a la normalidad. Los comandos se corren desde la carpeta del repo en la computadora.

## Antes de empezar

1. **Prender el lab** (servidores primero, routers después: ver README, *Después de reiniciar la computadora*):
   ```bash
   vagrant up db freeradius grafana
   VBoxManage startvm isp-radius_r1 --type headless
   VBoxManage startvm isp-radius_r2 --type headless
   VBoxManage startvm isp-radius_r3 --type headless
   ```
2. **Esperar unos 5 minutos** y abrir Grafana en http://localhost:3000, dashboard **Mapa**. Todo en verde salvo:
   - "Facturación → FreeRADIUS" en gris: no hubo suspensiones en 24 h, así que no hay nada que medir.
   - "FreeRADIUS → R1 (CoA)" en gris: no se mide.
3. **Avisos (opcional, una sola vez):** `scripts/configurar-avisos.sh` pide el token del bot de Telegram y la clave de la API de Claude para el agente. Sin eso, todo funciona igual, pero no llegan mensajes ni diagnósticos.
4. **Al prender el lab** suenan dos alertas tipo *ticket*, y es correcto:
   - **R1Reiniciado**: R1 arrancó hace menos de 15 min.
   - **VMReiniciada**: lo mismo para cada VM.

## Demo en vivo: 12 abonados conectándose y navegando (guion de ~15 min)

`scripts/demo/abonados.sh` agrega 10 abonados de demo (abonado3 a abonado12):
- se dan de **alta por facturación**, con las mismas funciones que usa el menú;
- se conectan por PPPoE desde R2 y R3, varias conexiones por router;
- generan tráfico con tres perfiles: **liviano** (3, 6, 9, 12), **navegación** en ráfagas (4, 7, 10) y **streaming** constante (5, 8, 11). abonado4, abonado8 y abonado12 tienen el plan de 10 megas.

**Preparación (una hora antes, para que los gráficos tengan historia):**
```bash
scripts/demo/abonados.sh alta          # 10 clientes nuevos en facturación y RADIUS
scripts/demo/abonados.sh conectar      # sus conexiones PPPoE en R2 y R3
scripts/demo/abonados.sh trafico on    # tráfico en tiempo real
scripts/demo/abonados.sh estado        # tienen que aparecer 12
```
Pantalla: **Componentes**, con la fila *En vivo* arriba y refresco cada 10 s. En otra pestaña, **Abonados**.

| Min | Acto | Comando | Qué se ve |
|---|---|---|---|
| 0 | Punto de partida | — | Componentes: 12 abonados conectados y la lista de *Logins en vivo*. Mapa: "12 sesiones" |
| 2 | Se conectan los clientes | `scripts/demo/abonados.sh conectar` (vuelve a crear las 10 conexiones) | En *Logins en vivo* entran los 10 `Login OK` en segundos, cada uno con su usuario y la MAC de su router. Para mostrar el alta desde cero, ver la sección *Alta de un cliente* |
| 5 | Tráfico por cliente | — | Abonados: abonado5 (streaming, ~100 kbit/s constante), abonado4 (ráfagas) y abonado3 (casi nada). El historial de sesiones. Infraestructura: tráfico de R1 hacia abonados |
| 7 | Contraseña equivocada | `scripts/demo/fuerza-bruta.sh 3` | Abonados (abonado2): `Login incorrect` con el motivo. *Logins en vivo* se llena de rechazos. Si supera 20 en 5 min, suena la alerta PosibleFuerzaBruta |
| 10 | Un cliente no paga | `scripts/demo/deuda.sh abonado5` y después `suspender` (sección 3) | La curva de abonado5 se corta en vivo y la sesión termina con "R1 la cortó (a mano o por orden de facturación)". Con pago y `rehabilitar`, vuelve |
| 12 | Se cae la base | Sección 5 | Mapa en rojo. Los conectados siguen navegando: las curvas no se cortan. Alerta urgente y diagnóstico por Telegram |
| 14 | Corte de luz en R1 | `VBoxManage controlvm isp-radius_r1 reset` | Los 12 abonados caen a 0 y se reconectan todos juntos: tormenta de logins en *Logins en vivo*. Alerta R1Reiniciado |
| 15 | Cierre | — | Servicio: indicadores con muestra real, cortes por causa, alertas que sonaron |

Lo de la demo **queda guardado**: las conexiones y el tráfico están en R2 y R3, y los clientes en la base. Al prender el lab otro día, los 12 abonados se conectan solos y el tráfico arranca solo.

**Volver al estado normal:** `scripts/demo/abonados.sh trafico off` corta el tráfico y reactiva el de fondo de abonado1 y abonado2. Para sacar todo lo de la demo: `scripts/demo/abonados.sh borrar`, que deja las sesiones en el historial.

**Límite del lab:** la licencia gratuita de los routers virtuales limita cada interfaz a 1 Mbit/s en total, y todos los abonados de un router comparten una. Los perfiles suman unos 500 kbit/s. Más tráfico satura el enlace y las sesiones se caen ("peer is not responding").

### Alta de un cliente nuevo en vivo

```bash
scripts/demo/abonados.sh alta 11       # suma abonado13 (los 10 anteriores ya existen y no se tocan)
scripts/demo/abonados.sh conectar 11   # su conexión en R3
scripts/demo/abonados.sh trafico on 11
```
**Qué se ve:**
- En *Logins en vivo* aparece `Login OK: [abonado13]`.
- *Abonados conectados* pasa a 13.
- En **Abonados**, abonado13 ya figura en la lista, con su plan.
- **Lado de facturación:** el menú (`vagrant ssh db -t -c /vagrant/facturacion/menu.sh`, opción 1) muestra al "Cliente demo 13" con su servicio activo. El alta se puede hacer también desde el menú (opciones 5 y 6), pero entonces hay que cargar la conexión en el router a mano.

## 1. Recorrido: un dashboard por pregunta (3 min)

| Dashboard | Qué mostrar |
|---|---|
| **Mapa** | Quién depende de quién y en qué estado está cada conexión. Click en un círculo para ir a sus logs y dashboards. La base es una sola para RADIUS y facturación. |
| **Servicio** | Los 4 indicadores contra sus objetivos, cada uno con su muestra. Alertas activas. El presupuesto de error "Agotado" y por qué pasa en el lab. |
| **Abonados** | Elegir abonado1: conectado, plan, IP, consumo, velocidad, sesiones con la causa de corte y logs. |
| **Componentes / PostgreSQL / Infraestructura** | Dónde se busca la causa: qué pieza, la base, las máquinas. |
| **Logs** | El buscador de texto, por ejemplo con `abonado2`. |

## 2. Autenticación: aceptado y rechazado con el motivo (2 min)

```bash
# Login correcto (CHAP) y uno con contraseña equivocada, directo contra FreeRADIUS
vagrant ssh freeradius -c 'S=$(grep RADIUS_SECRET_LOCAL /vagrant/freeradius/.env | cut -d= -f2); radtest -t chap abonado1 secreto1 127.0.0.1 0 $S; radtest -t chap abonado1 mala 127.0.0.1 0 $S'
```
**Qué mirar:**
- Abonados (abonado1), *Intentos de login, con el motivo*: `Login OK` y `Login incorrect (... password is incorrect)`, con cliente `dockernet`.
- Los logins que vienen de R1 dicen `client r1` y traen la MAC del equipo.

## 3. Facturación: suspensión por falta de pago y rehabilitación (5 min)

```bash
scripts/demo/deuda.sh abonado2                    # factura vencida ayer, impaga
vagrant ssh db -c 'systemd-cat -t facturacion-suspender --stderr-priority=err /vagrant/facturacion/suspender.sh'
```
**Qué mirar:**
- **Abonados (abonado2)**: *Plan o estado* = "Suspendido por falta de pago", la sesión terminó con "R1 la cortó (a mano o por orden de facturación)" y los intentos de R3 se rechazan.
- **Logs**, fila Facturación: `Suspendido: abonado2` y `sesión en 10.10.10.1 cortada (Disconnect-ACK)`.
- **Mapa**: la conexión Facturación → FreeRADIUS pasa a verde ("1 disconnect/24 h"), o a amarillo si en las últimas 24 h hubo alguna orden sin confirmar.

**Volver:** registrar el pago y rehabilitar.
```bash
vagrant ssh db -t -c '/vagrant/facturacion/menu.sh'   # opción 11 (Registrar pago), usuario abonado2, después 0
vagrant ssh db -c 'systemd-cat -t facturacion-rehabilitar --stderr-priority=err /vagrant/facturacion/rehabilitar.sh'
```
Si no se corre a mano, el cron lo hace solo en menos de 5 min. abonado2 se reconecta en unos segundos.

## 4. Cambio de plan en caliente (CoA) (2 min)

```bash
vagrant ssh db -t -c '/vagrant/facturacion/menu.sh'   # opción 7: abonado1 -> plan-10m
```
- R1 cambia la velocidad **sin cortar la sesión**: en Abonados, el *tiempo conectado* sigue corriendo.
- Para ver el tope de la cola, lanzar a mano un `/tool bandwidth-test` desde R2.
- **Volver:** misma opción, `plan-50m`.

## 5. Falla real: se cae la base de datos (5 min, alerta urgente + agente)

```bash
vagrant ssh db -c 'docker stop postgres'
# que haya logins para que FreeRADIUS registre los errores (los Interim de R1 también los generan)
vagrant ssh freeradius -c 'S=$(grep RADIUS_SECRET_LOCAL /vagrant/freeradius/.env | cut -d= -f2); for i in 1 2 3; do radtest abonado1 secreto1 127.0.0.1 0 $S >/dev/null; sleep 5; done'
```
**Qué mirar, en orden:**
1. **Mapa**: PostgreSQL y la conexión FreeRADIUS → PostgreSQL en rojo. Facturación → PostgreSQL también, en la próxima corrida del job.
2. A los ~2 min suena **FreeradiusSinBase** (urgente), detectada desde el log. El indicador Respondidos **no** lo ve: con la base caída, FreeRADIUS sigue contestando y rechaza a todos. Por eso esta alerta sale del log.
3. **Telegram** (si está configurado): llega la alerta con el runbook y, alrededor de un minuto después, el **diagnóstico del agente**, con la causa y la evidencia.
4. Los abonados ya conectados **siguen navegando**: R1 no los vuelve a autenticar. Los nuevos no entran.

**Volver:** `vagrant ssh db -c 'docker start postgres'`. Todo vuelve a verde en 2 a 5 min y llega "✅ Resuelta".

## 6. El agente de diagnóstico, a pedido (2 min)

```bash
vagrant ssh grafana -c 'docker exec diagnostico python agente.py "¿Por qué abonado2 no se puede conectar?"'
vagrant ssh grafana -c 'docker exec diagnostico python agente.py'     # revisión general
```
El agente solo puede **leer**: mapa, alertas, Prometheus y Loki. Responde con qué pasa, la causa probable con su evidencia, qué hacer y su confianza. Cada diagnóstico es una llamada a la API de Claude, con un tope de 12 consultas.

## 7. Reinicio de R1 (3 min)

```bash
VBoxManage controlvm isp-radius_r1 reset          # como un corte de luz
```
**Qué mirar:**
- **Componentes**: *Abonados conectados* cae a 0 y vuelve en uno o dos minutos.
- **Logs**, R1: `router was rebooted without proper shutdown`.
- **Servicio**, *Cómo terminaron las sesiones*: "R1 se reinició (NAS-Reboot)", en rojo. Al arrancar, R1 manda Accounting-On y FreeRADIUS cierra las sesiones viejas.
- Alerta **R1Reiniciado** (ticket).

## 8. Fuerza bruta de contraseñas (6 min)

```bash
scripts/demo/fuerza-bruta.sh 5     # R3 con contraseña equivocada durante 5 min; después se restaura sola
```
**Qué mirar:**
- **Abonados (abonado2)**: los `Login incorrect` con la MAC de R3.
- Con más de 20 rechazos en 5 min suena **PosibleFuerzaBruta** (ticket, sale del log), agrupada por MAC.

## Si algo no anda

| Síntoma | Dónde mirar |
|---|---|
| Un panel vacío | Infraestructura, *Fuentes de datos*: qué exporter no responde. |
| Un abonado no conecta | Abonados: el motivo del rechazo; ¿está suspendido? |
| No llegan mensajes a Telegram | `vagrant ssh grafana -c 'docker logs alertmanager 2>&1 \| grep arrancar.sh'` tiene que decir "Telegram activado". |
| El agente no diagnostica | `vagrant ssh grafana -c 'docker logs diagnostico \| tail'`: falta la clave, la clave es inválida o no hay salida a internet. |
| La orden de corte no llega | R1: `/radius incoming print` tiene que decir `accept: yes`. Si R1 no respondía, FreeRADIUS lo marca caído por un rato: `docker restart freeradius`. |
