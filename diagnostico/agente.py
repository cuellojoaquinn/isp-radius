"""Agente de diagnóstico del ISP de laboratorio.

Recibe una alerta (o una pregunta) e investiga con herramientas de SOLO LECTURA sobre
el monitoreo del lab: el mapa de dependencias, las alertas activas, Prometheus y Loki.
Devuelve un diagnóstico corto: qué pasa, causa probable con la evidencia, qué hacer.

Uso por consola (demo):
    docker exec -it diagnostico python agente.py "¿por qué está rojo el mapa?"
    docker exec -it diagnostico python agente.py          # revisión general

Corre en la VM grafana porque las herramientas tienen que llegar a la red interna del
lab (Prometheus, Loki, Alertmanager). Usa la API de Claude con el tool runner del SDK.
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

import anthropic
from anthropic import beta_tool

PROMETHEUS = os.environ.get("PROMETHEUS_URL", "http://prometheus:9090")
LOKI = os.environ.get("LOKI_URL", "http://loki:3100")
ALERTMANAGER = os.environ.get("ALERTMANAGER_URL", "http://alertmanager:9093")
MODELO = os.environ.get("MODELO", "claude-opus-5-5")
MAX_ITERACIONES = int(os.environ.get("MAX_ITERACIONES", "12"))   # tope de costo por diagnóstico
MAX_TEXTO = 6000                                                  # tope por resultado de herramienta

SISTEMA = """Sos el agente de diagnóstico de un ISP de laboratorio (proyecto final de Administración de Servicios Linux). Respondé siempre en español rioplatense, claro y sin jerga innecesaria.

## Arquitectura
- Abonados: R2 (abonado1) y R3 (abonado2), MikroTik que se conectan por PPPoE a R1.
- R1 (10.10.10.1): MikroTik, NAS y servidor PPPoE. Le pregunta a FreeRADIUS si cada abonado puede entrar y le informa el consumo cada 5 min (accounting Interim).
- FreeRADIUS (VM freeradius, 10.10.10.10, en Docker): autentica contra PostgreSQL.
- PostgreSQL (VM db, 10.10.10.20, en Docker): una base "radius" con dos esquemas: RADIUS (radcheck, radusergroup, radacct, radpostauth) y facturación. Si cae, caen los dos.
- Facturación: jobs en cron de la VM db. rehabilitar cada 5 min, suspender a las 03:00 (suspende morosos y manda Disconnect vía FreeRADIUS -> R1).
- Monitoreo (VM grafana, 10.10.10.30): Prometheus, Alertmanager, Loki (logs de las VMs vía Alloy y syslog de R1), Grafana.

## Métricas útiles (Prometheus)
- Mapa: topologia_nodo{id,detail__estado} y topologia_conexion{id,source,target,detail__estado} (estado: sano, degradado, falla, sin_dato, sin_metrica). Usá la herramienta estado_del_mapa.
- up{job,instance}: si cada fuente de datos responde (jobs: node, postgres, freeradius, r1-radius, r1-mktxp, loki, alloy, prometheus, alertmanager).
- SLI: slo:radius_auth_errores:ratio_rate5m (pedidos de R1 sin respuesta), slo:radius_auth_reenvios:ratio_rate5m, sli:radius_accounting_fresco:ratio, slo:radius_auth_fallas:increase1h.
- R1: routeros_radius_requests_total, _accepts_total, _rejects_total, _timeouts_total, _bad_replies_total, routeros_ppp_active_sessions{radius}, mktxp_system_uptime, mktxp_system_cpu_load.
- FreeRADIUS: freeradius_up, freeradius_total_access_requests, freeradius_queue_len_auth; del log: radius:sql_errores:rate5m, radius:login_ok:rate5m, radius:login_incorrecto:rate5m.
- PostgreSQL: pg_up, pg_stat_activity_count, radius_pg_consultas_max_segundos, radius_sesiones_activas_total.
- Facturación (del log): facturacion:corridas:count15m{tarea}, facturacion:fallas:count15m, facturacion:sql_errores:count15m, facturacion:disconnect_fallas:count24h.
- VMs: node_* con instance db|freeradius|grafana.

## Logs (Loki, LogQL)
- {container="freeradius"}: "Login OK" / "Login incorrect (motivo)", "Error: rlm_sql" = no llega a la base.
- {container="postgres"}; {instance="r1", topic="ppp"} (conexiones PPPoE); {instance="r1", topic=~"radius|sistema"} (timeouts RADIUS, reinicios, cambios de config).
- {service="facturacion"} (jobs; "FALLÓ", "ATENCIÓN: no se pudo cortar").
- {instance="db|freeradius|grafana", unit="kernel"} (OOM, disco).

