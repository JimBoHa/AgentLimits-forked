#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sysexits.h>
#include <sys/stat.h>
#include <sys/stdio.h>
#include <unistd.h>

static int parse_identity(
    const char *text,
    uint64_t *expected_device,
    uint64_t *expected_inode
) {
    char *separator;
    char *end;
    unsigned long long device;
    unsigned long long inode;

    errno = 0;
    device = strtoull(text, &separator, 10);
    if (errno != 0 || separator == text || *separator != ':') {
        return -1;
    }
    errno = 0;
    inode = strtoull(separator + 1, &end, 10);
    if (errno != 0 || end == separator + 1 || *end != '\0') {
        return -1;
    }
    *expected_device = (uint64_t)device;
    *expected_inode = (uint64_t)inode;
    return 0;
}

static int has_expected_identity(
    const struct stat *details,
    const char *identity
) {
    uint64_t expected_device;
    uint64_t expected_inode;

    if (parse_identity(identity, &expected_device, &expected_inode) != 0) {
        return 0;
    }
    return (uint64_t)details->st_dev == expected_device
        && (uint64_t)details->st_ino == expected_inode;
}

static int is_safe_name(const char *name) {
    return name[0] != '\0'
        && strcmp(name, ".") != 0
        && strcmp(name, "..") != 0
        && strchr(name, '/') == NULL;
}

int main(int argc, char *argv[]) {
    int source_parent;
    int destination_parent;
    struct stat source_parent_details;
    struct stat destination_parent_details;
    struct stat source_details;
    struct stat published_details;

    if (argc != 8) {
        fprintf(
            stderr,
            "Usage: atomic-release-publish SOURCE_PARENT SOURCE_NAME "
            "SOURCE_PARENT_ID SOURCE_ID DESTINATION_PARENT "
            "DESTINATION_NAME DESTINATION_PARENT_ID\n"
        );
        return EX_USAGE;
    }
    if (!is_safe_name(argv[2]) || !is_safe_name(argv[6])) {
        fprintf(stderr, "Atomic release publication names are unsafe\n");
        return EX_USAGE;
    }

    source_parent = open(
        argv[1],
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    );
    destination_parent = open(
        argv[5],
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    );
    if (source_parent < 0 || destination_parent < 0
        || fstat(source_parent, &source_parent_details) != 0
        || fstat(destination_parent, &destination_parent_details) != 0
        || !has_expected_identity(&source_parent_details, argv[3])
        || !has_expected_identity(&destination_parent_details, argv[7])
        || fstatat(
            source_parent,
            argv[2],
            &source_details,
            AT_SYMLINK_NOFOLLOW
        ) != 0
        || !S_ISDIR(source_details.st_mode)
        || !has_expected_identity(&source_details, argv[4])) {
        fprintf(stderr, "Atomic release publication identity changed\n");
        if (source_parent >= 0) {
            close(source_parent);
        }
        if (destination_parent >= 0) {
            close(destination_parent);
        }
        return EX_CANTCREAT;
    }
    if (fstatat(
            destination_parent,
            argv[6],
            &published_details,
            AT_SYMLINK_NOFOLLOW
        ) == 0 || errno != ENOENT) {
        fprintf(stderr, "Atomic release publication destination exists\n");
        close(source_parent);
        close(destination_parent);
        return EX_CANTCREAT;
    }

    if (renameatx_np(
            source_parent,
            argv[2],
            destination_parent,
            argv[6],
            RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH
        ) == 0
        && fstatat(
            destination_parent,
            argv[6],
            &published_details,
            AT_SYMLINK_NOFOLLOW
        ) == 0
        && S_ISDIR(published_details.st_mode)
        && has_expected_identity(&published_details, argv[4])) {
        close(source_parent);
        close(destination_parent);
        return EX_OK;
    }

    fprintf(stderr, "Atomic release publication failed: %s\n", strerror(errno));
    close(source_parent);
    close(destination_parent);
    return EX_CANTCREAT;
}
