#include <stdio.h>
#include <string.h>
#include "moonquakes.h"

/*
 * Helpers
 *
 * mq_tolstring returns a borrowed view: not NUL-terminated, only valid for
 * the explicit `len` bytes. We print via "%.*s" so we never pretend the byte
 * slice is a C string.
 */
static void print_str(const char* label, mq_State* L, int idx) {
    size_t len = 0;
    const char* s = mq_tolstring(L, idx, &len);
    if (s == NULL) {
        printf("%s: <not a string>\n", label);
        return;
    }
    printf("%s: %.*s\n", label, (int)len, s);
}

/*
 * A minimal reader that hands the whole source over in one call. mq_load
 * accumulates chunks into its own buffer, so a one-shot reader is fine for
 * in-memory strings.
 */
typedef struct {
    const char* src;
    int sent;
} string_reader_state;

static const char* string_reader(mq_State* L, void* ud, size_t* size) {
    (void)L;
    string_reader_state* st = (string_reader_state*)ud;
    if (st->sent) {
        *size = 0;
        return NULL;
    }
    st->sent = 1;
    *size = strlen(st->src);
    return st->src;
}

static int load_string(mq_State* L, const char* src, const char* chunkname) {
    string_reader_state st = {src, 0};
    return mq_load(L, string_reader, &st, chunkname, "t");
}

/*
 * A C function callable from Lua. Reads two integer arguments and pushes
 * two results (sum and product). The return value is the number of results
 * the dispatcher should forward to the caller.
 */
static int c_addmul(mq_State* L) {
    mq_Integer a = mq_tointeger(L, 1);
    mq_Integer b = mq_tointeger(L, 2);
    mq_pushinteger(L, a + b);
    mq_pushinteger(L, a * b);
    return 2;
}

static void run_chunk(mq_State* L, const char* label, const char* src) {
    printf("--- %s ---\n", label);
    int load_st = load_string(L, src, "=(load)");
    if (load_st != MQ_OK) {
        print_str("  load failed", L, -1);
        mq_settop(L, 0);
        return;
    }
    int call_st = mq_pcall(L, 0, 0, 0);
    if (call_st != MQ_OK) {
        print_str("  pcall failed", L, -1);
        mq_settop(L, 0);
        return;
    }
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("Moonquakes version: %s\n", mq_version());

    mq_State* L = mq_newstate();
    if (!L) {
        fprintf(stderr, "Failed to create Moonquakes state\n");
        return 1;
    }

    // 1. Stack basics: push, type-check.
    mq_pushinteger(L, 42);
    mq_pushnumber(L, 3.5);
    mq_pushstring(L, "hello");
    printf("stack top after 3 pushes: %d\n", mq_gettop(L));
    for (int i = 1; i <= mq_gettop(L); i++) {
        printf("  [%d] %s\n", i, mq_typename(L, mq_type(L, i)));
    }
    mq_settop(L, 0);

    // 2. Run a chunk for its side effect (sets a global).
    run_chunk(L, "set greeting", "greeting = 'hello from lua'");

    // 3. Read the global back into C.
    int t = mq_getglobal(L, "greeting");
    printf("greeting type=%s\n", mq_typename(L, t));
    print_str("greeting value", L, -1);
    mq_settop(L, 0);

    // 4. Define a function in Lua, call it from C with two arguments.
    run_chunk(L, "define add", "function add(a, b) return a + b end");
    mq_getglobal(L, "add");
    mq_pushinteger(L, 7);
    mq_pushinteger(L, 35);
    int call_st = mq_pcall(L, 2, 1, 0);
    if (call_st == MQ_OK) {
        printf("add(7, 35) = %lld\n", (long long)mq_tointeger(L, -1));
    } else {
        print_str("add failed", L, -1);
    }
    mq_settop(L, 0);

    // 5. Surface a runtime error through pcall.
    run_chunk(L, "define oops", "function oops() error('boom') end");
    mq_getglobal(L, "oops");
    int err_st = mq_pcall(L, 0, 0, 0);
    printf("oops -> status=%d\n", err_st);
    print_str("  msg", L, -1);
    mq_settop(L, 0);

    // 6. Surface a syntax error from mq_load.
    int bad = load_string(L, "function broken(", "=(load)");
    printf("syntax err -> status=%d\n", bad);
    print_str("  msg", L, -1);
    mq_settop(L, 0);

    // 7. Push a value from C and let Lua read it back.
    mq_pushinteger(L, 100);
    mq_setglobal(L, "from_c");
    run_chunk(L, "print from_c", "print('from_c =', from_c)");

    // 8. Register a C function as a Lua global and let Lua call it.
    //    The closure is held alive through the global; mq_setglobal pops
    //    it from the stack after binding.
    mq_pushcfunction(L, c_addmul);
    mq_setglobal(L, "addmul");
    run_chunk(L, "call addmul",
              "local s, p = addmul(6, 7) "
              "print('addmul(6, 7) -> sum=' .. s .. ' product=' .. p)");

    // 9. Load a C function from a shared object through package.loadlib.
    run_chunk(L, "package.loadlib",
              "local f, err, where = package.loadlib('./build/lib/loadlib_addmul.so', "
              "'mq_loadlib_addmul') "
              "assert(f, tostring(err) .. ' (' .. tostring(where) .. ')') "
              "local out = f(8, 9) "
              "print('loadlib addmul(8, 9) -> sum=' .. out[1] .. ' product=' .. out[2] "
              ".. ' len=' .. out[3])");

    // 10. Exercise mq_gc sub-commands.
    printf("gc running before stop: %d\n", mq_gc(L, MQ_GCISRUNNING, 0));
    mq_gc(L, MQ_GCSTOP, 0);
    printf("gc running after stop:  %d\n", mq_gc(L, MQ_GCISRUNNING, 0));
    mq_gc(L, MQ_GCRESTART, 0);
    mq_gc(L, MQ_GCCOLLECT, 0);
    printf("gc count (KB): %d\n", mq_gc(L, MQ_GCCOUNT, 0));

    mq_close(L);
    return 0;
}
