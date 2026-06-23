#include "moonquakes.h"

int mq_loadlib_addmul(mq_State* L) {
    mq_Integer a = mq_tointeger(L, 1);
    mq_Integer b = mq_tointeger(L, 2);
    mq_newtable(L);
    mq_pushinteger(L, a + b);
    mq_seti(L, -2, 1);
    mq_pushinteger(L, a * b);
    mq_seti(L, -2, 2);
    mq_len(L, -1);
    mq_seti(L, -2, 3);
    return 1;
}
