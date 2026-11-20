#!/usr/bin/env python3
"""Exporter de Prometheus para lo que mktxp no cubre de R1.

  /radius monitor   -> SLI 1 (disponibilidad) y SLI 2 (latencia por política)
  /ppp active       -> sesiones PPPoE activas

Lee R1 por la API binaria de RouterOS (8728) con el usuario de solo lectura
"monitor", en cada scrape de Prometheus (no guarda estado propio).

Los contadores de /radius monitor son acumulados desde que arrancó R1: se
exponen como *_total (counter) y Prometheus calcula las ventanas con increase().
Si R1 se reinicia vuelven a 0; increase() lo trata como un reinicio de contador.
"""
import os
import re
import time

from librouteros import connect
from librouteros.exceptions import LibRouterosError
from prometheus_client import start_http_server
from prometheus_client.core import REGISTRY, CounterMetricFamily, GaugeMetricFamily

HOST = os.environ.get("R1_HOST", "10.10.10.1")
PORT = int(os.environ.get("R1_API_PORT", "8728"))
USER = os.environ.get("R1_API_USER", "monitor")
PASSWORD = os.environ["R1_API_PASSWORD"]
LISTEN = int(os.environ.get("LISTEN_PORT", "9437"))

# Contadores de /radius monitor (nombre en RouterOS -> nombre de la métrica)
CONTADORES = {
    "requests": "pedidos de autenticación enviados",
    "accepts": "Access-Accept recibidos",
    "rejects": "Access-Reject recibidos",
    "resends": "reenvíos (la respuesta tardó más que el timeout del NAS)",
    "timeouts": "pedidos sin respuesta tras los reintentos (servidor inalcanzable)",
    "bad-replies": "respuestas descartadas por el NAS (p. ej. shared secret distinto)",
}

UNIDADES = {"w": 604800, "d": 86400, "h": 3600, "m": 60, "s": 1, "ms": 1e-3, "us": 1e-6}


def duracion(texto):
    """'1s20ms', '20ms', '350us', '0s' -> segundos (float)."""
    total = 0.0
    for numero, unidad in re.findall(r"(\d+(?:\.\d+)?)(ms|us|w|d|h|m|s)", texto or ""):
        total += float(numero) * UNIDADES[unidad]
    return total


class R1Collector:
    def __init__(self):
        self.api = None

    def _api(self):
        if self.api is None:
            self.api = connect(host=HOST, port=PORT, username=USER, password=PASSWORD, timeout=5)
        return self.api

    def collect(self):
        inicio = time.time()
        up = GaugeMetricFamily("routeros_exporter_up", "1 si el exporter pudo leer R1 por la API")
        try:
            api = self._api()
            servidores = list(api.path("radius"))
            familias = {k: CounterMetricFamily(f"routeros_radius_{k.replace('-', '_')}",
                                               f"/radius monitor: {d}", labels=["radius"])
                        for k, d in CONTADORES.items()}
            pendientes = GaugeMetricFamily("routeros_radius_pending",
                                           "/radius monitor: pedidos esperando respuesta (saturación)",
                                           labels=["radius"])
            rtt = GaugeMetricFamily("routeros_radius_last_request_rtt_seconds",
                                    "/radius monitor: RTT del último pedido (muestra suelta, no percentil)",
                                    labels=["radius"])
            for srv in servidores:
                datos = next(iter(api("/radius/monitor", **{"numbers": srv[".id"], "once": ""})), {})
                nombre = srv.get("address", srv[".id"])
                for k, fam in familias.items():
                    fam.add_metric([nombre], float(datos.get(k, 0)))
                pendientes.add_metric([nombre], float(datos.get("pending", 0)))
                rtt.add_metric([nombre], duracion(datos.get("last-request-rtt")))
            yield from familias.values()
            yield pendientes
            yield rtt

            sesiones = GaugeMetricFamily("routeros_ppp_active_sessions",
                                         "Sesiones PPP activas por servicio y origen de la autenticación",
                                         labels=["ppp_service", "radius"])   # "service" lo usa Prometheus
            cuenta = {}
            for s in api.path("ppp", "active"):
                clave = (s.get("service", ""), "yes" if s.get("radius") else "no")
                cuenta[clave] = cuenta.get(clave, 0) + 1
            for (servicio, radius) in [("pppoe", "yes"), ("pppoe", "no")]:   # siempre presentes (0 si no hay)
                cuenta.setdefault((servicio, radius), 0)
            for (servicio, radius), n in cuenta.items():
                sesiones.add_metric([servicio, radius], n)
            yield sesiones
            up.add_metric([], 1)
        except (LibRouterosError, OSError, StopIteration) as e:
            print(f"error leyendo R1: {e!r}", flush=True)
            self.api = None          # reconectar en el próximo scrape
            up.add_metric([], 0)
        yield up
        yield GaugeMetricFamily("routeros_exporter_scrape_seconds", "Duración de la lectura de R1",
                                value=time.time() - inicio)


if __name__ == "__main__":
    REGISTRY.register(R1Collector())
    start_http_server(LISTEN)
    print(f"r1-exporter escuchando en :{LISTEN}, leyendo {USER}@{HOST}:{PORT}", flush=True)
    while True:
        time.sleep(3600)
