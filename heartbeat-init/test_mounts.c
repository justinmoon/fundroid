#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

static int ensure_dir(const char *p, mode_t m) {
    return (mkdir(p, m) == -1 && errno != EEXIST) ? -1 : 0;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    
    printf("[test] Before mounts\n");
    
    ensure_dir("/proc", 0755);
    if (mount("proc", "/proc", "proc", MS_NOSUID|MS_NOEXEC|MS_NODEV, "") == -1) {
        printf("[test] mount /proc failed: %s\n", strerror(errno));
    } else {
        printf("[test] mount /proc OK\n");
    }
    
    ensure_dir("/sys", 0755);
    if (mount("sysfs", "/sys", "sysfs", MS_NOSUID|MS_NOEXEC|MS_NODEV, "") == -1) {
        printf("[test] mount /sys failed: %s\n", strerror(errno));
    } else {
        printf("[test] mount /sys OK\n");
    }
    
    ensure_dir("/dev", 0755);
    if (mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID|MS_NOEXEC, "mode=0755") == -1) {
        printf("[test] mount /dev failed: %s\n", strerror(errno));
    } else {
        printf("[test] mount /dev OK\n");
    }
    
    printf("[test] All mounts attempted, chaining to stock init\n");
    
    execl("/init.stock", "init", NULL);
    
    printf("[test] exec failed: %s\n", strerror(errno));
    while(1) sleep(999);
}
