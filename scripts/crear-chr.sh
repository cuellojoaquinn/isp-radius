#!/bin/bash
# Crea un MikroTik CHR del laboratorio en VirtualBox (R1 o R2).
# No hay boxes de CHR prácticas para Vagrant: por eso es un script aparte.
#
#   r1  NAS / servidor PPPoE (VM isp-radius_r1)
#       NIC1 -> intnet "gestion"  (ether1, 10.10.10.1)
#       NIC2 -> intnet "acceso"   (default-name ether2; r1.rsc lo renombra a ether3 -> vlan-acceso)
#       NIC3 -> intnet "lan1"     (default-name ether3; r1.rsc lo renombra a ether2 -> LAN1)
#
#   r2  abonado1, cliente PPPoE (VM isp-radius_r2)
#       NIC1 -> desconectada      (ether1: en UTM salía a internet por dhcp-client; acá
#                                  daría una segunda ruta por defecto que compite con PPPoE)
#       NIC2 -> intnet "acceso"   (default-name ether2; r2-abonado1.rsc lo renombra a ether3)
#       Solo 2 NICs: con una tercera, el rename a ether3 choca con el nombre existente.
#
#   Consola serie en un socket unix local (sin red): la usa scripts/chr-console.py
#
# Uso:  scripts/crear-chr.sh r1|r2
# Después: scripts/configurar-chr.sh r1|r2
set -euo pipefail

ROL=${1:?Uso: $0 r1|r2}
VERSION=7.20.4                       # la misma versión que los exports de mikrotik/
VM="isp-radius_$ROL"
DIR="$HOME/VirtualBox VMs/$VM"
CACHE="$HOME/.cache/isp-radius"
ZIP="$CACHE/chr-$VERSION.vdi.zip"

case "$ROL" in
  r1) NICS=(--nic1 intnet --intnet1 gestion --nic2 intnet --intnet2 acceso --nic3 intnet --intnet3 lan1) ;;
  r2) NICS=(--nic1 null --nic2 intnet --intnet2 acceso) ;;
  *)  echo "Rol desconocido: $ROL (r1 o r2)"; exit 2 ;;
esac

if VBoxManage showvminfo "$VM" >/dev/null 2>&1; then
  echo "La VM $VM ya existe. Para recrearla: VBoxManage unregistervm $VM --delete"; exit 1
fi

mkdir -p "$CACHE" "$DIR"
if [ ! -f "$ZIP" ]; then
  echo "Bajando CHR $VERSION..."
  curl -fSL -o "$ZIP.tmp" "https://download.mikrotik.com/routeros/$VERSION/chr-$VERSION.vdi.zip"
  mv "$ZIP.tmp" "$ZIP"
fi
unzip -o -q "$ZIP" -d "$DIR"
DISK="$DIR/chr-$VERSION.vdi"
VBoxManage internalcommands sethduuid "$DISK" >/dev/null   # UUID propio: todos los CHR salen de la misma imagen

VBoxManage createvm --name "$VM" --ostype Linux_64 --register --basefolder "$HOME/VirtualBox VMs" >/dev/null
VBoxManage modifyvm "$VM" --memory 256 --cpus 1 --boot1 disk --boot2 none --boot3 none --audio-enabled off \
  "${NICS[@]}" --uart1 0x3F8 4 --uart-mode1 server "$DIR/consola.sock"
VBoxManage storagectl "$VM" --name SATA --add sata --controller IntelAhci --portcount 1
VBoxManage storageattach "$VM" --storagectl SATA --port 0 --device 0 --type hdd --medium "$DISK"

VBoxManage startvm "$VM" --type headless
echo "$VM creado y arrancando. Consola serie: $DIR/consola.sock"
