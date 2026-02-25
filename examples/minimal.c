#include <stdio.h>
#include "moonquakes.h"

int main(void) {
    printf("Moonquakes version: %s\n", mq_version());

    mq_State* L = mq_newstate();
    if (!L) {
        fprintf(stderr, "Failed to create Moonquakes state\n");
        return 1;
    }

    printf("State created successfully.\n");

    printf("Initial stack top: %d\n", mq_gettop(L));
    mq_settop(L, 2);
    printf("After mq_settop(L, 2): %d\n", mq_gettop(L));
    mq_settop(L, 0);
    printf("After mq_settop(L, 0): %d\n", mq_gettop(L));

    mq_gc_collect(L);
    printf("GC collected successfully.\n");

    mq_close(L);
    printf("State closed successfully.\n");

    return 0;
}
