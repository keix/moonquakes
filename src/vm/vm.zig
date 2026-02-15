const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const Proto = @import("../compiler/proto.zig").Proto;
const NativeFnId = @import("../runtime/native.zig").NativeFnId;
const gc_mod = @import("../runtime/gc/gc.zig");
const GC = gc_mod.GC;
const RootProvider = gc_mod.RootProvider;
const object = @import("../runtime/gc/object.zig");
const call = @import("call.zig");
const StringObject = object.StringObject;
const TableObject = object.TableObject;
const ClosureObject = object.ClosureObject;
const UpvalueObject = object.UpvalueObject;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const builtin = @import("../builtin/dispatch.zig");
const metamethod = @import("metamethod.zig");

// Execution ABI: CallInfo (frame)
const execution = @import("execution.zig");
const CallInfo = execution.CallInfo;

// Re-export MetamethodKeys from metamethod.zig
pub const MetamethodKeys = metamethod.MetamethodKeys;

/// VM represents an execution thread (Lua "thread"/coroutine state).
/// The name VM is kept intentionally as a clean-room abstraction.
///
/// Architecture: VM (thread) references GC (global state) via pointer.
/// Multiple VMs (coroutines) can share the same GC.
pub const VM = struct {
    stack: [256]TValue,
    stack_last: u32,
    top: u32,
    base: u32,
    ci: ?*CallInfo,
    base_ci: CallInfo,
    callstack: [35]CallInfo, // Support up to 35 nested calls
    callstack_size: u8,
    globals: *TableObject,
    registry: *TableObject, // Global registry table (for debug.getregistry)
    gc: *GC, // Pointer to shared GC (global state)
    open_upvalues: ?*UpvalueObject, // Linked list of open upvalues (sorted by stack level)
    lua_error_msg: ?*StringObject = null, // Stored Lua error message for pcall

    // Debug hook fields (for debug.sethook/gethook)
    hook_func: ?*ClosureObject = null, // Hook function
    hook_mask: u8 = 0, // Bitmask: 1=call, 2=return, 4=line
    hook_count: u32 = 0, // Count for count hook

    /// Initialize a VM in-place with a shared GC.
    /// GC must be initialized and have mm_keys set up before calling this.
    /// The VM is automatically registered as a GC root provider.
    pub fn init(self: *VM, gc: *GC) !void {
        self.* = .{
            .stack = undefined,
            .stack_last = 256 - 1,
            .top = 0,
            .base = 0,
            .ci = null,
            .base_ci = undefined,
            .callstack = undefined,
            .callstack_size = 0,
            .globals = try gc.allocTable(),
            .registry = try gc.allocTable(),
            .gc = gc,
            .open_upvalues = null,
        };

        for (&self.stack) |*v| {
            v.* = .nil;
        }

        // Initialize global environment (needs GC for string allocation)
        try builtin.initGlobalEnvironment(self.globals, gc);

        // Register as GC root provider (self is now at its final address)
        try gc.addRootProvider(self.rootProvider());
    }

    pub fn deinit(self: *VM) void {
        // Unregister from GC before destruction
        self.gc.removeRootProvider(self.rootProvider());
    }

    /// Run garbage collection manually.
    pub fn collectGarbage(self: *VM) void {
        const before = self.gc.bytes_allocated;

        self.gc.collect();

        // Debug output (disabled in ReleaseFast)
        if (@import("builtin").mode != .ReleaseFast) {
            std.log.info("GC: {} -> {} bytes, next at {}", .{ before, self.gc.bytes_allocated, self.gc.next_gc });
        }
    }

    /// Close all upvalues at or above the given stack level
    pub fn closeUpvalues(self: *VM, level: u32) void {
        while (self.open_upvalues) |uv| {
            // Check if this upvalue points to a stack slot at or above level
            const uv_level = (@intFromPtr(uv.location) - @intFromPtr(&self.stack[0])) / @sizeOf(TValue);
            if (uv_level < level) break;

            // Remove from open list and close
            self.open_upvalues = uv.next_open;
            uv.close();
        }
    }

    /// Get existing open upvalue for stack slot, or create a new one
    pub fn getOrCreateUpvalue(self: *VM, location: *TValue) !*UpvalueObject {
        // Search for existing open upvalue pointing to this location
        var prev: ?*UpvalueObject = null;
        var current = self.open_upvalues;

        while (current) |uv| {
            if (@intFromPtr(uv.location) == @intFromPtr(location)) {
                // Found existing upvalue
                return uv;
            }
            if (@intFromPtr(uv.location) < @intFromPtr(location)) {
                // Passed the insertion point (list is sorted by descending address)
                break;
            }
            prev = uv;
            current = uv.next_open;
        }

        // Create new upvalue
        const new_uv = try self.gc.allocUpvalue(location);

        // Insert into sorted list
        new_uv.next_open = current;
        if (prev) |p| {
            p.next_open = new_uv;
        } else {
            self.open_upvalues = new_uv;
        }

        return new_uv;
    }

    /// VM is just a bridge - dispatches to appropriate native function
    pub fn callNative(self: *VM, id: NativeFnId, func_reg: u32, nargs: u32, nresults: u32) !void {
        try builtin.invoke(id, self, func_reg, nargs, nresults);
    }

    /// Create a RootProvider for this VM instance
    pub fn rootProvider(self: *VM) RootProvider {
        return RootProvider.init(VM, self, &vmRootProviderVTable);
    }

    /// Reserve temporary stack slots for native functions.
    /// MUST be called before any GC-triggering operation (allocString, allocTable, etc.)
    /// when using stack slots beyond the function's arguments.
    ///
    /// func_reg: base-relative register where the function was called
    /// count: number of slots to reserve (func_reg + 0 through func_reg + count - 1)
    ///
    /// GC uses vm.top as the boundary; only slots below vm.top are scanned as roots.
    pub inline fn reserveSlots(self: *VM, func_reg: u32, count: u32) void {
        const needed = self.base + func_reg + count;
        if (self.top < needed) self.top = needed;
    }
};

