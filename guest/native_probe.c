/* Optional Linux-native FD inventory. No arbitrary PID/address/file arguments.
 * Compile inside the disposable guest only; this is not isolation acceptance. */
#if !defined(__linux__)
#include <stdio.h>
int main(void) {
    puts("{\"status\":\"unavailable\",\"reason\":\"Linux guest required\"}");
    return 2;
}
#else
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void) {
    DIR *dir = opendir("/proc/self/fd");
    struct dirent *entry;
    int first = 1;
    if (!dir) {
        perror("/proc/self/fd");
        return 2;
    }
    printf("{\"claim_scope\":\"native_fd_inventory_only\",\"pid\":%ld,\"uid\":%ld,\"fds\":[",
           (long)getpid(), (long)getuid());
    while ((entry = readdir(dir))) {
        char *end = NULL;
        long value = strtol(entry->d_name, &end, 10);
        struct stat info;
        int flags;
        if (!entry->d_name[0] || *end || value < 0 || value == dirfd(dir))
            continue;
        flags = fcntl((int)value, F_GETFD);
        if (flags < 0 || fstat((int)value, &info) < 0) {
            closedir(dir);
            perror("FD inventory changed");
            return 2;
        }
        printf("%s{\"fd\":%ld,\"cloexec\":%s,\"device\":%llu,\"inode\":%llu}",
               first ? "" : ",", value, flags & FD_CLOEXEC ? "true" : "false",
               (unsigned long long)info.st_dev, (unsigned long long)info.st_ino);
        first = 0;
    }
    if (closedir(dir) < 0) {
        perror("closedir");
        return 2;
    }
    puts("]}");
    return 0;
}
#endif
