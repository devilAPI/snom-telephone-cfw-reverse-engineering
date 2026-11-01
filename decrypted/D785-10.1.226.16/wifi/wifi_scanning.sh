#!/bin/bash

DEVICE=$1
if [ -z "$1" ]; then
 DEVICE="ra0"
fi

if [ "$#" -eq  "2" ]
  then SECOND_ARG=$2
fi

if [[ $SECOND_ARG == 'load_wifi_modules' ]]; then
    /sbin/insmod /wifi/rt5572sta.ko
    /sbin/insmod /wifi/mt7601Usta.ko
    /sbin/insmod /wifi/8192eu.ko
    /sbin/insmod /wifi/8192cu.ko
    /sbin/insmod /wifi/8821cu.ko
fi

/sbin/ifconfig $DEVICE up
/sbin/iwlist $DEVICE scanning > /tmp/wifiscan
/bin/cat /tmp/wifiscan | grep ESSID | cut -d ':' -f 2 | cut -d '"' -f 2 > /tmp/wifiessid
/bin/cat /tmp/wifiscan | grep Mode > /tmp/wifimode
/bin/cat /tmp/wifiscan | grep Encryption > /tmp/wifienc
/bin/cat /tmp/wifiscan | grep Channel > /tmp/wifichan
/bin/cat /tmp/wifiscan | grep ESSID > /tmp/wifissid
/usr/bin/paste /tmp/wifiessid /tmp/wifichan > /tmp/wifinet
echo -n "completed" > /tmp/wifi_scan_status_info
/bin/sync
/bin/sync
/bin/sync
