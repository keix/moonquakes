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

    pub const YieldState = struct {
        base: u32 = 0,
        count: u32 = 0,
        ret_base: u32 = 0,
        nresults: i32 = 0, // -1 = variable results
        from_tailcall: bool = false,
    };

    pub const ErrorState = struct {
        lua_error_value: TValue = .nil,
        close_metamethod_depth: u8 = 0,
        pending_error_unwind: bool = false,
        pending_error_unwind_ci: ?*CallInfo = null,
        error_handling_depth: u8 = 0,
        pending_error_from_error_builtin: bool = false,
        native_call_depth: u16 = 0,
    };

    pub const HookState = struct {
        func: ?*ClosureObject = null,
        func_value: TValue = .nil,
        mask: u8 = 0, // 1=call, 2=return, 4=line
        count: u32 = 0,
        countdown: u32 = 0,
        in_hook: bool = false,
        transfer_start: u32 = 1,
        transfer_count: u32 = 0,
        transfer_values: [64]TValue = [_]TValue{.nil} ** 64,
        name_override: ?[]const u8 = null,
        skip_next_line: bool = false,
        last_line: i64 = -1,
    };

    pub const TracebackState = struct {
        snapshot_lines: [256]u32 = [_]u32{0} ** 256,
        snapshot_names: [256]TValue = [_]TValue{.nil} ** 256,
        snapshot_closures: [256]?*ClosureObject = [_]?*ClosureObject{null} ** 256,
        snapshot_sources: [256][]const u8 = [_][]const u8{""} ** 256,
        snapshot_def_lines: [256]u32 = [_]u32{0} ** 256,
        snapshot_count: u16 = 0,
        snapshot_has_error_frame: bool = false,
    };

    pub const FieldCache = struct {
        last_field_reg: ?u8 = null,
        last_field_key: ?*object.StringObject = null,
        last_field_is_global: bool = false,
        last_field_is_method: bool = false,
        last_field_tick: u64 = 0,
        int_repr_field_key: ?*object.StringObject = null,
        exec_tick: u64 = 0,
    };

    pub const CallDebugState = struct {
        next_name: ?[]const u8 = null,
        next_namewhat: ?[]const u8 = null,
    };

    stack: [STACK_CAPACITY]TValue,
    top: u32,
    base: u32,
    ci: ?*CallInfo,
    base_ci: CallInfo,
    // Keep this below 256 as callstack_size is u8.
    callstack: [200]CallInfo,
    callstack_size: u8,
    open_upvalues: ?*UpvalueObject,
    yield: YieldState = .{},
    errors: ErrorState = .{},
    hooks: HookState = .{},
    traceback: TracebackState = .{},
    field_cache: FieldCache = .{},
    call_debug: CallDebugState = .{},

    rt: *Runtime,
    thread: *ThreadObject,

    // TODO(gc): Revisit fixed size. A growable temp-root stack would remove
    // remaining depth limits in deeply nested native/metamethod paths.
    temp_roots: [32]TValue = [_]TValue{.nil} ** 32,
    temp_roots_count: u8 = 0,

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
