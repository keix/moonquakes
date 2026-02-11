//! Moonquakes C API Constants
//!
//! Lua 5.4 compatible constants for embedding and extending.
//! Prefix: MQ_ (instead of LUA_), MQL_ (instead of LUAL_)

const std = @import("std");

// ============================================================================
// Status Codes
// ============================================================================

/// No errors
pub const MQ_OK = 0;
/// Thread yielded
pub const MQ_YIELD = 1;
/// Runtime error
pub const MQ_ERRRUN = 2;
/// Syntax error during precompilation
pub const MQ_ERRSYNTAX = 3;
/// Memory allocation error
pub const MQ_ERRMEM = 4;
/// Error while running error handler
pub const MQ_ERRERR = 5;
/// File-related error
pub const MQ_ERRFILE = 6;

// ============================================================================
// Type Codes
// ============================================================================

/// Non-valid stack index
pub const MQ_TNONE = -1;
/// nil
pub const MQ_TNIL = 0;
/// boolean
pub const MQ_TBOOLEAN = 1;
/// light userdata
pub const MQ_TLIGHTUSERDATA = 2;
/// number
pub const MQ_TNUMBER = 3;
/// string
pub const MQ_TSTRING = 4;
/// table
pub const MQ_TTABLE = 5;
/// function
pub const MQ_TFUNCTION = 6;
/// full userdata
pub const MQ_TUSERDATA = 7;
/// thread (coroutine)
pub const MQ_TTHREAD = 8;

/// Number of basic types
pub const MQ_NUMTYPES = 9;

// ============================================================================
// Arithmetic Operators (for mq_arith)
// ============================================================================

/// Addition (+)
pub const MQ_OPADD = 0;
/// Subtraction (-)
pub const MQ_OPSUB = 1;
/// Multiplication (*)
pub const MQ_OPMUL = 2;
/// Float division (/)
pub const MQ_OPDIV = 3;
/// Floor division (//)
pub const MQ_OPIDIV = 4;
/// Modulo (%)
pub const MQ_OPMOD = 5;
/// Exponentiation (^)
pub const MQ_OPPOW = 6;
/// Unary minus (-)
pub const MQ_OPUNM = 7;
/// Bitwise NOT (~)
pub const MQ_OPBNOT = 8;
/// Bitwise AND (&)
pub const MQ_OPBAND = 9;
/// Bitwise OR (|)
pub const MQ_OPBOR = 10;
/// Bitwise XOR (~)
pub const MQ_OPBXOR = 11;
/// Left shift (<<)
pub const MQ_OPSHL = 12;
/// Right shift (>>)
pub const MQ_OPSHR = 13;

// ============================================================================
// Comparison Operators (for mq_compare)
// ============================================================================

/// Equality (==)
pub const MQ_OPEQ = 0;
/// Less than (<)
pub const MQ_OPLT = 1;
/// Less or equal (<=)
pub const MQ_OPLE = 2;

// ============================================================================
// Hook Events
// ============================================================================

/// Call hook
pub const MQ_HOOKCALL = 0;
/// Return hook
pub const MQ_HOOKRET = 1;
/// Line hook
pub const MQ_HOOKLINE = 2;
/// Count hook
pub const MQ_HOOKCOUNT = 3;
/// Tail call hook
pub const MQ_HOOKTAILCALL = 4;

// ============================================================================
// Hook Masks
// ============================================================================

/// Call mask
pub const MQ_MASKCALL = 1 << MQ_HOOKCALL;
/// Return mask
pub const MQ_MASKRET = 1 << MQ_HOOKRET;
/// Line mask
pub const MQ_MASKLINE = 1 << MQ_HOOKLINE;
/// Count mask
pub const MQ_MASKCOUNT = 1 << MQ_HOOKCOUNT;

// ============================================================================
// Integer Limits
// ============================================================================

/// Maximum value for mq_Integer (i64)
pub const MQ_MAXINTEGER = std.math.maxInt(i64);
/// Minimum value for mq_Integer (i64)
pub const MQ_MININTEGER = std.math.minInt(i64);

// ============================================================================
// Stack and Registry
// ============================================================================

/// Minimum Lua stack available to a C function
pub const MQ_MINSTACK = 20;

/// Pseudo-index for the registry
pub const MQ_REGISTRYINDEX = -1001000;

/// Registry index for main thread
pub const MQ_RIDX_MAINTHREAD = 1;
/// Registry index for global environment
pub const MQ_RIDX_GLOBALS = 2;

// ============================================================================
// Reference System
// ============================================================================

/// Invalid reference (returned by luaL_ref for nil)
pub const MQ_REFNIL = -1;
/// No reference (initial/invalid state)
pub const MQ_NOREF = -2;

// ============================================================================
// Function Calls
// ============================================================================

/// Option for multiple returns in mq_call and mq_pcall
pub const MQ_MULTRET = -1;

// ============================================================================
// Module System
// ============================================================================

/// Name of table for loaded modules (package.loaded)
pub const MQ_LOADED_TABLE = "_LOADED";
/// Name of table for preloaded modules (package.preload)
pub const MQ_PRELOAD_TABLE = "_PRELOAD";

// ============================================================================
// Garbage Collection
// ============================================================================

/// Stop the garbage collector
pub const MQ_GCSTOP = 0;
/// Restart the garbage collector
pub const MQ_GCRESTART = 1;
/// Perform a full garbage-collection cycle
pub const MQ_GCCOLLECT = 2;
/// Return the current amount of memory (in Kbytes)
pub const MQ_GCCOUNT = 3;
/// Return the remainder of dividing memory by 1024
pub const MQ_GCCOUNTB = 4;
/// Perform an incremental step
pub const MQ_GCSTEP = 5;
/// Set garbage collector pause
pub const MQ_GCSETPAUSE = 6;
/// Set garbage collector step multiplier
pub const MQ_GCSETSTEPMUL = 7;
/// Check if collector is running
pub const MQ_GCISRUNNING = 9;
/// Change to generational mode
pub const MQ_GCGEN = 10;
/// Change to incremental mode
pub const MQ_GCINC = 11;

// ============================================================================
// Buffer (Auxiliary Library)
// ============================================================================

/// Initial buffer size for mqL_Buffer
pub const MQL_BUFFERSIZE = 8192;

// ============================================================================
// Debug/Configuration
// ============================================================================

/// Enable API argument checks (enabled in debug/safe builds)
pub const MQ_USE_APICHECK = std.debug.runtime_safety;
