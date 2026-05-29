/*
 * Black-box test of Moonquakes table-handling APIs.
 *
 * Pins the contract:
 *   - mq_newtable pushes a fresh empty table.
 *   - mq_setfield stores top-of-stack under a string key on the table at
 *     the given index, and pops the value on success.
 *   - mq_setfield resolves negative indices against the live stack (before
 *     popping), so `mq_setfield(L, -2, "k")` targets the table directly
 *     below the value.
 *   - mq_setfield is a no-op (leaves the value on the stack) when the
 *     target slot is not a table.
 *   - Values stored via mq_setfield are observable through mq_getglobal /
 *     mq_getfield-style retrieval (here exercised end-to-end via Lua code
 *     loaded by mq_load + mq_pcall).
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

static void test_newtable_pushes_a_table(mq_State *L) {
    int before = mq_gettop(L);
    mq_newtable(L);
    assert(mq_gettop(L) == before + 1);
    assert(mq_type(L, -1) == MQ_TTABLE);
    assert(mq_istable(L, -1));
    mq_settop(L, 0);
}

static void test_setfield_pops_value_on_success(mq_State *L) {
    mq_newtable(L);
    mq_pushinteger(L, 42);
    /* Stack: [table, 42], top = 2. -2 = table, -1 = value. */
    mq_setfield(L, -2, "answer");
    /* The value is popped; the table remains. */
    assert(mq_gettop(L) == 1);
    assert(mq_type(L, -1) == MQ_TTABLE);
    mq_settop(L, 0);
}

static void test_setfield_is_visible_from_lua(mq_State *L) {
    mq_newtable(L);
    mq_pushinteger(L, 7);
    mq_setfield(L, -2, "x");
    mq_pushstring(L, "hello");
    mq_setfield(L, -2, "greeting");
    /* Promote the table to a global so Lua code can see it. */
    mq_setglobal(L, "cfg");

    const char *src =
        "assert(cfg.x == 7, 'x'); "
        "assert(cfg.greeting == 'hello', 'greeting'); "
        "return true";
    const char *cursor = src;
    int rc = mq_load(L, one_shot, &cursor, "=cfg_test", NULL);
    assert(rc == MQ_OK);
    rc = mq_pcall(L, 0, 1, 0);
    assert(rc == MQ_OK);
    assert(mq_toboolean(L, -1));
    mq_settop(L, 0);
}

static void test_setfield_on_non_table_is_noop(mq_State *L) {
    mq_pushinteger(L, 1);     /* not a table */
    mq_pushinteger(L, 2);     /* value to set */
    /* -2 is the integer 1, not a table → must leave the stack untouched. */
    mq_setfield(L, -2, "k");
    assert(mq_gettop(L) == 2);
    assert(mq_type(L, -1) == MQ_TNUMBER);
    assert(mq_type(L, -2) == MQ_TNUMBER);
    mq_settop(L, 0);
}

static void test_setfield_null_key_is_noop(mq_State *L) {
    mq_newtable(L);
    mq_pushinteger(L, 99);
    mq_setfield(L, -2, NULL);
    /* Null key: value must remain on the stack. */
    assert(mq_gettop(L) == 2);
    assert(mq_type(L, -1) == MQ_TNUMBER);
    mq_settop(L, 0);
}

int main(void) {
    mq_State *L = mq_newstate();
    assert(L != NULL);

    test_newtable_pushes_a_table(L);
    test_setfield_pops_value_on_success(L);
    test_setfield_is_visible_from_lua(L);
    test_setfield_on_non_table_is_noop(L);
    test_setfield_null_key_is_noop(L);

    mq_close(L);
    return 0;
}
