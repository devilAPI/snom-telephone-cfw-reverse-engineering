# Sourced: the per-model QEMU settings shared by qemu-run.sh and vm-define.sh.
# Needs MODEL and VM; sets MACHINE_ARGS, NIC, CMDLINE, GUEST_IP, PORT_BASE.
case "$MODEL" in
d375)
    MAC=00:04:13:00:03:75 GUEST_IP=192.0.2.77 PORT_SSH=12222 PORT_CFW=18080 PORT_WEB=18081
    MACHINE_ARGS=(-M snom-d375 -kernel "$VM/uImage")
    NICMODEL=snom-dma
    CMDLINE="console=ttyAMA0,115200n8 root=/dev/mtdblock7 rw rootfstype=jffs2 noinitrd"
    CMDLINE+=" ethaddr=$MAC bootmemheap=1M mtdparts=bcm_umi-nand:0x000a0000(bootloader),0x000e0000(uboot),0x00080000(ubootenv),0x00400000(rescuekernel),0x00800000(rescuefs),0x000c0000(data),0x00400000(kernel),0x06d40000(rootfs)"
    ;;
d815)
    MAC=00:04:13:00:08:15 GUEST_IP=192.0.2.78 PORT_SSH=13222 PORT_CFW=19080 PORT_WEB=19081
    MACHINE_ARGS=(-M snom-d815 -kernel "$VM/zImage" -dtb "$VM/phone.dtb")
    NICMODEL=npcm-gmac
    CMDLINE="console=ttyS0,115200n8 ubi.mtd=0 root=ubi0:rootfs1 rootfstype=ubifs ro"
    ;;
esac
NIC="user,model=$NICMODEL,mac=$MAC,net=192.0.2.0/24,host=192.0.2.2,dns=192.0.2.3,dhcpstart=$GUEST_IP"
NIC+=",hostfwd=tcp:127.0.0.1:$PORT_SSH-$GUEST_IP:22"
NIC+=",hostfwd=tcp:127.0.0.1:$PORT_CFW-$GUEST_IP:8080"
NIC+=",hostfwd=tcp:127.0.0.1:$PORT_WEB-$GUEST_IP:80"
