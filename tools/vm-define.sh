#!/usr/bin/env bash
# Register the phones as libvirt VMs (user session), for virt-manager.
#
#   tools/vm-define.sh [d375] [d815]        default: both
#
# In virt-manager: File > Add Connection > "QEMU/KVM user session".
# The VMs boot the fixed paths in emu/vm/, which tools/vm-update.sh refreshes.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONN=qemu:///session
[ $# -gt 0 ] || set -- d375 d815

for MODEL in "$@"; do
    VM="$ROOT/emu/vm/$MODEL"
    RUN="$ROOT/emu/run/$MODEL"
    [ -f "$VM/nand.img" ] || "$ROOT/tools/vm-update.sh" "$MODEL"
    mkdir -p "$RUN"
    source "$ROOT/tools/qemu-args.sh"
    case "$MODEL" in
        d375) MEM=256 VNC=5975 KERNEL=$VM/uImage DTB= ;;
        d815) MEM=512 VNC=5976 KERNEL=$VM/zImage DTB="<dtb>$VM/phone.dtb</dtb>" ;;
    esac
    # Keep the UUID so that running this again updates the existing VM.
    UUID=$(virsh -c "$CONN" domuuid "snom-$MODEL" 2>/dev/null | head -1 || true)
    xml=$(mktemp)
    cat > "$xml" <<XML
<domain type='qemu' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>snom-$MODEL</name>
  ${UUID:+<uuid>$UUID</uuid>}
  <title>snom ${MODEL^^} CFW</title>
  <description>Boots emu/vm/$MODEL; refresh with tools/vm-update.sh $MODEL</description>
  <memory unit='MiB'>$MEM</memory>
  <vcpu>1</vcpu>
  <os>
    <type arch='armv7l' machine='snom-$MODEL'>hvm</type>
    <kernel>$KERNEL</kernel>
    <cmdline>$CMDLINE</cmdline>
    $DTB
  </os>
  <on_reboot>restart</on_reboot>
  <devices>
    <emulator>$ROOT/emu/build/qemu-system-arm</emulator>
    <graphics type='vnc' port='$VNC' autoport='no' listen='127.0.0.1'/>
    <video><model type='none'/></video>
    <memballoon model='none'/>
  </devices>
  <qemu:commandline>
    <qemu:arg value='-drive'/>
    <qemu:arg value='if=mtd,format=raw,file=$VM/nand.img'/>
    <qemu:arg value='-nic'/>
    <qemu:arg value='$NIC'/>
    <qemu:arg value='-serial'/>
    <qemu:arg value='file:$RUN/console.log'/>
    <qemu:arg value='-serial'/>
    <qemu:arg value='unix:$RUN/shell.sock,server=on,wait=off'/>
  </qemu:commandline>
</domain>
XML
    virsh -c "$CONN" define "$xml"
    rm -f "$xml"
done
