#!/bin/sh
# Arranque de Alertmanager: arma la configuración efectiva antes de iniciarlo.
# Si están los dos secretos de Telegram (scripts/configurar-avisos.sh), descomenta las
# líneas "#TG " de alertmanager.yml y pone el chat; si no, la usa tal cual (sin Telegram).
set -e
SRC=/etc/alertmanager/alertmanager.yml
DST=/alertmanager/config-efectiva.yml
S=/etc/alertmanager/secretos
if [ -s "$S/telegram_token" ] && [ -s "$S/telegram_chat_id" ]; then
  CHAT=$(tr -dc '0-9-' < "$S/telegram_chat_id")
  sed -e 's/^#TG //' -e "s/__TELEGRAM_CHAT_ID__/$CHAT/" "$SRC" > "$DST"
  echo "arrancar.sh: Telegram activado"
else
  cp "$SRC" "$DST"
  echo "arrancar.sh: Telegram sin configurar (faltan $S/telegram_token y telegram_chat_id)"
fi
exec /bin/alertmanager --config.file="$DST" --storage.path=/alertmanager "$@"
