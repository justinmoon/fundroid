#include <errno.h>
#include <fcntl.h>
#include <linux/kdev_t.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <unistd.h>

static void log_line(const char *fmt, ...) {
    char buffer[256];

    va_list args;
    va_start(args, fmt);
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);

    dprintf(STDOUT_FILENO, "[cf-init] %s\n", buffer);
    dprintf(STDERR_FILENO, "[cf-init] %s\n", buffer);
}

static void ensure_dev_node(const char *path, mode_t mode, dev_t dev) {
    struct stat st;
    if (stat(path, &st) == 0) {
        return;
    }
    if (mknod(path, mode, dev) != 0 && errno != EEXIST) {
        log_line("mknod(%s) failed: %d", path, errno);
    }
}

static void mount_once(const char *source,
                       const char *target,
                       const char *fstype,
                       unsigned long flags) {
    if (mount(source, target, fstype, flags, "") != 0) {
        if (errno != EBUSY) {
            log_line("mount(%s -> %s) failed: %d", source, target, errno);
        }
    }
}

static void handoff_to_stock(char **argv) {
    log_line("handing off to /init.stock");
    execv("/init.stock", argv);
    log_line("execv(/init.stock) failed: %d", errno);
    _exit(127);
}

int main(int argc, char **argv) {
    (void)argc;

    log_line("wrapper starting");

    mount_once("devtmpfs", "/dev", "devtmpfs", MS_NOATIME);
    mount_once("proc", "/proc", "proc", MS_NOATIME);
    mount_once("sysfs", "/sys", "sysfs", MS_NOATIME);

    ensure_dev_node("/dev/console", S_IFCHR | 0600, makedev(5, 1));
    ensure_dev_node("/dev/kmsg", S_IFCHR | 0600, makedev(1, 11));

    if (access("/init.stock", X_OK) != 0) {
        log_line("/init.stock missing or not executable: %d", errno);
        _exit(126);
    }

    handoff_to_stock(argv);
}
