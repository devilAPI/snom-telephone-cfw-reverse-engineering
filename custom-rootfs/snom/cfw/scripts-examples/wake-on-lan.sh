#!/bin/sh
# Example: wake-on-LAN. Edit MAC (aa:bb:cc:dd:ee:ff) and optionally BCAST.
MAC="aa:bb:cc:dd:ee:ff"
BCAST="255.255.255.255"
if busybox ether-wake -h >/dev/null 2>&1 || busybox --list | grep -qx ether-wake; then
    ether-wake "$MAC" && echo "ether-wake sent to $MAC" && exit 0
fi
# fallback: magic packet = 6x FF + 16x MAC, via nc -u
hex=$(echo "$MAC" | tr -d ':-')
payload='\xff\xff\xff\xff\xff\xff'
m=$(echo "$hex" | sed 's/../\\x&/g')
i=0; while [ $i -lt 16 ]; do payload="$payload$m"; i=$((i+1)); done
printf "$payload" | nc -u -w1 "$BCAST" 9 && echo "magic packet sent to $MAC via nc"
