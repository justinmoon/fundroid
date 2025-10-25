#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#ifndef TIOCSCTTY
#define TIOCSCTTY 0x540E
#endif

static volatile sig_atomic_t running = 1;

static void on_term(int sig) {
    (void)sig;
    running = 0;
}

static void mount_fs(const char *src, const char *tgt, const char *type, unsigned long flags) {
    mkdir(tgt, 0755);
    mount(src, tgt, type, flags, NULL);
}

static void unmount_fs(const char *tgt) {
    umount2(tgt, MNT_DETACH);
}

static void setup_console(void) {
    mknod("/dev/console", S_IFCHR | 0600, makedev(5, 1));
    
    int fd = -1;
    for (int tries = 50; tries-- && (fd = open("/dev/console", O_RDWR)) < 0; ) {
        usleep(100000);
    }
    
    if (fd >= 0) {
        ioctl(fd, TIOCSCTTY, 0);
        dup2(fd, STDIN_FILENO);
        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
        if (fd > STDERR_FILENO) close(fd);
    }
    
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
}

int main(void) {
    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    signal(SIGHUP, on_term);
    signal(SIGPIPE, SIG_IGN);

    mount_fs("devtmpfs", "/dev", "devtmpfs", MS_NOSUID|MS_NOEXEC);
    mount_fs("proc", "/proc", "proc", MS_NOSUID|MS_NOEXEC|MS_NODEV);
    mount_fs("sysfs", "/sys", "sysfs", MS_NOSUID|MS_NOEXEC|MS_NODEV);

    setup_console();

    printf("VIRTUAL_DEVICE_BOOT_COMPLETED\n");
    
    int k = open("/dev/kmsg", O_WRONLY|O_CLOEXEC);
    if (k >= 0) {
        dprintf(k, "<6>[heartbeat] init %ld\n", (long)time(NULL));
        close(k);
    }

    while (running) {
        printf("[cf-heartbeat] %ld\n", (long)time(NULL));
        sleep(5);
    }

    printf("[cf-heartbeat] shutting down\n");
    unmount_fs("/sys");
    unmount_fs("/proc");
    unmount_fs("/dev");
    return 0;
}
