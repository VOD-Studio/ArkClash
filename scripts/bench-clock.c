#include <stdio.h>
#include <time.h>

int main(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_REALTIME, &now) != 0) {
        return 1;
    }
    printf("%lld\n", (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000);
    return 0;
}
