#!/bin/bash
# Provisión común a todas las VMs: DNS fijo y Docker.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# DNS persistente (lección de la bitácora: el DHCP pisaba /etc/resolv.conf)
if ! grep -q '^supersede domain-name-servers' /etc/dhcp/dhclient.conf; then
  echo 'supersede domain-name-servers 8.8.8.8, 1.1.1.1;' >> /etc/dhcp/dhclient.conf
fi
echo "nameserver 8.8.8.8" > /etc/resolv.conf

apt-get update -q
apt-get install -y -q docker.io docker-compose postgresql-client freeradius-utils
usermod -aG docker vagrant

# Logs: Docker escribe los logs de los contenedores en el journal (Alloy los lee de
# ahí, ver alloy/journal.alloy). `docker logs` sigue funcionando igual.
# El log driver se fija al crear el contenedor: los ya creados necesitan
# `docker-compose up -d --force-recreate` una vez.
mkdir -p /etc/docker /etc/systemd/journald.conf.d
cambio_docker=0; cambio_journal=0
DAEMON='{
  "log-driver": "journald",
  "log-opts": { "tag": "{{.Name}}", "labels": "com.docker.compose.service" }
}'
if [ "$(cat /etc/docker/daemon.json 2>/dev/null)" != "$DAEMON" ]; then
  echo "$DAEMON" > /etc/docker/daemon.json; cambio_docker=1
fi

# Journal persistente y acotado: 500 MB o 14 días (igual que la retención de Loki).
# Si Loki está caído, los logs esperan acá.
JOURNAL='[Journal]
Storage=persistent
SystemMaxUse=500M
MaxRetentionSec=14day'
if [ "$(cat /etc/systemd/journald.conf.d/isp-radius.conf 2>/dev/null)" != "$JOURNAL" ]; then
  echo "$JOURNAL" > /etc/systemd/journald.conf.d/isp-radius.conf; cambio_journal=1
fi
[ "$cambio_journal" = 1 ] && systemctl restart systemd-journald
[ "$cambio_docker" = 1 ] && systemctl restart docker
true
