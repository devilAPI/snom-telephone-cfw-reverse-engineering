# zip.sh - zipped ROM/WAD support shared by the four launchers (nes, gb/gba via
# retro-boot.sh, doom). Source it:  . /snom/cfw/lib/zip.sh      See docs/zip.md.
#
# The phone's busybox has no unzip, so /snom/cfw/bin/unzip (busybox, unzip
# applet only, static) does the work. A download is a zip if it starts with the
# magic bytes PK\003\004 -- never judged by the URL.
#
#   zip_is_zip FILE
#   zip_extract SYS FILE ERE URL   unpack FILE (deleted afterwards) into
#         /tmp/zip-SYS/x, list the files whose name matches ERE (case
#         insensitive, e.g. 'gbc?'), subfolders included, __MACOSX/ and "._"
#         files ignored. Returns 0 = exactly one: ZIP_ROM is its path,
#         1 = error: ZIP_ERR says why, 2 = several: stored for a later choice
#         (ZIP_SID, ZIP_N); the list is /tmp/zip-SYS/list, one relative path
#         per line, in the order the user sees.
#   zip_pick SYS SID IDX           pick entry number IDX (1-based) of the
#         stored list. SID and IDX are untrusted (they come from a browser): the
#         path is NEVER taken from the client, only looked up by index in our
#         own list. Sets ZIP_ROM, ZIP_URL; returns 1 + ZIP_ERR on bad input.
#   zip_clear SYS                  forget any stored choice (frees the RAM)
#   zip_ext SYS                    the extension regex for SYS
#   zip_wait SYS SECONDS           (CGIs) wait for the launcher's verdict in
#                                  /tmp/SYS.status: error*|running|done|choose*
ZIPBIN=/snom/cfw/bin/unzip

zip_ext() {
    case "$1" in
        nes) echo nes ;;
        gb)  echo 'gbc?' ;;
        gba) echo gba ;;
        doom) echo wad ;;
    esac
}

zip_is_zip() { [ "$(dd if="$1" bs=4 count=1 2>/dev/null)" = "$(printf 'PK\003\004')" ]; }

zip_clear() { rm -rf "/tmp/zip-$1"; }

zip_extract() {
    _s=$1; _f=$2; _re=$3; _u=$4
    ZIP_ERR=; ZIP_ROM=; ZIP_N=0; ZIP_SID=
    _d=/tmp/zip-$_s
    zip_clear "$_s"
    [ -x "$ZIPBIN" ] || { ZIP_ERR="unzip tool $ZIPBIN is missing"; rm -f "$_f"; return 1; }
    # Space check: the zip itself is still in /tmp while we unpack.
    _need=$("$ZIPBIN" -l "$_f" 2>/dev/null | tail -n 1 | awk '{print int(($1 + 1023) / 1024)}')
    _free=$(df -k /tmp | awk 'NR==2 {print $4}')
    case "$_need" in ''|*[!0-9]*) ZIP_ERR="the zip is damaged (cannot read its file list)"; rm -f "$_f"; return 1 ;; esac
    if [ "$_need" -gt "$_free" ]; then
        ZIP_ERR="the zip unpacks to ${_need} KB but only ${_free} KB of RAM disk are free"
        rm -f "$_f"; return 1
    fi
    mkdir -p "$_d/x"
    if ! "$ZIPBIN" -qo "$_f" -d "$_d/x" -x '__MACOSX/*' >>"${LOG:-/dev/null}" 2>&1; then
        ZIP_ERR="could not unzip the file (damaged or encrypted zip, or RAM disk full)"
        rm -f "$_f"; zip_clear "$_s"; return 1
    fi
    rm -f "$_f"
    ( cd "$_d/x" && find . -type f 2>/dev/null ) | sed 's|^\./||' |
        grep -iE "\\.($_re)\$" | grep -vE '(^|/)\._|(^|/)__MACOSX/' | sort > "$_d/list"
    ZIP_N=$(wc -l < "$_d/list")
    if [ "$ZIP_N" -eq 0 ]; then
        ZIP_ERR="no .$(echo "$_re" | sed 's/c?/[c]/') file inside the zip"
        zip_clear "$_s"; return 1
    fi
    if [ "$ZIP_N" -eq 1 ]; then
        ZIP_ROM="$_d/x/$(head -n 1 "$_d/list")"
        return 0
    fi
    ZIP_SID="$(date +%s)-$$"
    echo "$ZIP_SID" > "$_d/sid"
    printf '%s\n' "$_u" > "$_d/url"
    return 2
}

zip_pick() {
    _s=$1; _sid=$2; _i=$3
    ZIP_ERR=; ZIP_ROM=; ZIP_URL=
    _d=/tmp/zip-$_s
    case "$_s" in nes|gb|gba|doom) ;; *) ZIP_ERR="unknown system"; return 1 ;; esac
    [ -f "$_d/sid" ] || { ZIP_ERR="no zip is waiting for a choice (download it again)"; return 1; }
    case "$_sid" in ''|*[!0-9-]*) ZIP_ERR="bad session id"; return 1 ;; esac
    [ "$_sid" = "$(cat "$_d/sid")" ] || { ZIP_ERR="stale session (the list was replaced by a newer download)"; return 1; }
    case "$_i" in ''|*[!0-9]*) ZIP_ERR="bad file number"; return 1 ;; esac
    _n=$(wc -l < "$_d/list")
    if [ "$_i" -lt 1 ] || [ "$_i" -gt "$_n" ]; then ZIP_ERR="file number out of range (1-$_n)"; return 1; fi
    _rel=$(sed -n "${_i}p" "$_d/list")
    ZIP_ROM="$_d/x/$_rel"
    [ -f "$ZIP_ROM" ] && [ ! -L "$ZIP_ROM" ] || { ZIP_ERR="file vanished"; ZIP_ROM=; return 1; }
    ZIP_URL=$(cat "$_d/url" 2>/dev/null)
    return 0
}

zip_wait() {
    _i=0; st=
    while [ "$_i" -lt "$2" ]; do
        sleep 1; _i=$((_i + 1))
        st=$(cat "/tmp/$1.status" 2>/dev/null)
        case "$st" in error*|running|done|choose*) break ;; esac
    done
}
