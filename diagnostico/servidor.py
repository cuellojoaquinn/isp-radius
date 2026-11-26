"""Recibe las alertas urgentes de Alertmanager (webhook) y les agrega un diagnóstico.

    POST /alerta   lo llama Alertmanager (receiver "page", grafana/alertmanager/alertmanager.yml)
    GET  /salud    para ver que el servicio está vivo

Por cada grupo de alertas que SUENA (no las resueltas) corre el agente en segundo plano y:
  - escribe el diagnóstico en su salida (journal -> Loki: dashboard Logs, {container="diagnostico"});
  - si Telegram está configurado (scripts/configurar-avisos.sh), lo manda al mismo chat de las alertas.
Un mismo grupo no se diagnostica dos veces en 30 min (Alertmanager repite los avisos).
"""
import html
import json
import os
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from agente import diagnosticar

SECRETOS = "/secretos"
REPETIR_CADA = 30 * 60
_ultimos: dict[str, float] = {}
_lock = threading.Lock()


def log(msg: str) -> None:
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


def _secreto(nombre: str) -> str:
    try:
        return open(os.path.join(SECRETOS, nombre)).read().strip()
    except OSError:
        return ""


def telegram(texto: str) -> None:
    token, chat = _secreto("telegram_token"), _secreto("telegram_chat_id")
    if not (token and chat):
        return
    datos = urllib.parse.urlencode({"chat_id": chat, "text": texto[:4000], "parse_mode": "HTML",
                                    "disable_web_page_preview": "true"}).encode()
    try:
        urllib.request.urlopen(f"https://api.telegram.org/bot{token}/sendMessage", datos, timeout=20)
    except Exception as e:  # no mostrar la URL: lleva el token
        log(f"Telegram: no se pudo enviar ({type(e).__name__})")


def atender(grupo: dict) -> None:
    alertas = [a for a in grupo.get("alerts", []) if a.get("status") == "firing"]
    if not alertas:
        return
    clave = grupo.get("groupKey", "")
    with _lock:
        if time.time() - _ultimos.get(clave, 0) < REPETIR_CADA:
            return
        _ultimos[clave] = time.time()
    nombres = sorted({a["labels"].get("alertname", "?") for a in alertas})
    detalle = "\n".join(f"- {a['labels'].get('alertname')}: {a.get('annotations', {}).get('summary', '')} "
                        f"(desde {a.get('startsAt', '')[:16]} UTC)" for a in alertas)
    pedido = ("Sonó una alerta urgente. Diagnosticá la causa.\n\n" + detalle +
              "\n\nRunbook de la alerta:\n" + alertas[0].get("annotations", {}).get("runbook", "(sin runbook)"))
    log(f"Diagnosticando {', '.join(nombres)}")
    inicio = time.time()
    resultado = diagnosticar(pedido)
    log(f"Diagnóstico de {', '.join(nombres)} ({time.time() - inicio:.0f} s):\n{resultado}")
    telegram(f"🤖 <b>Diagnóstico: {html.escape(', '.join(nombres))}</b>\n\n{html.escape(resultado)}")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/salud":
            ok = bool(os.environ.get("ANTHROPIC_API_KEY"))
            self._responder(200, {"vivo": True, "clave_api": ok,
                                  "telegram": bool(_secreto("telegram_token") and _secreto("telegram_chat_id"))})
        else:
            self._responder(404, {"error": "no existe"})

    def do_POST(self):
        if self.path != "/alerta":
            return self._responder(404, {"error": "no existe"})
        try:
            grupo = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        except (ValueError, json.JSONDecodeError):
            return self._responder(400, {"error": "JSON inválido"})
        # Responder enseguida: el diagnóstico tarda (Alertmanager reintenta si no contestamos)
        threading.Thread(target=atender, args=(grupo,), daemon=True).start()
        self._responder(202, {"recibido": True})

    def _responder(self, codigo: int, cuerpo: dict):
        datos = json.dumps(cuerpo).encode()
        self.send_response(codigo)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(datos)))
        self.end_headers()
        self.wfile.write(datos)

    def log_message(self, *args):  # sin una línea por cada pedido HTTP
        pass


if __name__ == "__main__":
    log(f"Agente de diagnóstico escuchando en :8080 (clave API: {'sí' if os.environ.get('ANTHROPIC_API_KEY') else 'no'}, "
        f"Telegram: {'sí' if _secreto('telegram_token') and _secreto('telegram_chat_id') else 'no'})")
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
