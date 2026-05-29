/*
 * Black-box test of mq_pushcfunction.
 *
 * Pins the contract:
 *   - mq_pushcfunction wraps an external C function in a native callable
 *     that can be invoked via mq_pcall or from Lua code.
 *   - Inside the callee, mq_gettop(L) == nargs; index 1 is the first arg.
 *   - Returning N causes the top N stack slots to become the call results.
 *   - Returning 0 yields no results (caller sees nil-padded slots when it
 *     asked for fixed results).
 *   - Returning a value larger than what's on the stack is truncated to
 *     the available count and nil-padded by the caller; the pcall succeeds.
 *   - Returning a negative value raises an error; mq_pcall returns
 *     MQ_ERRRUN and a single error value sits at the top.
 *   - The callee survives a GC cycle while reachable as a global.
 */

#include "moonquakes.h"

#include <assert.h>
#include <stddef.h>
#include <string.h>

static const char *one_shot(mq_State *L, void *ud, size_t *size) {
    (void)L;
    const char **slot = (const char **)ud;
    const char *src = *slot;
    if (src == NULL) {
        *size = 0;
        return NULL;
    }
    *slot = NULL;
    *size = strlen(src);
    return src;
}

/* Double the first arg. */
static int c_doubler(mq_State *L) {
    assert(mq_gettop(L) == 1);
    mq_Integer n = mq_tointeger(L, 1);
    mq_pushinteger(L, n * 2);
    return 1;
}

/* Push two results, return them in order. */
static int c_two_results(mq_State *L) {
    assert(mq_gettop(L) == 0);
    mq_pushinteger(L, 1);
    mq_pushinteger(L, 2);
    return 2;
}

/* No-op that reports 0 results. */
static int c_no_result(mq_State *L) {
    (void)L;
    return 0;
}

/* Claims 5 results but only pushed 1. The dispatcher must clamp safely. */
static int c_overclaim(mq_State *L) {
    (void)L;
    mq_pushinteger(L, 99);
    return 5;
}

/* Raise with a string error value. */
static int c_raise(mq_State *L) {
    mq_pushstring(L, "boom");
    return -1;
}

static void register_global(mq_State *L, const char *name, mq_CFunction fn) {
    mq_pushcfunction(L, fn);
    mq_setglobal(L, name);
}

static void run_lua(mq_State *L, const char *src) {
    const char *cursor = src;
    int rc = mq_load(L, one_shot, &cursor, "=cfn_test", NULL);
    assert(rc == MQ_OK);
    rc = mq_pcall(L, 0, 1, 0);
    assert(rc == MQ_OK);
    assert(mq_toboolean(L, -1));
    mq_settop(L, 0);
}

static void test_doubler_via_pcall(mq_State *L) {
    mq_pushcfunction(L, c_doubler);
    mq_pushinteger(L, 21);
    int rc = mq_pcall(L, 1, 1, 0);
    assert(rc == MQ_OK);
    assert(mq_type(L, -1) == MQ_TNUMBER);
    assert(mq_tointeger(L, -1) == 42);
    mq_settop(L, 0);
}

static void test_doubler_from_lua(mq_State *L) {
    register_global(L, "dbl", c_doubler);
    run_lua(L, "assert(dbl(21) == 42); return true");
}

static void test_two_results_from_lua(mq_State *L) {
    register_global(L, "two", c_two_results);
    run_lua(L,
        "local a, b = two(); "
        "assert(a == 1 and b == 2); "
        "return true");
}

static void test_no_result_pads_with_nil(mq_State *L) {
    mq_pushcfunction(L, c_no_result);
    int rc = mq_pcall(L, 0, 1, 0);
    assert(rc == MQ_OK);
    /* Caller asked for one result; the callee returned zero. The slot
     * must be nil-padded. */
    assert(mq_type(L, -1) == MQ_TNIL);
    mq_settop(L, 0);
}

static void test_overclaim_is_clamped(mq_State *L) {
    /* Pcall with MULTRET-style fixed-1: only one slot is requested even
     * though the callee returned 5. The pcall must succeed and the slot
     * must hold the one value the callee actually pushed. */
    mq_pushcfunction(L, c_overclaim);
    int rc = mq_pcall(L, 0, 1, 0);
    assert(rc == MQ_OK);
    assert(mq_type(L, -1) == MQ_TNUMBER);
    assert(mq_tointeger(L, -1) == 99);
    mq_settop(L, 0);
}

static void test_negative_return_raises(mq_State *L) {
    mq_pushcfunction(L, c_raise);
    int rc = mq_pcall(L, 0, 0, 0);
    assert(rc == MQ_ERRRUN);
    /* The raised error value is on top. */
    size_t len = 0;
    const char *s = mq_tolstring(L, -1, &len);
    assert(s != NULL);
    assert(len == 4);
    assert(memcmp(s, "boom", 4) == 0);
    mq_settop(L, 0);
}

static void test_survives_gc(mq_State *L) {
    register_global(L, "survivor", c_doubler);
    /* Force a full collection; the registered global must keep the
     * closure alive. */
    mq_gc(L, MQ_GCCOLLECT, 0);
    run_lua(L, "assert(survivor(11) == 22); return true");
}

int main(void) {
    mq_State *L = mq_newstate();
    assert(L != NULL);

    test_doubler_via_pcall(L);
    test_doubler_from_lua(L);
    test_two_results_from_lua(L);
    test_no_result_pads_with_nil(L);
    test_overclaim_is_clamped(L);
    test_negative_return_raises(L);
    test_survives_gc(L);

    mq_close(L);
    return 0;
}
