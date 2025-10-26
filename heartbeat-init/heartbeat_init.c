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

int main(void) {
    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    signal(SIGHUP, on_term);
    signal(SIGPIPE, SIG_IGN);

    mkdir("/dev", 0755);
    mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID|MS_NOEXEC, NULL);
    
    mkdir("/proc", 0755);
    mount("proc", "/proc", "proc", MS_NOSUID|MS_NOEXEC|MS_NODEV, NULL);
    
    mkdir("/sys", 0755);
    mount("sysfs", "/sys", "sysfs", MS_NOSUID|MS_NOEXEC|MS_NODEV, NULL);

    mknod("/dev/console", S_IFCHR | 0600, makedev(229, 0));
    
    int fd = -1;
    for (int tries = 50; tries-- && (fd = open("/dev/console", O_RDWR)) < 0; ) {
        usleep(100000);
    }
    
    if (fd < 0) fd = open("/dev/hvc0", O_RDWR);
    if (fd < 0) fd = open("/dev/ttyS0", O_RDWR);
    
    if (fd >= 0) {
        ioctl(fd, TIOCSCTTY, 0);
        dup2(fd, 0);
        dup2(fd, 1);
        dup2(fd, 2);
        if (fd > 2) close(fd);
    }
    
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    mkdir("/tmp", 0755);
    int breadcrumb = open("/tmp/heartbeat-was-here", O_WRONLY|O_CREAT|O_TRUNC, 0644);
    if (breadcrumb >= 0) {
        dprintf(breadcrumb, "PID1 executed at %ld\n", (long)time(NULL));
        dprintf(breadcrumb, "PID: %d\n", getpid());
        close(breadcrumb);
    }

    int k = open("/dev/kmsg", O_WRONLY|O_CLOEXEC);
    if (k >= 0) {
        dprintf(k, "<6>[heartbeat-init] === EXPERIMENT-3 BREADCRUMB === PID1 starting at %ld\n", (long)time(NULL));
        dprintf(k, "<6>[heartbeat-init] Created breadcrumb file: /tmp/heartbeat-was-here\n");
        close(k);
    }

    puts("VIRTUAL_DEVICE_BOOT_COMPLETED");
    fprintf(stderr, "[cf-heartbeat] standalone PID1 running (experiment-3 instrumented)\n");
    
    k = open("/dev/kmsg", O_WRONLY|O_CLOEXEC);
    if (k >= 0) {
        dprintf(k, "<6>[heartbeat] init started %ld\n", (long)time(NULL));
        close(k);
    }

    while (running) {
        printf("[cf-heartbeat] %ld\n", (long)time(NULL));
        
        k = open("/dev/kmsg", O_WRONLY|O_CLOEXEC);
        if (k >= 0) {
            dprintf(k, "<6>[heartbeat] %ld\n", (long)time(NULL));
            close(k);
        }
        
        fsync(STDOUT_FILENO);
        sleep(5);
    }

    fprintf(stderr, "[cf-heartbeat] shutting down\n");
    umount2("/sys", MNT_DETACH);
    umount2("/proc", MNT_DETACH);
    umount2("/dev", MNT_DETACH);
    sleep(1);
    return 0;
}
