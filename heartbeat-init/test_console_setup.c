#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

#ifndef TIOCSCTTY
#define TIOCSCTTY 0x540E
#endif

int main(void) {
    mkdir("/dev", 0755);
    mount("devtmpfs", "/dev", "devtmpfs", MS_NOSUID|MS_NOEXEC, NULL);
    
    mknod("/dev/console", S_IFCHR | 0600, makedev(5, 1));
    
    int fd = -1;
    for (int tries = 50; tries-- && (fd = open("/dev/console", O_RDWR)) < 0; ) {
        usleep(100000);
    }
    
    if (fd >= 0) {
        ioctl(fd, TIOCSCTTY, 0);
        dup2(fd, 0);
        dup2(fd, 1);
        dup2(fd, 2);
        if (fd > 2) close(fd);
    }
    
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    
    printf("CONSOLE_TEST: printf works\n");
    fprintf(stderr, "CONSOLE_TEST: fprintf stderr works\n");
    
    const char *msg = "CONSOLE_TEST: raw write works\n";
    write(1, msg, strlen(msg));
    
    printf("CONSOLE_TEST: Now chaining to stock init\n");
    
    execl("/init.stock", "init", NULL);
    
    printf("CONSOLE_TEST: exec failed\n");
    while(1) sleep(999);
}
