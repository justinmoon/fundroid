#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;

static void on_term(int sig) {
    (void)sig;
    running = 0;
}

static int ensure_dir(const char *p, mode_t m) {
    return (mkdir(p, m) == -1 && errno != EEXIST) ? -1 : 0;
}

static int mount_fs(const char *src, const char *tgt, const char *type, unsigned long flags, const char *data) {
    if (ensure_dir(tgt, 0755) == -1) {
        return -1;
    }
    return mount(src, tgt, type, flags, data);
}

static void bind_stdio_to_console(void) {
    setsid();
    
    int fd = open("/dev/console", O_RDWR | O_CLOEXEC);
    if (fd >= 0) {
        dup2(fd, STDIN_FILENO);
        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
        if (fd > 2) close(fd);
    } else {
        int kfd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
        if (kfd >= 0) {
            dprintf(kfd, "<6>[cf-heartbeat] WARN: open(/dev/console) failed: %s\n", strerror(errno));
            close(kfd);
        }
    }
    
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
}

int main(void) {
    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    signal(SIGHUP, on_term);
    signal(SIGPIPE, SIG_IGN);

    mount_fs("proc", "/proc", "proc", MS_NOSUID|MS_NOEXEC|MS_NODEV, "");
    mount_fs("sysfs", "/sys", "sysfs", MS_NOSUID|MS_NOEXEC|MS_NODEV, "");
    mount_fs("devtmpfs", "/dev", "devtmpfs", MS_NOSUID|MS_NOEXEC, "mode=0755");

    bind_stdio_to_console();

    puts("VIRTUAL_DEVICE_BOOT_COMPLETED");
    fprintf(stderr, "[cf-heartbeat] standalone PID1 running\n");

    while (running) {
        time_t now = time(NULL);
        fprintf(stderr, "[cf-heartbeat] %ld\n", (long)now);
        fsync(STDERR_FILENO);
        
        struct timespec ts = { .tv_sec = 5, .tv_nsec = 0 }, rem;
        while (nanosleep(&ts, &rem) == -1 && errno == EINTR && running) {
            ts = rem;
        }
    }

    fprintf(stderr, "[cf-heartbeat] shutting down\n");
    umount2("/proc", MNT_DETACH);
    umount2("/sys", MNT_DETACH);
    umount2("/dev", MNT_DETACH);
    sleep(1);
    return 0;
}
