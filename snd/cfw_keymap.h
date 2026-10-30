/* cfw_keymap.h - per-game key maps for the CFW engines (header only, C and C++).
 * See docs/keymap.md.
 *
 *   /snom/cfw-data/keymaps/<engine>/<game>.map   one game
 *   /snom/cfw-data/keymaps/<engine>/default.map  every game of that engine
 *   built-in table                               when neither has a valid line
 * Lines: "<scancode> <ACTION>", '#' starts a comment. A malformed line, an
 * unknown action name or a scancode outside 1..255 is skipped with one
 * "keymap: FILE:LINE: ..." line on stderr; a file without any valid line is
 * treated as absent. CFW_KEYMAP_DIR overrides the base directory (tests).
 * Engine = nes|gb|gba|doom; game = ROM sha1 / IWAD name (CFW_GAME_ID). */
#ifndef CFW_KEYMAP_H
#define CFW_KEYMAP_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CFW_KM_MAX 96

struct cfw_keydef { int code; const char *name; };   /* built-in table, code 0 ends it */
struct cfw_keymap { int n; struct { int code, act; } e[CFW_KM_MAX]; };

/* index of NAME in the NULL-terminated array NAMES, or -1 */
static int cfw_km_action(const char *const *names, const char *name) {
    for (int i = 0; names[i]; i++) if (!strcmp(names[i], name)) return i;
    return -1;
}

static void cfw_km_set(struct cfw_keymap *km, int code, int act) {
    for (int i = 0; i < km->n; i++) if (km->e[i].code == code) { km->e[i].act = act; return; }
    if (km->n < CFW_KM_MAX) { km->e[km->n].code = code; km->e[km->n].act = act; km->n++; }
}

/* parse one file; returns number of valid lines, -1 if it cannot be opened */
static int cfw_km_parse(const char *path, const char *const *names, struct cfw_keymap *km) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    char line[256]; int ln = 0, ok = 0;
    while (fgets(line, sizeof line, f)) {
        ln++;
        char *h = strchr(line, '#'); if (h) *h = 0;
        char a[48], b[48], c[48];
        int n = sscanf(line, "%47s %47s %47s", a, b, c);
        if (n <= 0) continue;
        char *end; long code = strtol(a, &end, 10);
        int act = (n == 2 && *end == 0 && code >= 1 && code <= 255) ? cfw_km_action(names, b) : -1;
        if (act < 0) { fprintf(stderr, "keymap: %s:%d: ignoring malformed line\n", path, ln); continue; }
        cfw_km_set(km, (int)code, act); ok++;
    }
    fclose(f);
    return ok;
}

static int cfw_km_clean(const char *s) {
    if (!s || !*s || s[0] == '.') return 0;
    for (; *s; s++)
        if (!((*s >= 'a' && *s <= 'z') || (*s >= 'A' && *s <= 'Z') || (*s >= '0' && *s <= '9') ||
              *s == '.' || *s == '_' || *s == '-')) return 0;
    return 1;
}

/* Load the map. Returns 2 = game map, 1 = default.map, 0 = built-in table. */
static int cfw_keymap_load(const char *engine, const char *game, const char *const *names,
                           const struct cfw_keydef *defs, struct cfw_keymap *km) {
    const char *base = getenv("CFW_KEYMAP_DIR");
    char path[320];
    if (!base || !*base) base = "/snom/cfw-data/keymaps";
    km->n = 0;
    if (cfw_km_clean(engine)) {
        if (cfw_km_clean(game)) {
            snprintf(path, sizeof path, "%s/%s/%s.map", base, engine, game);
            if (cfw_km_parse(path, names, km) > 0) { fprintf(stderr, "keymap: %s\n", path); return 2; }
            km->n = 0;
        }
        snprintf(path, sizeof path, "%s/%s/default.map", base, engine);
        if (cfw_km_parse(path, names, km) > 0) { fprintf(stderr, "keymap: %s\n", path); return 1; }
        km->n = 0;
    }
    for (; defs->code; defs++) {
        int a = cfw_km_action(names, defs->name);
        if (a >= 0) cfw_km_set(km, defs->code, a);
    }
    fprintf(stderr, "keymap: built-in\n");
    return 0;
}

/* action for a scancode or -1 */
static int cfw_keymap_find(const struct cfw_keymap *km, int code) {
    for (int i = 0; i < km->n; i++) if (km->e[i].code == code) return km->e[i].act;
    return -1;
}

/* Call on every key press: records the scancode in /tmp/cfw-lastkey (the panel's
 * "press a key" capture reads it) and, with CFW_KEYMAP_DEBUG set, logs the mapping. */
static void cfw_keymap_note(const struct cfw_keymap *km, const char *const *names, int code) {
    FILE *f = fopen("/tmp/cfw-lastkey", "w");
    if (f) { fprintf(f, "%d\n", code); fclose(f); }
    if (getenv("CFW_KEYMAP_DEBUG")) {
        int a = cfw_keymap_find(km, code);
        fprintf(stderr, "keymap: key %d -> %s\n", code, a >= 0 ? names[a] : "(none)");
    }
}
#endif
