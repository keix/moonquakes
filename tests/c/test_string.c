/*
 * Black-box test of Moonquakes string-handling APIs.
 *
 * Pins the contract:
 *   - mq_pushlstring / mq_pushstring / mq_tolstring return a borrowed
 *     pointer into GC-managed inline data. NOT NUL-terminated.
 *   - The pointer stays valid while the underlying value is rooted on the
 *     stack (i.e. has not been popped).
 *   - mq_pushlstring honours embedded NUL bytes.
 *   - mq_tolstring on a number rewrites the slot in place to a string and
 *     reports the new length.
 */

#include "moonquakes.h"

#include <assert.h>
#include <stddef.h>
#include <string.h>

static void test_push_and_borrow(mq_State *L) {
    mq_pushstring(L, "hello");

    size_t len = 0;
    const char *s = mq_tolstring(L, -1, &len);
    assert(s != NULL);
    assert(len == 5);
    assert(memcmp(s, "hello", 5) == 0);

    mq_settop(L, 0);
}

static void test_borrow_survives_other_pushes(mq_State *L) {
    mq_pushstring(L, "hello");
    size_t len_a = 0;
    const char *a = mq_tolstring(L, -1, &len_a);

    mq_pushstring(L, "world");
    size_t len_b = 0;
    const char *b = mq_tolstring(L, -1, &len_b);

    /* The first pointer must still see "hello": both values remain on the
     * stack, so the first StringObject is still rooted and its inline data
     * is intact. */
    assert(len_a == 5);
    assert(memcmp(a, "hello", 5) == 0);
    assert(len_b == 5);
    assert(memcmp(b, "world", 5) == 0);
    assert(a != b);

    mq_settop(L, 0);
}

static void test_pushlstring_embedded_nul(mq_State *L) {
    const char binary[3] = { 'a', '\0', 'b' };
    mq_pushlstring(L, binary, 3);

    size_t len = 0;
    const char *s = mq_tolstring(L, -1, &len);
    assert(s != NULL);
    assert(len == 3);
    assert(memcmp(s, binary, 3) == 0);

    mq_settop(L, 0);
}

static void test_pushlstring_zero_length(mq_State *L) {
    mq_pushlstring(L, NULL, 0);
    assert(mq_type(L, -1) == MQ_TSTRING);

    size_t len = 99;
    const char *s = mq_tolstring(L, -1, &len);
    assert(s != NULL);
    assert(len == 0);

    mq_settop(L, 0);
}

static void test_pushstring_null_pushes_nil(mq_State *L) {
    const char *ret = mq_pushstring(L, NULL);
    assert(ret == NULL);
    assert(mq_type(L, -1) == MQ_TNIL);

    mq_settop(L, 0);
}

static void test_tolstring_coerces_integer_in_place(mq_State *L) {
    mq_pushinteger(L, 42);
    assert(mq_type(L, -1) == MQ_TNUMBER);

    size_t len = 0;
    const char *s = mq_tolstring(L, -1, &len);
    assert(s != NULL);
    assert(len == 2);
    assert(memcmp(s, "42", 2) == 0);
    /* The slot is now a string (mq_tolstring rewrites it). */
    assert(mq_type(L, -1) == MQ_TSTRING);

    mq_settop(L, 0);
}

static void test_tolstring_coerces_float_with_trailing_zero(mq_State *L) {
    mq_pushnumber(L, 1.0);
    size_t len = 0;
    const char *s = mq_tolstring(L, -1, &len);
    assert(s != NULL);
    assert(len == 3);
    assert(memcmp(s, "1.0", 3) == 0);
    assert(mq_type(L, -1) == MQ_TSTRING);

    mq_settop(L, 0);
}

static void test_tolstring_rejects_non_string_types(mq_State *L) {
    mq_pushboolean(L, 1);
    assert(mq_tolstring(L, -1, NULL) == NULL);
    /* The boolean slot must not be rewritten. */
    assert(mq_type(L, -1) == MQ_TBOOLEAN);

    mq_pushnil(L);
    assert(mq_tolstring(L, -1, NULL) == NULL);
    assert(mq_type(L, -1) == MQ_TNIL);

    mq_settop(L, 0);
}

int main(void) {
    mq_State *L = mq_newstate();
    assert(L != NULL);

    test_push_and_borrow(L);
    test_borrow_survives_other_pushes(L);
    test_pushlstring_embedded_nul(L);
    test_pushlstring_zero_length(L);
    test_pushstring_null_pushes_nil(L);
    test_tolstring_coerces_integer_in_place(L);
    test_tolstring_coerces_float_with_trailing_zero(L);
    test_tolstring_rejects_non_string_types(L);

    mq_close(L);
    return 0;
}
