#!/bin/bash
#/sbin/insmod /wifi/rt2070sta.o 2> /dev/zero
DEVICE=$1
if [ -z "$1" ]; then
 DEVICE="ra0"
fi
/sbin/ifconfig $DEVICE up
/sbin/iwlist $DEVICE scanning > /tmp/wifiscan
/bin/cat /tmp/wifiscan | grep ESSID | cut -d ':' -f 2 | cut -d '"' -f 2 > /tmp/wifiessid
/bin/cat /tmp/wifiscan | grep Mode > /tmp/wifimode
/bin/cat /tmp/wifiscan | grep Encryption > /tmp/wifienc
/bin/cat /tmp/wifiscan | grep Channel > /tmp/wifichan
/bin/cat /tmp/wifiscan | grep ESSID > /tmp/wifissid
/usr/bin/paste /tmp/wifiessid /tmp/wifichan > /tmp/wifinet
/usr/bin/paste /tmp/wifissid /tmp/wifichan /tmp/wifimode /tmp/wifienc > /tmp/wifiinfo
/bin/sync
/bin/sync
/bin/sync
