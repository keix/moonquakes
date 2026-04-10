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

const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");
const ClosureObject = object.ClosureObject;
const UpvalueObject = object.UpvalueObject;
const ThreadObject = object.ThreadObject;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const execution = @import("execution.zig");
const CallInfo = execution.CallInfo;
const call_debug_mod = @import("call_debug.zig");
const error_state_mod = @import("error_state.zig");
const field_cache_mod = @import("field_cache.zig");
const hook_mod = @import("hook.zig");
const metamethod = @import("metamethod.zig");
const traceback_mod = @import("traceback.zig");
const yield_mod = @import("yield.zig");

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

    pub const ErrorState = error_state_mod.ErrorState;
    pub const YieldState = yield_mod.YieldState;
    pub const HookState = hook_mod.HookState;
    pub const TracebackState = traceback_mod.TracebackState;
    pub const FieldCache = field_cache_mod.FieldCache;
    pub const CallDebugState = call_debug_mod.CallDebugState;

    // Core execution state
    stack: [STACK_CAPACITY]TValue,
    top: u32,
    base: u32,
    ci: ?*CallInfo,
    base_ci: CallInfo,
    // Keep this below 256 as callstack_size is u8.
    callstack: [200]CallInfo,
    callstack_size: u8,
    open_upvalues: ?*UpvalueObject,

    // Grouped auxiliary state
    yield: YieldState = .{},
    errors: ErrorState = .{},
    hooks: HookState = .{},
    traceback: TracebackState = .{},
    field_cache: FieldCache = .{},
    call_debug: CallDebugState = .{},

    // Shared runtime identity
    rt: *Runtime,
    thread: *ThreadObject,

    // Small inline temp-root buffer with spill storage for deeper native paths.
    temp_roots_inline: [8]TValue = [_]TValue{.nil} ** 8,
    temp_roots_spill: std.ArrayListUnmanaged(TValue) = .{},
    temp_roots_count: u32 = 0,

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
    pub const beginGCGuard = api.beginGCGuard;
    pub const endGCGuard = api.endGCGuard;
    pub const rootProvider = vm_gc.rootProvider;
    pub const reserveSlots = api.reserveSlots;

    // Debug read-only API
    pub const DebugFrameInfo = vm_debug.DebugFrameInfo;
    pub const DebugLocalMeta = vm_debug.DebugLocalMeta;
    pub const debugGetFrameInfoAtLevel = vm_debug.debugGetFrameInfoAtLevel;
    pub const debugWriteLocalAtLevel = vm_debug.debugWriteLocalAtLevel;
    pub const debugInferFunctionNameAtLevel = vm_debug.debugInferFunctionNameAtLevel;
};
