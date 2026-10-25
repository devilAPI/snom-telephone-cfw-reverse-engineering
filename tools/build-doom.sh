#!/bin/bash
# Cross-build doomgeneric (snom D375 fb/evdev port) as a static musl armv6 binary.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq gcc make wget xz-utils ca-certificates file >/dev/null

cd /opt
wget -q https://musl.cc/arm-linux-musleabi-cross.tgz
tar xf arm-linux-musleabi-cross.tgz
export PATH=/opt/arm-linux-musleabi-cross/bin:$PATH
CC=arm-linux-musleabi-gcc

cd /src/doomgeneric/doomgeneric
# Doom source objects (same list as upstream Makefile) + our platform file.
SRC="dummy.o am_map.o doomdef.o doomstat.o dstrings.o d_event.o d_items.o d_iwad.o \
d_loop.o d_main.o d_mode.o d_net.o f_finale.o f_wipe.o g_game.o hu_lib.o hu_stuff.o \
info.o i_cdmus.o i_endoom.o i_joystick.o i_scale.o i_sound.o i_system.o i_timer.o \
memio.o m_argv.o m_bbox.o m_cheat.o m_config.o m_controls.o m_fixed.o m_menu.o \
m_misc.o m_random.o p_ceilng.o p_doors.o p_enemy.o p_floor.o p_inter.o p_lights.o \
p_map.o p_maputl.o p_mobj.o p_plats.o p_pspr.o p_saveg.o p_setup.o p_sight.o p_spec.o \
p_switch.o p_telept.o p_tick.o p_user.o r_bsp.o r_data.o r_draw.o r_main.o r_plane.o \
r_segs.o r_sky.o r_things.o sha1.o sounds.o statdump.o st_lib.o st_stuff.o s_sound.o \
tables.o v_video.o wi_stuff.o w_checksum.o w_file.o w_main.o w_wad.o z_zone.o \
w_file_stdc.o i_input.o i_video.o doomgeneric.o doomgeneric_snom.o"

mkdir -p build
CFLAGS="-Os -march=armv4t -DNORMALUNIX -DLINUX -DSNDSERV -D_DEFAULT_SOURCE \
 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200 -Wno-implicit-function-declaration"
for o in $SRC; do
  $CC $CFLAGS -c "${o%.o}.c" -o "build/$o"
done
$CC $CFLAGS -static -Wl,--gc-sections $(printf 'build/%s ' $SRC) -o /out/doom -lm
arm-linux-musleabi-strip /out/doom
file /out/doom; ls -la /out/doom
arm-linux-musleabi-readelf -d /out/doom 2>/dev/null | grep -i needed || echo "OK: fully static"