/// VTable for VM's RootProvider implementation
const vmRootProviderVTable = RootProvider.VTable{
    .markRoots = vmMarkRoots,
    .callValue = vmCallValue,
};

/// Mark all VM roots for GC
/// Called by GC during mark phase via RootProvider interface
fn vmMarkRoots(ctx: *anyopaque, gc: *GC) void {
    const self: *VM = @ptrCast(@alignCast(ctx));

    // 1. Mark VM stack
    // Calculate the maximum stack extent across all active frames.
    // We need to mark up to the highest frame_max because:
    // - vm.top may be lower than frame_max for variable results (nresults < 0)
    // - Each frame's local variables must be protected during GC
    var stack_extent = self.top;

    // Check base_ci's extent
    const base_frame_max = self.base_ci.base + self.base_ci.func.maxstacksize;
    if (base_frame_max > stack_extent) {
        stack_extent = base_frame_max;
    }

    // Check each call frame's extent
    for (self.callstack[0..self.callstack_size]) |frame| {
        const frame_max = frame.base + frame.func.maxstacksize;
        if (frame_max > stack_extent) {
            stack_extent = frame_max;
        }
    }

    gc.markStack(self.stack[0..stack_extent]);

    // 2. Mark call frames
    // NOTE: base_ci is NOT in callstack[] - it's the main chunk's frame.
    // When inside a function call, base_ci still holds the main proto which
    // contains nested function protos. These must be marked or their
    // constants (strings, native closures) will be collected.
    if (self.base_ci.closure) |closure| {
        gc.mark(&closure.header);
    } else {
        // Main chunk: mark proto and all nested protos recursively
        gc.markProtoObject(@constCast(self.base_ci.func));
    }

    // Mark function call frames on the callstack
    for (self.callstack[0..self.callstack_size]) |frame| {
        if (frame.closure) |closure| {
            gc.mark(&closure.header);
        } else {
            gc.markProtoObject(@constCast(frame.func));
        }
    }

    // 3. Mark global environment
    gc.mark(&self.globals.header);

    // 3b. Mark registry table
    gc.mark(&self.registry.header);

    // 4. Mark open upvalues (captured variables still pointing to stack)
    var upval = self.open_upvalues;
    while (upval) |uv| {
        gc.mark(&uv.header);
        upval = uv.next_open;
    }

    // 5. Mark lua_error_msg (stored error message for pcall)
    if (self.lua_error_msg) |msg| {
        gc.mark(&msg.header);
    }

    // 6. Mark debug hook function (if set)
    if (self.hook_func) |hook| {
        gc.mark(&hook.header);
    }
}

/// Call a Lua value (used for __gc finalizers)
/// Called by GC via RootProvider interface
fn vmCallValue(ctx: *anyopaque, func: *const TValue, args: []const TValue) anyerror!TValue {
    const self: *VM = @ptrCast(@alignCast(ctx));
    return call.callValue(self, func.*, args);
}
