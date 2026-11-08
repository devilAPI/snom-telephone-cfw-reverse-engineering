#!/usr/bin/env bash
# Cross-build tinyalsa's tools (tinymix, tinyplay, tinycap, tinypcminfo). Output:
# out/tiny*. Discovery tools only; the games use halaudio. Needs docker.
# See docs/sound.md.
. "$(dirname "$0")/lib.sh"
musl_run '
git clone --depth 1 https://github.com/tinyalsa/tinyalsa.git /src >/dev/null 2>&1
cd /src
F="-O2 -march=armv4t -fomit-frame-pointer -Iinclude"
for c in src/*.c; do $X-gcc $F -c "$c" -o "$(basename "${c%.c}").o"; done
for t in tinymix tinyplay tinycap tinypcminfo; do
    s=utils/$t.c; [ -f "$s" ] || s=$t.c
    $X-gcc $F -static -Wl,--gc-sections "$s" *.o -o /out/$t -lm -ldl 2>/dev/null \
        || $X-gcc $F -static -Wl,--gc-sections "$s" *.o -o /out/$t -lm
    $X-strip /out/$t
done
file /out/tinymix'
