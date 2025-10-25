#include <unistd.h>

int main(void) {
    const char *msg = "INIT_STARTED\n";
    write(2, msg, 13);
    write(1, msg, 13);
    
    while(1) sleep(999);
}
