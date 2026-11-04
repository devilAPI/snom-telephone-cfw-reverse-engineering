# CFW: load / unload the stock amxr_user_hook.ko for micstream (intercom.sh) and
# spkstream (speaker.sh). Sourced. Both use the module at the same time, so it is
# unloaded only when the CFW loaded it and no amxruser port has a connection left.
AMXR_KO=/lib/modules/2.6.27.47/BROADCOM/amxr_user_hook.ko
AMXR_FLAG=/tmp/cfw-amxr-ko-loaded

# amxr_mod_load LOGFILE: 0 when the module is there
amxr_mod_load() {
    [ -c /dev/amxruser ] || mknod /dev/amxruser c 236 0
    grep -q '^amxr_user_hook ' /proc/modules 2>/dev/null && return 0
    insmod "$AMXR_KO" >>"$1" 2>&1 || return 1
    touch "$AMXR_FLAG"
}

amxr_mod_unload() {
    [ -f "$AMXR_FLAG" ] || return 0
    grep -q '^amxr_user_hook ' /proc/modules 2>/dev/null || { rm -f "$AMXR_FLAG"; return 0; }
    pidof micstream spkstream >/dev/null 2>&1 && return 0
    grep -q 'amxruser.*cnxs=[1-9]' /proc/amxr 2>/dev/null && return 0
    rm -f "$AMXR_FLAG"
    rmmod amxr_user_hook 2>/dev/null && return 0
    sleep 1
    rmmod amxr_user_hook
}
