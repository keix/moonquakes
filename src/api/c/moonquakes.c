#include <stdlib.h>
#include "moonquakes.h"

struct mq_State
{
    void* internal;
};

mq_State* mq_newstate(void)
{
    mq_State* L = (mq_State*)calloc(1, sizeof(mq_State));
    if (!L)
        return NULL; // Allocation failed

    L->internal = NULL; // Placeholder for internal state
    return L;
}

void mq_close(mq_State* L)
{
    if (!L)
        return;         // Handle null pointer
    L->internal = NULL; // Clean up internal state if necessary

    free(L);
}
