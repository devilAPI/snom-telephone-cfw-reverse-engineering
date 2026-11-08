#!/bin/sh

# bail out on errors
set -e

# check if CSS loaded
if [ -d /sys/bus/platform/devices/8200000.css ]
then
	STATE=`cat /sys/bus/platform/devices/8200000.css/state`
else
	echo "CSS device not available"
	exit 1
fi

if [ "$STATE" != "loaded" -a "$STATE" != "panic" ]
then
	echo "CSS neither loaded nor in panic mode"
	exit 1
fi

if [ "$STATE" != "panic" ]
then
	echo 1 > /sys/bus/platform/devices/8200000.css/panic
	sleep 1
	STATE=`cat /sys/bus/platform/devices/8200000.css/state`
fi

if [ "$STATE" != "panic" ]
then
	echo "CSS not in panic mode, memory dump will be incomplete"
fi

# check if debugfs is mounted
if [ -e /sys/kernel/debug/css/itcm ]
then
	echo "debugfs already mounted..."
else
	echo "mounting debugfs..."
	mount -t debugfs none /sys/kernel/debug
fi

TMPDIR=`mktemp -d`
DUMPDIR="$TMPDIR/ramdump"
mkdir "$DUMPDIR"

echo "dumping all CSS memories..."
cat /sys/kernel/debug/css/ahb-ram > "$DUMPDIR/ahb-ram"
cat /sys/kernel/debug/css/dram > "$DUMPDIR/dram"
cat /sys/kernel/debug/css/dtcm > "$DUMPDIR/dtcm"
cat /sys/kernel/debug/css/itcm > "$DUMPDIR/itcm"
echo "dumping shared memory..."
#cat /sys/kernel/debug/sharedmem/memory > "$DUMPDIR/sharedmem"
uname -a > "$DUMPDIR/release.txt"
dmesg > "$DUMPDIR/dmesg.txt"
cp /lib/firmware/css-loader "$DUMPDIR/css-loader"

echo "packing ramdump image..."
tar cf css-ramdump.tar.tar -C "$TMPDIR" ramdump/
echo "
created CSS ramdump...
=============================================
 send css-ramdump.tar.gz to customer support
 with information about your last actions
 just before the crash
============================================="

rm -rf "$TMPDIR"
