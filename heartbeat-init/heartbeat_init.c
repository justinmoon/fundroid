#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;

static void sigterm_handler(int sig) {
    (void)sig;
    running = 0;
}

static void mount_fs(const char *source, const char *target, const char *fstype, unsigned long flags) {
    if (mkdir(target, 0755) < 0 && errno != EEXIST) {
        fprintf(stderr, "mkdir %s: %s\n", target, strerror(errno));
    }
    if (mount(source, target, fstype, flags, NULL) < 0 && errno != EBUSY && errno != EEXIST) {
        fprintf(stderr, "mount %s: %s\n", target, strerror(errno));
    }
}

static void unmount_fs(const char *target) {
    if (umount2(target, MNT_DETACH) < 0 && errno != EINVAL && errno != ENOENT) {
        fprintf(stderr, "umount %s: %s\n", target, strerror(errno));
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
        fprintf(stderr, "dup2: %s\n", strerror(errno));
    }
    
    if (fd > STDERR_FILENO) {
        close(fd);
    }
}

int main(void) {
    mount_fs("proc", "/proc", "proc", MS_NODEV | MS_NOEXEC | MS_NOSUID);
    mount_fs("sysfs", "/sys", "sysfs", MS_NODEV | MS_NOEXEC | MS_NOSUID);
    mount_fs("devtmpfs", "/dev", "devtmpfs", MS_NOSUID);

    setup_console();

    printf("VIRTUAL_DEVICE_BOOT_COMPLETED\n");
    fflush(stdout);

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    printf("[cf-heartbeat] %ld\n", ts.tv_sec);
    fflush(stdout);

    sleep(2);
    clock_gettime(CLOCK_REALTIME, &ts);
    printf("[cf-heartbeat] %ld\n", ts.tv_sec);
    fflush(stdout);

    sleep(2);
    clock_gettime(CLOCK_REALTIME, &ts);
    printf("[cf-heartbeat] %ld\n", ts.tv_sec);
    fflush(stdout);

    printf("[cf-heartbeat] chaining to /init.stock\n");
    fflush(stdout);

    execl("/init.stock", "init", NULL);
    
    fprintf(stderr, "Failed to exec /init.stock: %s\n", strerror(errno));
    return 1;
}