## Cómo trabajar
1. Empezá por estado_del_mapa y alertas_activas: te dicen dónde mirar.
2. Confirmá con métricas y logs antes de afirmar una causa. Buscá la causa más arriba en la cadena de dependencias (si PostgreSQL cae, FreeRADIUS rechaza a todos y R1 ve fallas: la causa es la base).
3. Pocas consultas y bien elegidas: cada una cuesta. No repitas consultas.
4. Si no hay evidencia suficiente, decilo. No inventes métricas ni resultados.
5. Solo podés leer: no podés reiniciar ni cambiar nada. Proponé qué hacer.

## Respuesta final (va a Telegram: máximo ~15 líneas, texto plano)
Qué pasa: una o dos líneas con el síntoma para los abonados.
Causa probable: la causa, con la evidencia concreta (métrica o línea de log y su valor).
Qué hacer: 2 a 4 pasos concretos (comandos o dashboards).
Confianza: alta / media / baja, y por qué."""


def _get(url: str, params: dict) -> dict:
    with urllib.request.urlopen(url + "?" + urllib.parse.urlencode(params), timeout=20) as r:
        return json.load(r)


def _recortar(texto: str) -> str:
    return texto if len(texto) <= MAX_TEXTO else texto[:MAX_TEXTO] + f"\n... (recortado, {len(texto)} caracteres)"


def _serie(m: dict) -> str:
    etiquetas = {k: v for k, v in m.items() if k not in ("job",)}
    nombre = etiquetas.pop("__name__", "")
    return nombre + "{" + ", ".join(f'{k}="{v}"' for k, v in sorted(etiquetas.items())) + "}"


@beta_tool
def consultar_prometheus(consulta: str) -> str:
    """Ejecuta una consulta PromQL instantánea (valor de ahora) en Prometheus.

    Args:
        consulta: Expresión PromQL, por ejemplo 'up == 0' o 'max(pg_up)'.
    """
    try:
        r = _get(f"{PROMETHEUS}/api/v1/query", {"query": consulta})
    except Exception as e:  # la herramienta informa el error al modelo, no corta el diagnóstico
        return f"Error al consultar Prometheus: {e}"
    res = r.get("data", {}).get("result", [])
    if not res:
        return "Sin resultados (la serie no existe o no cumple la condición)."
    lineas = [f"{_serie(x['metric'])} = {x['value'][1]}" for x in res[:40]]
    if len(res) > 40:
        lineas.append(f"... y {len(res) - 40} series más")
    return _recortar("\n".join(lineas))


@beta_tool
def consultar_prometheus_historia(consulta: str, minutos: int = 60) -> str:
    """Muestra cómo evolucionó una consulta PromQL: primer valor, mínimo, máximo y último de cada serie.

    Args:
        consulta: Expresión PromQL.
        minutos: Cuántos minutos hacia atrás mirar (1 a 1440).
    """
    minutos = max(1, min(int(minutos), 1440))
    fin = time.time()
    paso = max(15, minutos * 60 // 60)
    try:
        r = _get(f"{PROMETHEUS}/api/v1/query_range",
                 {"query": consulta, "start": fin - minutos * 60, "end": fin, "step": paso})
    except Exception as e:
        return f"Error al consultar Prometheus: {e}"
    res = r.get("data", {}).get("result", [])
    if not res:
        return f"Sin datos en los últimos {minutos} min."
    lineas = []
    for x in res[:20]:
        vals = [float(v) for _, v in x["values"]]
        t0 = time.strftime("%H:%M", time.gmtime(float(x["values"][0][0])))
        lineas.append(f"{_serie(x['metric'])}: desde {t0} UTC primero={vals[0]:g} min={min(vals):g} "
                      f"max={max(vals):g} último={vals[-1]:g} ({len(vals)} puntos)")
    return _recortar("\n".join(lineas))


@beta_tool
def buscar_logs(consulta: str, minutos: int = 30, limite: int = 40) -> str:
    """Busca líneas de log en Loki con LogQL, de la más nueva a la más vieja.

    Args:
        consulta: Consulta LogQL, por ejemplo '{container="freeradius"} |= "Error"'.
        minutos: Cuántos minutos hacia atrás buscar (1 a 1440).
        limite: Máximo de líneas a devolver (1 a 100).
    """
    minutos = max(1, min(int(minutos), 1440))
    limite = max(1, min(int(limite), 100))
    fin = time.time_ns()
    try:
        r = _get(f"{LOKI}/loki/api/v1/query_range",
                 {"query": consulta, "start": fin - minutos * 60 * 10**9, "end": fin, "limit": limite,
                  "direction": "backward"})
    except Exception as e:
        return f"Error al consultar Loki: {e}"
    lineas = []
    for s in r.get("data", {}).get("result", []):
        origen = s["stream"].get("container") or s["stream"].get("unit") or s["stream"].get("topic", "")
        for ts, linea in s["values"]:
            lineas.append((int(ts), f"{time.strftime('%H:%M:%S', time.gmtime(int(ts) / 1e9))} UTC "
                                    f"[{s['stream'].get('instance', '?')}/{origen}] {linea.strip()[:300]}"))
    if not lineas:
        return f"Ninguna línea en los últimos {minutos} min."
    lineas.sort(reverse=True)
    return _recortar("\n".join(l for _, l in lineas[:limite]))


@beta_tool
def alertas_activas() -> str:
    """Lista las alertas que están sonando ahora en Alertmanager, con su resumen y su runbook."""
    try:
        with urllib.request.urlopen(f"{ALERTMANAGER}/api/v2/alerts?active=true&silenced=false&inhibited=true",
                                    timeout=20) as r:
            alertas = json.load(r)
    except Exception as e:
        return f"Error al consultar Alertmanager: {e}"
    if not alertas:
        return "No hay alertas activas."
    out = []
    for a in alertas:
        l, an = a.get("labels", {}), a.get("annotations", {})
        estado = "inhibida (otra alerta explica la causa)" if a.get("status", {}).get("inhibitedBy") else "sonando"
        out.append(f"- {l.get('alertname')} [{l.get('severity')}] {estado}, desde {a.get('startsAt', '')[:16]} UTC: "
                   f"{an.get('summary', '')}\n  runbook: {an.get('runbook', '')}")
    return _recortar("\n".join(out))


@beta_tool
def estado_del_mapa() -> str:
    """Estado de cada componente y conexión del mapa de dependencias (verde/amarillo/rojo/gris)."""
    out = []
    for metrica, clave in (("topologia_nodo", "id"), ("topologia_conexion", "id")):
        try:
            r = _get(f"{PROMETHEUS}/api/v1/query", {"query": metrica})
        except Exception as e:
            return f"Error al consultar Prometheus: {e}"
        for x in sorted(r["data"]["result"], key=lambda x: x["metric"].get(clave, "")):
            m = x["metric"]
            valor = x["value"][1]
            valor = "" if valor == "NaN" else f" = {float(valor):g} {m.get('secondarystat', '')}"
            out.append(f"{'nodo' if metrica == 'topologia_nodo' else 'conexión'} {m.get(clave)}: "
                       f"{m.get('detail__estado')}{valor}")
    return "\n".join(out) or "El mapa no tiene datos."


HERRAMIENTAS = [estado_del_mapa, alertas_activas, consultar_prometheus, consultar_prometheus_historia, buscar_logs]


def diagnosticar(pedido: str) -> str:
    """Corre el agente sobre un pedido (texto de la alerta o pregunta) y devuelve el diagnóstico."""
    if not os.environ.get("ANTHROPIC_API_KEY"):
        return ("Sin diagnóstico: falta ANTHROPIC_API_KEY (scripts/configurar-avisos.sh). "
                "Las alertas siguen llegando igual.")
    cliente = anthropic.Anthropic()
    try:
        runner = cliente.beta.messages.tool_runner(
            model=MODELO,
            max_tokens=16000,
            max_iterations=MAX_ITERACIONES,
            system=SISTEMA,
            tools=HERRAMIENTAS,
            output_config={"effort": "high"},
            # Si un filtro de seguridad rechazara el pedido, la API lo reintenta con otro modelo
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
            messages=[{"role": "user", "content": pedido}],
        )
        final = runner.until_done()
    except anthropic.AuthenticationError:
        return "Sin diagnóstico: la ANTHROPIC_API_KEY no es válida."
    except anthropic.RateLimitError:
        return "Sin diagnóstico: límite de uso de la API alcanzado, reintentar en unos minutos."
    except anthropic.APIStatusError as e:
        return f"Sin diagnóstico: error de la API ({e.status_code})."
    except anthropic.APIConnectionError:
        return "Sin diagnóstico: la VM grafana no llega a la API de Claude (¿salida a internet?)."
    if final.stop_reason == "refusal":
        return "Sin diagnóstico: el modelo rechazó el pedido."
    texto = "\n".join(b.text for b in final.content if b.type == "text").strip()
    if final.stop_reason == "tool_use":   # se cortó por el tope de iteraciones
        texto += "\n\n(Diagnóstico incompleto: se alcanzó el tope de consultas.)"
    return texto or "Sin diagnóstico: el modelo no devolvió texto."


if __name__ == "__main__":
    pregunta = " ".join(sys.argv[1:]) or ("Revisión general: ¿el servicio está bien? Si algo está mal, "
                                          "diagnosticalo.")
    print(diagnosticar(pregunta))
