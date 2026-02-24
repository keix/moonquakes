#include <stdio.h>
#include "moonquakes.h"

int main(void) {
    mq_State* L = mq_newstate();
    if (!L) {
        printf("failed\n");
        return 1;
    }

    printf("Moonquakes minimal OK\n");

    mq_close(L);
    return 0;
}
