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
 * Moonquakes 0.1.1 - An interpretation of Lua.
 * Copyright (c) 2025 KEI SAWAMURA. Licensed under the MIT License.
 *
 */

#ifndef MOONQUAKES_H
#define MOONQUAKES_H

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

typedef struct mq_State mq_State;

const char* mq_version(void);

mq_State* mq_newstate(void);
void mq_close(mq_State* L);

/*
 * Force a full garbage collection cycle.
 *
 * This function may be unified under a more general mq_gc()
 * interface in the future, but for now it serves as a simple way
 * to explicity trigger collection.
 */
void mq_gc_collect(mq_State* L);


#ifdef __cplusplus
}
#endif

#endif // Handwritten by keix - Master *void
