#define _GNU_SOURCE
#include <stdio.h>
#include <unistd.h>

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    
    printf("VIRTUAL_DEVICE_BOOT_COMPLETED\n");
    fprintf(stderr, "[cf-heartbeat] PID1 starting, chaining to /init.stock\n");
    
    execl("/init.stock", "init", NULL);
    
    fprintf(stderr, "[cf-heartbeat] exec failed, hanging\n");
    while(1) sleep(999);
}
