const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const Proto = @import("../compiler/proto.zig").Proto;
const NativeFnId = @import("../runtime/native.zig").NativeFnId;
const GC = @import("../runtime/gc/gc.zig").GC;
const object = @import("../runtime/gc/object.zig");
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
    allocator: std.mem.Allocator,
    gc: GC, // Garbage collector (replaces arena)
    open_upvalues: ?*UpvalueObject, // Linked list of open upvalues (sorted by stack level)
    mm_keys: MetamethodKeys, // Pre-allocated metamethod strings
    lua_error_msg: ?*StringObject = null, // Stored Lua error message for pcall

    // Debug hook fields (for debug.sethook/gethook)
    hook_func: ?*ClosureObject = null, // Hook function
    hook_mask: u8 = 0, // Bitmask: 1=call, 2=return, 4=line
    hook_count: u32 = 0, // Count for count hook

    pub fn init(allocator: std.mem.Allocator) !VM {
        // Initialize GC first so we can allocate strings and tables
        var gc = GC.init(allocator);

        // Create globals table via GC
        const globals = try gc.allocTable();

        // Create registry table via GC
        const registry = try gc.allocTable();

        // Pre-allocate metamethod key strings (avoids allocation on every lookup)
        const mm_keys = try MetamethodKeys.init(&gc);

        // Initialize global environment (needs GC for string allocation)
        try builtin.initGlobalEnvironment(globals, &gc);

        var vm = VM{
            .stack = undefined,
            .stack_last = 256 - 1,
            .top = 0,
            .base = 0,
            .ci = null,
            .base_ci = undefined,
            .callstack = undefined,
            .callstack_size = 0,
            .globals = globals,
            .registry = registry,
            .allocator = allocator,
            .gc = gc,
            .open_upvalues = null,
            .mm_keys = mm_keys,
        };
        for (&vm.stack) |*v| {
            v.* = .nil;
        }

        return vm;
    }

    pub fn deinit(self: *VM) void {
        // All tables are now GC-managed, so just clean up the GC
        // GC.deinit() will free all allocated objects (tables, strings, closures)
        self.gc.deinit();
    }

    /// GC SAFETY CONTRACT: VM Root Marking
    ///
    /// GC ROOTS - objects that keep other objects alive:
    /// | Root                  | Description                                      |
    /// |-----------------------|--------------------------------------------------|
    /// | stack[0..top]         | VM stack - locals, temporaries, arguments        |
    /// | base_ci               | Main chunk frame (separate from callstack[])     |
    /// | callstack[0..size]    | Active call frames                               |
    /// | globals               | Global environment table                         |
    /// | open_upvalues         | Captured variables still on stack                |
    /// | lua_error_msg         | Stored error message for pcall                   |
    ///
    /// CRITICAL: base_ci is NOT in callstack[] - it's the main chunk's frame.
    /// When inside a function call, base_ci still references the main proto which
    /// contains nested function prototypes. If not marked, nested function constants
    /// (strings, native closures) will be collected while still referenced.
    ///
    /// Uses markProto() (not markConstants()) to ensure nested protos are marked.
    pub fn collectGarbage(self: *VM) void {
        const before = self.gc.bytes_allocated;

        // Prepare for new GC cycle (clears weak tables list)
        self.gc.beginCollection();

        // === Mark phase: traverse from roots ===

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

        self.gc.markStack(self.stack[0..stack_extent]);

        // 2. Mark call frames
        // NOTE: base_ci is NOT in callstack[] - it's the main chunk's frame.
        // When inside a function call, base_ci still holds the main proto which
        // contains nested function protos. These must be marked or their
        // constants (strings, native closures) will be collected.
        if (self.base_ci.closure) |closure| {
            self.gc.mark(&closure.header);
        } else {
            // Main chunk: mark proto and all nested protos recursively
            self.gc.markProtoObject(@constCast(self.base_ci.func));
        }

        // Mark function call frames on the callstack
        for (self.callstack[0..self.callstack_size]) |frame| {
            if (frame.closure) |closure| {
                self.gc.mark(&closure.header);
            } else {
                self.gc.markProtoObject(@constCast(frame.func));
            }
        }

        // 3. Mark global environment
        self.gc.mark(&self.globals.header);

        // 3b. Mark registry table
        self.gc.mark(&self.registry.header);

        // 4. Mark open upvalues (captured variables still pointing to stack)
        var upval = self.open_upvalues;
        while (upval) |uv| {
            self.gc.mark(&uv.header);
            upval = uv.next_open;
        }

        // 5. Mark lua_error_msg (stored error message for pcall)
        if (self.lua_error_msg) |msg| {
            self.gc.mark(&msg.header);
        }

        // 6. Mark debug hook function (if set)
        if (self.hook_func) |hook| {
            self.gc.mark(&hook.header);
        }

        // === Sweep phase ===
        self.gc.collect();

        // Debug output (disabled in ReleaseFast)
        // TODO: Consider making this configurable via runtime flag or environment variable
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
