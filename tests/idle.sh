#!/bin/bash
# Task B test: idle widgets. Deploys CGIs, applies clock+stats+picture, screenshots, restores stock.
. "$(dirname "$0")/lib.sh"
C=$REPO/rootfs/d375/snom
OUT=${OUT:-/tmp/idle-test}; mkdir -p $OUT
shot() { curl -s -m 10 http://$PHONE_IP:8080/cgi-bin/screenshot > $OUT/$1.bmp
         python3 -c "from PIL import Image; Image.open('$OUT/$1.bmp').save('$OUT/$1.png')"; }
wait_ui() { sleep 10; for i in $(seq 1 60); do
    [ -n "$(ph "ps | awk '/[l]csD375/'")" ] && curl -s -m 5 -o /dev/null http://$PHONE_IP:8080/ && { sleep 25; return; }
    sleep 3; done; }
python3 -c "
from PIL import Image,ImageDraw
im=Image.new('RGB',(120,60),(200,30,30)); ImageDraw.Draw(im).ellipse((40,10,80,50),fill=(255,255,0)); im.save('$OUT/pic.png')"
run() {
    for f in cgi-bin/idle cgi-bin/idle-widget lib/cfw.sh; do ph_put $C/cfw/$f /snom/cfw/$f; done
    ph "mkdir -p /snom/cfw-data/idle"; ph_put $OUT/pic.png /snom/cfw-data/idle/picture.png
    ph_put $C/html/xml/gui/state_idle.xml.orig /snom/html/xml/gui/state_idle.xml.orig
    W=$(ph /snom/cfw/cgi-bin/idle-widget); echo "widget: $W"
    assert_contains "$W" "load" "idle-widget prints stats"
    curl -s -m 20 -d 'action=apply&clock=on&stats=on&picture=on' http://$PHONE_IP:8080/cgi-bin/idle >/dev/null
    assert_contains "$(ph 'cat /snom/cfw-data/idle/config')" "clock=on" "config written"
    wait_ui; shot widgets
    assert_contains "$(ph 'cat /snom/html/xml/gui/state_idle.xml')" 'cfw-idle.png' "xml has picture"
    curl -s -m 20 -d 'action=restore' http://$PHONE_IP:8080/cgi-bin/idle >/dev/null
    assert_eq "$(md5sum < $C/html/xml/gui/state_idle.xml.orig)" "$(ph 'md5sum < /snom/html/xml/gui/state_idle.xml')" "stock restored"
    wait_ui; shot stock
}
trap 'ph "cp /snom/html/xml/gui/state_idle.xml.orig /snom/html/xml/gui/state_idle.xml" 2>/dev/null' EXIT
with_phone_lock run
echo "inspect $OUT/widgets.png and $OUT/stock.png"
