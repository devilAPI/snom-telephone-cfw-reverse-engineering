/* keyinject: press phone keys by writing evdev events into /dev/input/event0.
 *
 *   keyinject NAME [NAME...]     press+release each key (names: see table below)
 *   keyinject -d MS NAME         hold time in ms (default 60)
 *   keyinject -c CODE            raw evdev scancode (0..255)
 *   keyinject -l                 list "NAME CODE" lines
 *
 * Works with the phone UI (lid reads the events via media_daemon) and with
 * games that own the keypad. The table is documented in docs/remote.md.
 * Static musl armv6; no dependencies. Exit 0 ok, 1 usage/unknown key, 2 I/O.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <strings.h>

/* 32-bit ARM kernel struct input_event: timeval is two 32-bit ints. */
struct iev { int sec, usec; unsigned short type, code; int value; };

static const struct { const char *name; int code; } keys[] = {
    {"MUTE",3},{"#",4},{"POUND",4},{"0",5},{"*",6},{"STAR",6},
    {"VOLUME_DOWN",16},{"SPEAKER",17},{"HEADSET",18},{"MENU",19},
    {"9",20},{"8",21},{"7",22},
    {"RECALL",32},{"PHONE_BOOK",33},{"TRANSFER",34},{"DND",35},
    {"6",36},{"5",37},{"4",38},
    {"3",48},{"2",49},{"RIGHT",50},{"1",51},{"RETRIEVE",52},{"REC",53},{"SNOM",54},
    {"HELP",64},{"SETTINGS",65},{"REDIAL",66},{"DOWN",67},
    {"P6",68},{"P12",69},{"P5",70},
    {"P11",80},{"P4",81},{"P10",82},{"P3",83},{"UP",84},{"P9",85},{"P2",86},
    {"CONFERENCE",96},{"CANCEL",97},{"P8",98},{"P1",99},{"P7",100},{"LEFT",101},
    {"F4",113},{"F3",114},{"F2",115},{"F1",116},{"VOLUME_UP",119},{"ENTER",120},
    {0,0}
};

static int lookup(const char *n) {
    for (int i = 0; keys[i].name; i++) if (!strcasecmp(keys[i].name, n)) return keys[i].code;
    return -1;
}

static int emit(int fd, int type, int code, int value) {
    struct iev e; memset(&e, 0, sizeof e);
    e.type = type; e.code = code; e.value = value;
    return write(fd, &e, sizeof e) == sizeof e ? 0 : -1;
}

int main(int argc, char **argv) {
    int hold = 60, i = 1;
    if (argc >= 2 && !strcmp(argv[1], "-l")) {
        for (int k = 0; keys[k].name; k++) printf("%s %d\n", keys[k].name, keys[k].code);
        return 0;
    }
    if (argc >= 3 && !strcmp(argv[i], "-d")) { hold = atoi(argv[i+1]); i += 2; if (hold < 10) hold = 10; if (hold > 5000) hold = 5000; }
    if (i >= argc) { fprintf(stderr, "usage: keyinject [-d ms] NAME... | -c CODE | -l\n"); return 1; }
    int fd = open("/dev/input/event0", O_WRONLY);
    if (fd < 0) { perror("keyinject: /dev/input/event0"); return 2; }
    for (; i < argc; i++) {
        int code;
        if (!strcmp(argv[i], "-c") && i + 1 < argc) { char *end; code = strtol(argv[++i], &end, 10); if (*end || code < 1 || code > 255) { fprintf(stderr, "bad code\n"); return 1; } }
        else { code = lookup(argv[i]); if (code < 0) { fprintf(stderr, "keyinject: unknown key '%s'\n", argv[i]); return 1; } }
        if (emit(fd, 1, code, 1) || emit(fd, 0, 0, 0)) { perror("keyinject: write"); return 2; }
        usleep(hold * 1000);
        if (emit(fd, 1, code, 0) || emit(fd, 0, 0, 0)) { perror("keyinject: write"); return 2; }
        usleep(40000);
    }
    close(fd);
    return 0;
}
