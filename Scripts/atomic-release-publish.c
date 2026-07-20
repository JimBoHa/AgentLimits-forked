#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sysexits.h>
#include <sys/stdio.h>

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "Usage: atomic-release-publish SOURCE DESTINATION\n");
        return EX_USAGE;
    }

    if (renamex_np(
            argv[1],
            argv[2],
            RENAME_EXCL | RENAME_NOFOLLOW_ANY
        ) == 0) {
        return EX_OK;
    }

    fprintf(stderr, "Atomic release publication failed: %s\n", strerror(errno));
    return EX_CANTCREAT;
}
