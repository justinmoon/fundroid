#define _GNU_SOURCE
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <sys/mount.h>

int main(void) {
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
    
    int fd = open("/dev/heartbeat_was_here", O_CREAT | O_WRONLY | O_TRUNC, 0644);
    if (fd >= 0) {
        const char *msg = "HEARTBEAT_INIT_RAN\n";
        write(fd, msg, strlen(msg));
        close(fd);
    }
    
    execl("/init.stock", "init", NULL);
    
    while(1) sleep(999);
}
