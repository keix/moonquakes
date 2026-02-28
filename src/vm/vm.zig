//! VM State - Execution Thread
//!
//! VM is the unit of execution (Lua "thread" / coroutine).
//! Pure state container; behavior lives in separate modules.
//!
//! Architecture:
//!   Runtime (shared) ← VM (thread)
//!   - VM references Runtime via pointer
//!   - Multiple VMs share one Runtime (coroutines)
//!   - VM knows Runtime; Runtime does NOT know VM internals
//!
//! Stack model:
//!   - Fixed stack slots (compile-time constant)
//!   - base: current frame's register 0
//!   - top: next free slot (for GC extent)
//!   - NOTE: capacity is temporarily larger for compatibility tests.
//!
//! Error handling:
//!   - lua_error_value stores the error object
//!   - error.LuaException propagates up call stack
//!   - pcall catches and converts to status code
//!
//! Module split:
//!   - api.zig: public methods (accessors, upvalue, error, temp roots)
//!   - gc.zig: GC integration (root provider, mark, callbacks)
//!   - lifecycle.zig: init/deinit

const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");
const ClosureObject = object.ClosureObject;
const UpvalueObject = object.UpvalueObject;
const ThreadObject = object.ThreadObject;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const execution = @import("execution.zig");
const CallInfo = execution.CallInfo;
const metamethod = @import("metamethod.zig");

// Implementation modules
const api = @import("api.zig");
const vm_debug = @import("debug.zig");
const vm_gc = @import("gc.zig");
const lifecycle = @import("lifecycle.zig");

// Re-exports
pub const MetamethodKeys = metamethod.MetamethodKeys;
pub const LuaException = api.LuaException;

/// VM represents an execution thread (Lua "thread"/coroutine state).
///
/// Architecture: VM references Runtime (shared state) via pointer.
/// Multiple VMs (coroutines) share a single Runtime.
/// VM knows Runtime; Runtime does not know VM.
pub const VM = struct {
    pub const STACK_CAPACITY = 8192;
    stack: [STACK_CAPACITY]TValue,
    top: u32,
    base: u32,
    ci: ?*CallInfo,
    base_ci: CallInfo,
    callstack: [35]CallInfo,
    callstack_size: u8,
    open_upvalues: ?*UpvalueObject,
    lua_error_value: TValue = .nil,
    last_field_reg: ?u8 = null,
    last_field_key: ?*object.StringObject = null,
    int_repr_field_key: ?*object.StringObject = null,

    // Yield state
    yield_base: u32 = 0,
    yield_count: u32 = 0,
    yield_ret_base: u32 = 0,
    yield_nresults: i32 = 0, // -1 = variable results

    rt: *Runtime,
    thread: *ThreadObject,

    temp_roots: [8]TValue = [_]TValue{.nil} ** 8,
    temp_roots_count: u8 = 0,

    hook_func: ?*ClosureObject = null,
    hook_mask: u8 = 0, // 1=call, 2=return, 4=line
    hook_count: u32 = 0,

    // Lifecycle
    pub const init = lifecycle.init;
    pub const deinit = lifecycle.deinit;

    // Accessors
    pub const gc = api.gc;
    pub const globals = api.globals;
    pub const registry = api.registry;
    pub const getThread = api.getThread;
    pub const isMainThread = api.isMainThread;

    // Upvalue
    pub const closeUpvalues = api.closeUpvalues;
    pub const getOrCreateUpvalue = api.getOrCreateUpvalue;

    // Error
    pub const raise = api.raise;
    pub const raiseString = api.raiseString;

    // Native
    pub const callNative = api.callNative;

    // GC
    pub const pushTempRoot = api.pushTempRoot;
    pub const popTempRoots = api.popTempRoots;
    pub const collectGarbage = api.collectGarbage;
    pub const rootProvider = vm_gc.rootProvider;
    pub const reserveSlots = api.reserveSlots;

    // Debug read-only API
    pub const DebugFrameInfo = vm_debug.DebugFrameInfo;
    pub const DebugLocalMeta = vm_debug.DebugLocalMeta;
    pub const debugGetFrameInfoAtLevel = vm_debug.debugGetFrameInfoAtLevel;
    pub const debugWriteLocalAtLevel = vm_debug.debugWriteLocalAtLevel;
};
