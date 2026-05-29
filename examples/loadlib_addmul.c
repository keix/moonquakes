#include "moonquakes.h"

int mq_loadlib_addmul(mq_State* L) {
    mq_Integer a = mq_tointeger(L, 1);
    mq_Integer b = mq_tointeger(L, 2);
    mq_pushinteger(L, a + b);
    mq_pushinteger(L, a * b);
    return 2;
}
