#!/usr/bin/env python3
"""Ejecuta comandos de RouterOS por la consola serie de un CHR en VirtualBox.

La consola serie es un socket unix local (ver scripts/crear-chr.sh): sirve para
configurar el router antes de que tenga IP, sin exponer nada en la red.

Uso:
  CHR_ADMIN_PASSWORD=... scripts/chr-console.py SOCKET < comandos.rsc
  CHR_ADMIN_PASSWORD=... scripts/chr-console.py SOCKET -c '/ip address print'

- Une las líneas que terminan en "\\" (formato de /export) y salta comentarios.
- Primer login de un CHR nuevo: admin sin contraseña; RouterOS pide definir una
  nueva y se usa CHR_ADMIN_PASSWORD.
- Entra como "admin+cte1000w": sin colores, sin detección de terminal, modo "dumb",
  para que la salida sea texto plano.
- Sale con código 1 si algún comando devolvió error ("failure:", "bad command"...).
"""
import os
import re
import select
import socket
import sys
import time

PROMPT = re.compile(rb"(\[[^\]\r\n]+@[^\]\r\n]+\]|<[^\r\n>]*) [^\r\n>]*> ?$")
OCULTAR = re.compile(r'(secret|password)="[^"]*"')
ERRORES = re.compile(r"(failure:|bad command|syntax error|expected |no such item|invalid value|ambiguous value|already have)", re.I)


class Consola:
    def __init__(self, ruta):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(ruta)
        self.buf = b""

    def enviar(self, texto):
        self.s.sendall(texto.encode() + b"\r")

    def _recibir(self, espera):
        r, _, _ = select.select([self.s], [], [], espera)
        if r:
            chunk = self.s.recv(4096)
            if not chunk:
                raise ConnectionError("se cerró la consola")
            self.buf += chunk
            return True
        return False

    def leer_hasta(self, patrones, timeout=30, silencio=0.4):
        """Lee hasta que el final del buffer coincida con algún patrón (regex bytes)
        y la consola quede callada `silencio` segundos (RouterOS redibuja el prompt
        varias veces: un prompt seguido de más texto no es el final)."""
        fin = time.time() + timeout
        while time.time() < fin:
            limpio = self.buf.rstrip(b"\x00 ")
            for i, p in enumerate(patrones):
                if re.search(p, limpio) and not self._recibir(silencio):
                    datos, self.buf = self.buf, b""
                    return i, datos.decode(errors="replace")
            self._recibir(0.3)
        raise TimeoutError(f"sin respuesta esperada; último texto: {self.buf[-300:]!r}")

    def login(self, password):
        LOGIN, PASS, LICENCIA, REPETIR, NUEVA, PROMPT_OK = (
            rb"Login: ?$", rb"Password: ?$", rb"\[Y/n\]:? ?$",
            rb"repeat new password> ?$", rb"new password> ?$", PROMPT.pattern)
        self.enviar("")
        claves = [password, ""]          # la de .env; si falla, la vacía de fábrica
        intento = 0
        while True:
            i, texto = self.leer_hasta([LOGIN, PASS, LICENCIA, REPETIR, NUEVA, PROMPT_OK], timeout=120)
            if i == 0:
                if "Login failed" in texto:
                    intento += 1
                    if intento >= len(claves):
                        raise PermissionError("no se pudo entrar con ninguna contraseña")
                self.enviar("admin+cte1000w")   # ancho grande: RouterOS recorta las líneas largas
            elif i == 1:
                self.enviar(claves[intento])
            elif i == 2:
                self.enviar("n")         # no mostrar la licencia
            elif i in (3, 4):
                self.enviar(password)    # primer login: definir la contraseña de admin
            elif i == 5:
                return

    def comando(self, linea, timeout=60):
        self.enviar(linea)
        eco = re.escape(linea[-40:].encode())
        fin = time.time() + timeout
        while not re.search(eco, self.buf) and time.time() < fin:   # esperar el eco
            self._recibir(0.3)
        _, salida = self.leer_hasta([PROMPT.pattern], timeout=max(1, fin - time.time()))
        # la salida es lo que viene después del último eco del comando
        salida = salida.split(linea[-40:], 1)[-1] if linea[-40:] in salida else salida
        lineas = [PROMPT.sub(b"", l.encode()).decode().strip() for l in salida.replace("\r", "\n").split("\n")]
        return "\n".join(l for l in lineas if l and not re.fullmatch(r"\[[^\]]+\] [^>]*>.*", l))


def logicas(texto):
    """Une continuaciones '\\' y descarta comentarios y líneas vacías."""
    actual = ""
    for crudo in texto.splitlines():
        l = crudo.rstrip()
        if not actual and (not l.strip() or l.lstrip().startswith("#")):
            continue
        if l.endswith("\\"):
            actual += l[:-1]
            continue
        actual += l.lstrip() if actual else l
        yield actual.strip()
        actual = ""
    if actual:
        yield actual.strip()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    ruta = sys.argv[1]
    texto = sys.argv[3] if len(sys.argv) > 3 and sys.argv[2] == "-c" else sys.stdin.read()
    password = os.environ.get("CHR_ADMIN_PASSWORD")
    if not password:
        sys.exit("Falta CHR_ADMIN_PASSWORD")

    c = Consola(ruta)
    c.login(password)
    fallas = 0
    for linea in logicas(texto):
        salida = c.comando(linea)
        # nunca mostrar secretos (un print detail los muestra en claro)
        print(OCULTAR.sub(r'\1="***"', f"> {linea}"))
        if salida:
            print(OCULTAR.sub(r'\1="***"', salida))
        if ERRORES.search(salida):
            fallas += 1
            print("  ^^^ ERROR", file=sys.stderr)
    c.enviar("/quit")
    sys.exit(1 if fallas else 0)


if __name__ == "__main__":
    main()
