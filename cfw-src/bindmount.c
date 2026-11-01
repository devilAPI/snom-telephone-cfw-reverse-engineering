/* bindmount SRC DST: mount --bind for a single file. The phone's busybox mount
 * has no bind support ("can't setup loop device"); rcS uses this to show the
 * user boot splash in the phone app too (docs/theming.md). */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <sys/mount.h>

int main(int argc, char **argv)
{
    if (argc != 3) { fprintf(stderr, "usage: bindmount SRC DST\n"); return 2; }
    if (mount(argv[1], argv[2], NULL, MS_BIND, NULL) != 0) {
        fprintf(stderr, "bindmount: %s\n", strerror(errno)); return 1;
    }
    return 0;
}
