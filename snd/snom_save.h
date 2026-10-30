/* snom_save.h - tiny persistent-save helpers shared by the NES and libretro
 * engines (header-only, C and C++). The launcher passes the save file path in
 * the environment variable CFW_SAVE_FILE (/snom/cfw-data/saves/<sys>/<rom-sha1>.srm).
 * Writes are atomic (tmp file + rename) so a power loss never leaves a torn
 * save; every failure is logged to stderr ("save: ...") and never fatal.
 * See docs/saves.md. */
#ifndef SNOM_SAVE_H
#define SNOM_SAVE_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>

#define SV_INTERVAL 30   /* seconds between "write if changed" checks */

static inline const char *sv_path(void) {
    const char *p = getenv("CFW_SAVE_FILE");
    return (p && *p) ? p : NULL;
}

/* Read up to n bytes of the save into buf. Returns the number of bytes read
 * (0 when there is no save yet). */
static inline size_t sv_load(const char *path, void *buf, size_t n) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    size_t got = fread(buf, 1, n, f);
    fclose(f);
    fprintf(stderr, "save: loaded %lu bytes from %s\n", (unsigned long)got, path);
    return got;
}

/* Write n bytes atomically. Returns 0 on success, -1 on failure (logged). */
static inline int sv_store(const char *path, const void *buf, size_t n) {
    char tmp[512];
    if (snprintf(tmp, sizeof tmp, "%s.tmp", path) >= (int)sizeof tmp) {
        fprintf(stderr, "save: path too long: %s\n", path); return -1;
    }
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { fprintf(stderr, "save: cannot write %s: %s\n", tmp, strerror(errno)); return -1; }
    const char *p = (const char *)buf;
    size_t left = n;
    while (left) {
        ssize_t w = write(fd, p, left);
        if (w <= 0) { fprintf(stderr, "save: write to %s failed: %s\n", tmp, strerror(errno));
                      close(fd); unlink(tmp); return -1; }
        p += w; left -= (size_t)w;
    }
    if (fsync(fd) < 0) { fprintf(stderr, "save: fsync %s failed: %s\n", tmp, strerror(errno));
                         close(fd); unlink(tmp); return -1; }
    close(fd);
    if (rename(tmp, path) < 0) { fprintf(stderr, "save: rename to %s failed: %s\n", path, strerror(errno));
                                 unlink(tmp); return -1; }
    fprintf(stderr, "save: wrote %lu bytes to %s\n", (unsigned long)n, path);
    return 0;
}
#endif
