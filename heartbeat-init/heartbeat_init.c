#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static int kmsg_fd = -1;

static void log_line(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    
    if (kmsg_fd >= 0) {
        va_start(ap, fmt);
        dprintf(kmsg_fd, "<6>");
        vdprintf(kmsg_fd, fmt, ap);
        dprintf(kmsg_fd, "\n");
        va_end(ap);
    }
}

static void open_kmsg(void) {
    int fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
    if (fd >= 0) kmsg_fd = fd;
}

static void mount_fs(const char *source, const char *target, const char *fstype, unsigned long flags) {
    if (mkdir(target, 0755) < 0 && errno != EEXIST) {
        fprintf(stderr, "mkdir %s: %s\n", target, strerror(errno));
    }
    if (mount(source, target, fstype, flags, NULL) < 0 && errno != EBUSY && errno != EEXIST) {
        fprintf(stderr, "mount %s: %s\n", target, strerror(errno));
    }
}

static void setup_console(void) {
    int fd = open("/dev/console", O_RDWR);
    if (fd < 0) {
        fd = open("/dev/ttyS0", O_RDWR);
        if (fd < 0) {
            return;
        }
    }
    
    if (dup2(fd, STDIN_FILENO) < 0 ||
        dup2(fd, STDOUT_FILENO) < 0 ||
        dup2(fd, STDERR_FILENO) < 0) {
        const char *msg = "dup2 failed\n";
        write(fd >= 0 ? fd : STDERR_FILENO, msg, strlen(msg));
    }
    
    if (fd > STDERR_FILENO) {
        close(fd);
    }

    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    open_kmsg();
}

static void check_device(const char *path, int flags, const char *what) {
    struct stat st;
    if (stat(path, &st) < 0) {
        log_line("[cf-heartbeat] dev check: %s: stat failed: %s", path, strerror(errno));
        return;
    }
    if (!S_ISCHR(st.st_mode)) {
        log_line("[cf-heartbeat] dev check: %s: not a char device (mode=%o)", path, st.st_mode);
    }
    int fd = open(path, flags | O_CLOEXEC);
    if (fd < 0) {
        log_line("[cf-heartbeat] dev check: %s: open failed: %s", path, strerror(errno));
        return;
    }
    if (strcmp(path, "/dev/urandom") == 0) {
        unsigned char b[8];
        ssize_t n = read(fd, b, sizeof(b));
        log_line("[cf-heartbeat] dev check: /dev/urandom read: %zd", n);
    } else if (strcmp(path, "/dev/null") == 0) {
        ssize_t n = write(fd, "", 0);
        log_line("[cf-heartbeat] dev check: /dev/null write(0): %zd", n);
    }
    close(fd);
    log_line("[cf-heartbeat] dev check: %s OK (%s)", path, what);
}

int main(void) {
    mount_fs("proc", "/proc", "proc", MS_NODEV | MS_NOEXEC | MS_NOSUID);
    mount_fs("sysfs", "/sys", "sysfs", MS_NODEV | MS_NOEXEC | MS_NOSUID);
    mount_fs("devtmpfs", "/dev", "devtmpfs", MS_NOSUID);

    setup_console();

    pid_t pid = getpid();
    char exe[PATH_MAX] = {0};
    ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe)-1);
    if (n >= 0) exe[n] = '\0';
    log_line("[cf-heartbeat] init start: pid=%d%s%s",
             pid, (n >= 0 ? " exe=" : ""), (n >= 0 ? exe : ""));

    printf("VIRTUAL_DEVICE_BOOT_COMPLETED\n");

    check_device("/dev/console", O_RDWR, "console");
    check_device("/dev/null", O_RDWR, "null");
    check_device("/dev/urandom", O_RDONLY, "urandom");
    check_device("/dev/kmsg", O_WRONLY, "kmsg");

    if (access("/init.stock", X_OK) == 0) {
        struct stat st;
        if (stat("/init.stock", &st) == 0) {
            log_line("[cf-heartbeat] /init.stock present (mode=%o size=%ld)", st.st_mode, (long)st.st_size);
        }
    } else {
        log_line("[cf-heartbeat] /init.stock missing or not executable: %s", strerror(errno));
    }

    log_line("[cf-heartbeat] chaining to /init.stock");
    execl("/init.stock", "init", NULL);

    log_line("[cf-heartbeat] Failed to exec /init.stock: %s", strerror(errno));
    execl("/sbin/init", "init", NULL);
    log_line("[cf-heartbeat] Failed to exec /sbin/init: %s", strerror(errno));
    execl("/bin/sh", "sh", NULL);
    log_line("[cf-heartbeat] Failed to exec /bin/sh: %s", strerror(errno));
    return 1;
}
