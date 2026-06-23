/*
 * Moonquakes - C Interface
 *
 * Moonquakes is a clean-room implementation of the Lua 5.4 language.
 * Written with clarity, structural boundaries, and explicit ownership
 * as primary design goals.
 *
 * This header defines the public C interface between host programs and
 * the Moonquakes runtime.
 * 
 * Handwritten at the boundary.
 *
 * Moonquakes 0.4.0 - An interpretation of Lua.
 * Copyright (c) 2025 KEI SAWAMURA. Licensed under the MIT License.
 */

#ifndef MOONQUAKES_H
#define MOONQUAKES_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// C API constants (Lua 5.4 compatible)
enum {
    MQ_OK = 0,
    MQ_YIELD = 1,
    MQ_ERRRUN = 2,
    MQ_ERRSYNTAX = 3,
    MQ_ERRMEM = 4,
    MQ_ERRERR = 5,
    MQ_ERRFILE = 6,
};

// Type tags returned by mq_type
enum {
    MQ_TNONE = -1,
    MQ_TNIL = 0,
    MQ_TBOOLEAN = 1,
    MQ_TLIGHTUSERDATA = 2,
    MQ_TNUMBER = 3,
    MQ_TSTRING = 4,
    MQ_TTABLE = 5,
    MQ_TFUNCTION = 6,
    MQ_TUSERDATA = 7,
    MQ_TTHREAD = 8,
};

typedef struct mq_State mq_State;
typedef int64_t mq_Integer;
typedef double mq_Number;

/*
 * Native callable signature. Registered via mq_pushcfunction.
 *
 * On entry, arguments are visible at indices 1..mq_gettop(L). The callee
 * pushes its results and returns the result count. A negative return value
 * signals an error; the value on top of the stack (or a synthesized message
 * when the stack is empty) becomes the raised error. v1 does not support
 * upvalues or yielding from a C function.
 *
 * The mq_State* passed to mq_CFunction is borrowed. It is valid only for the
 * duration of the C function call. Extensions must not store it or use it
 * after the function returns.
 */
typedef int (*mq_CFunction)(mq_State* L);

/*
 * Reader callback used by mq_load. Called repeatedly until it returns NULL
 * or writes 0 to *size. The returned pointer must stay valid until the next
 * call into the same reader.
 */
typedef const char* (*mq_Reader)(mq_State* L, void* ud, size_t* size);

// State Manipulation
mq_State* mq_newstate(void);
void mq_close(mq_State* L);
const char* mq_version(void);

// Stack Operations
int mq_gettop(mq_State* L);
void mq_settop(mq_State* L, int idx);

// Type Inspection
int mq_type(mq_State* L, int idx);
const char* mq_typename(mq_State* L, int t);
int mq_isnil(mq_State* L, int idx);
int mq_isnone(mq_State* L, int idx);
int mq_isnoneornil(mq_State* L, int idx);
int mq_isboolean(mq_State* L, int idx);
int mq_isnumber(mq_State* L, int idx);
int mq_isinteger(mq_State* L, int idx);
int mq_isstring(mq_State* L, int idx);
int mq_istable(mq_State* L, int idx);
int mq_isfunction(mq_State* L, int idx);

// Push
//
// String pushes return a borrowed view of the interned bytes. The pointer is
// NOT NUL-terminated; it is valid for the explicit `len` bytes only while the
// underlying value stays alive on the stack/globals.
void mq_pushnil(mq_State* L);
void mq_pushboolean(mq_State* L, int b);
void mq_pushinteger(mq_State* L, mq_Integer n);
void mq_pushnumber(mq_State* L, mq_Number n);
const char* mq_pushlstring(mq_State* L, const char* s, size_t len);
const char* mq_pushstring(mq_State* L, const char* s);
void mq_pushcfunction(mq_State* L, mq_CFunction fn);
void mq_pushvalue(mq_State* L, int idx);

// Conversion (to*)
//
// `mq_tolstring` returns a borrowed byte view, not a C string. Callers must
// use the `len` out-param; the bytes are not NUL-terminated. A length-less
// `mq_tostring` is intentionally NOT in this header: a Lua-named convenience
// without a length out-param would invite `printf("%s", ...)` use, which is
// undefined against Moonquakes' GC strings. An owned-copy API
// (`mq_dupecstring` / `mq_tocstringbuf`) will land separately when needed.
int mq_toboolean(mq_State* L, int idx);
mq_Integer mq_tointeger(mq_State* L, int idx);
mq_Integer mq_tointegerx(mq_State* L, int idx, int* isnum);
mq_Number mq_tonumber(mq_State* L, int idx);
mq_Number mq_tonumberx(mq_State* L, int idx, int* isnum);
const char* mq_tolstring(mq_State* L, int idx, size_t* len);

// Load
int mq_load(mq_State* L, mq_Reader reader, void* data,
            const char* chunkname, const char* mode);

// Protected call
int mq_pcall(mq_State* L, int nargs, int nresults, int msgh);

// Tables
//
// `mq_newtable` pushes a new empty table.
// `mq_setfield` does t[k] = v, where t is at idx and v is on top of the
// stack; v is popped on success.
void mq_newtable(mq_State* L);
int mq_geti(mq_State* L, int idx, mq_Integer n);
void mq_setfield(mq_State* L, int idx, const char* k);
void mq_seti(mq_State* L, int idx, mq_Integer n);

// Length
int mq_len(mq_State* L, int idx);

// Globals
int mq_getglobal(mq_State* L, const char* name);
void mq_setglobal(mq_State* L, const char* name);

// Garbage collector control. `what` selects a sub-command (MQ_GCSTOP,
// MQ_GCRESTART, MQ_GCCOLLECT, MQ_GCCOUNT, MQ_GCCOUNTB, MQ_GCSTEP,
// MQ_GCSETPAUSE, MQ_GCSETSTEPMUL, MQ_GCISRUNNING, MQ_GCGEN, MQ_GCINC).
// `data` is the optional argument for sub-commands that take one; pass 0
// for sub-commands without an argument. The return value's meaning depends
// on the sub-command (see exports.zig). Returns -1 for unknown commands.
int mq_gc(mq_State* L, int what, int data);

// Sub-command constants for mq_gc (mirrored from src/api/c/constants.zig).
enum {
    MQ_GCSTOP       = 0,
    MQ_GCRESTART    = 1,
    MQ_GCCOLLECT    = 2,
    MQ_GCCOUNT      = 3,
    MQ_GCCOUNTB     = 4,
    MQ_GCSTEP       = 5,
    MQ_GCSETPAUSE   = 6,
    MQ_GCSETSTEPMUL = 7,
    MQ_GCISRUNNING  = 9,
    MQ_GCGEN        = 10,
    MQ_GCINC        = 11,
};


// Convenience macros (Lua 5.4 compatible)
#define mq_pop(L, n) mq_settop((L), (-(n) - 1))

#ifdef __cplusplus
}
#endif

#endif /* MOONQUAKES_H */
