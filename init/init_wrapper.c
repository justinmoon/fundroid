#include <errno.h>
#include <fcntl.h>
#include <linux/kdev_t.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>

static void log_line(const char *fmt, ...) {
    static const char prefix[] = "[cf-init] ";
    static const char kmsg_prefix[] = "<6>[cf-init] ";
    char buffer[256];

    va_list args;
    va_start(args, fmt);
    int written = vsnprintf(buffer, sizeof(buffer), fmt, args);
    va_end(args);

    if (written < 0) {
        return;
    }
    size_t msg_len = (size_t)written;
    if (msg_len >= sizeof(buffer)) {
        msg_len = sizeof(buffer) - 1;
        buffer[msg_len] = '\0';
    }

    struct iovec kmsg_iov[] = {
        {.iov_base = (void *)kmsg_prefix, .iov_len = sizeof(kmsg_prefix) - 1},
        {.iov_base = buffer, .iov_len = msg_len},
        {.iov_base = "\n", .iov_len = 1},
    };
    int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    if (fd >= 0) {
        writev(fd, kmsg_iov, 3);
        close(fd);
    }

    struct iovec console_iov[] = {
        {.iov_base = (void *)prefix, .iov_len = sizeof(prefix) - 1},
        {.iov_base = buffer, .iov_len = msg_len},
        {.iov_base = "\n", .iov_len = 1},
    };
    fd = open("/dev/console", O_WRONLY | O_CLOEXEC);
    if (fd >= 0) {
        writev(fd, console_iov, 3);
        close(fd);
    }

    dprintf(STDOUT_FILENO, "%s%.*s\n", prefix, (int)msg_len, buffer);
    dprintf(STDERR_FILENO, "%s%.*s\n", prefix, (int)msg_len, buffer);
}

static void ensure_dir(const char *path) {
    struct stat st;
    if (stat(path, &st) == 0) {
        return;
    }
    if (mkdir(path, 0755) != 0 && errno != EEXIST) {
        log_line("mkdir(%s) failed: %d", path, errno);
    }
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
    ensure_dir(target);
    if (mount(source, target, fstype, flags, "") != 0) {
        if (errno != EBUSY) {
            log_line("mount(%s -> %s) failed: %d", source, target, errno);
        }
    }
}

static bool exists(const char *path) {
    struct stat st;
    return stat(path, &st) == 0;
}

static void append_marker_line(const char *path, const char *msg) {
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0) {
        log_line("open(%s) failed: %d", path, errno);
        return;
    }
    dprintf(fd, "%s\n", msg);
    close(fd);
}

static void write_markers(const char *msg) {
    ensure_dir("/metadata");
    ensure_dir("/metadata/cf_init");
    append_marker_line("/metadata/cf_init/marker.log", msg);
    append_marker_line("/cf_init_marker", msg);
    append_marker_line("/tmp/cf_init_marker", msg);
}

static void try_exec_stock(char **argv) {
    log_line("handing off to /init.stock");
    write_markers("handing off to /init.stock");
    execv("/init.stock", argv);
    log_line("execv(/init.stock) failed: %d", errno);
    write_markers("execv(/init.stock) failed");
    _exit(127);
}

int main(int argc, char **argv) {
    (void)argc;
    log_line("wrapper starting");
    write_markers("wrapper starting");

    mount_once("devtmpfs", "/dev", "devtmpfs", MS_NOATIME);
    mount_once("proc", "/proc", "proc", MS_NOATIME);
    mount_once("sysfs", "/sys", "sysfs", MS_NOATIME);

    ensure_dev_node("/dev/console", S_IFCHR | 0600, makedev(5, 1));
    ensure_dev_node("/dev/kmsg", S_IFCHR | 0600, makedev(1, 11));

    if (!exists("/init.stock")) {
        log_line("/init.stock missing; attempting to rename original init");
        if (rename("/init", "/init.stock") != 0) {
            log_line("rename(/init -> /init.stock) failed: %d", errno);
            write_markers("rename(/init -> /init.stock) failed");
            _exit(126);
        }
    }

    try_exec_stock(argv);
}
