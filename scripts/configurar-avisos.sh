#!/bin/bash
# Configura los avisos: Telegram (alertas) y la clave del agente de diagnóstico.
# Lo corre una persona: pide los secretos sin mostrarlos y los guarda en archivos que
# no se suben al repo. Se puede correr de nuevo para cambiar cualquiera de los dos.
#
#   Telegram:  grafana/alertmanager/secretos/telegram_token y telegram_chat_id
#   Agente:    ANTHROPIC_API_KEY en grafana/.env
#
# Antes, para Telegram: en la app, hablarle a @BotFather -> /newbot -> copiar el token.
# Uso: scripts/configurar-avisos.sh
set -euo pipefail
cd "$(dirname "$0")/.."
SEC=grafana/alertmanager/secretos
mkdir -p "$SEC"; chmod 700 "$SEC"

echo "== Telegram (Enter para dejarlo como está)"
read -rsp "Token del bot (de @BotFather): " TOKEN; echo
if [ -n "$TOKEN" ]; then
  umask 077; printf '%s' "$TOKEN" > "$SEC/telegram_token"
  echo "Ahora mandale cualquier mensaje a tu bot desde Telegram (o agregalo a un grupo y escribí algo)."
  read -rp "Cuando lo hayas mandado, apretá Enter... " _
  CHAT=$(curl -fsS "https://api.telegram.org/bot$TOKEN/getUpdates" | python3 -c '
import json, sys
r = json.load(sys.stdin).get("result", [])
ids = [u[k]["chat"]["id"] for u in r for k in ("message", "channel_post", "my_chat_member") if k in u]
print(ids[-1] if ids else "")')
  if [ -z "$CHAT" ]; then echo "No encontré el mensaje: mandale uno al bot y corré el script de nuevo."; exit 1; fi
  printf '%s' "$CHAT" > "$SEC/telegram_chat_id"
  curl -fsS -o /dev/null "https://api.telegram.org/bot$TOKEN/sendMessage" \
       --data-urlencode "chat_id=$CHAT" --data-urlencode "text=✅ isp-radius: Telegram configurado. Acá van a llegar las alertas."
  echo "Telegram listo (chat $CHAT): te mandé un mensaje de prueba."
fi

echo "== Agente de diagnóstico (Enter para dejarlo como está)"
read -rsp "ANTHROPIC_API_KEY: " KEY; echo
if [ -n "$KEY" ]; then
  touch grafana/.env; chmod 600 grafana/.env
  grep -v '^ANTHROPIC_API_KEY=' grafana/.env > grafana/.env.tmp || true
  printf 'ANTHROPIC_API_KEY=%s\n' "$KEY" >> grafana/.env.tmp && mv grafana/.env.tmp grafana/.env
  echo "Clave guardada en grafana/.env."
fi

echo "== Reiniciando Alertmanager y el agente en la VM grafana"
vagrant ssh grafana -c 'cd /vagrant/grafana && docker-compose up -d --build diagnostico >/dev/null && docker restart alertmanager >/dev/null && docker logs alertmanager 2>&1 | grep arrancar.sh | tail -1 && sleep 3 && docker exec diagnostico python -c "import urllib.request; print(urllib.request.urlopen(\"http://localhost:8080/salud\").read().decode())"'
