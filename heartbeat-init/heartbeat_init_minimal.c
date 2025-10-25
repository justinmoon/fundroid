#define _GNU_SOURCE
#include <unistd.h>

int main(void) {
    execl("/init.stock", "init", NULL);
    while(1) sleep(999);
}
