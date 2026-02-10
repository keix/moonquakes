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

// Execution ABI: CallInfo (frame), ReturnValue (result)
const execution = @import("execution.zig");
pub const CallInfo = execution.CallInfo;

// Mnemonics is imported internally for execute(), not re-exported to avoid circular dependency
const Mnemonics = @import("mnemonics.zig");

/// Pre-allocated metamethod key strings for fast lookup
/// These are allocated once at VM startup and never collected
pub const MetamethodKeys = struct {
    add: *StringObject,
    sub: *StringObject,
    mul: *StringObject,
    div: *StringObject,
    mod: *StringObject,
    pow: *StringObject,
    unm: *StringObject,
    idiv: *StringObject,
    band: *StringObject,
    bor: *StringObject,
    bxor: *StringObject,
    bnot: *StringObject,
    shl: *StringObject,
    shr: *StringObject,
    eq: *StringObject,
    lt: *StringObject,
    le: *StringObject,
    concat: *StringObject,
    len: *StringObject,
    index: *StringObject,
    newindex: *StringObject,
    call: *StringObject,
    metatable: *StringObject,

    pub fn init(gc: *GC) !MetamethodKeys {
        return .{
            .add = try gc.allocString("__add"),
            .sub = try gc.allocString("__sub"),
            .mul = try gc.allocString("__mul"),
            .div = try gc.allocString("__div"),
            .mod = try gc.allocString("__mod"),
            .pow = try gc.allocString("__pow"),
            .unm = try gc.allocString("__unm"),
            .idiv = try gc.allocString("__idiv"),
            .band = try gc.allocString("__band"),
            .bor = try gc.allocString("__bor"),
            .bxor = try gc.allocString("__bxor"),
            .bnot = try gc.allocString("__bnot"),
            .shl = try gc.allocString("__shl"),
            .shr = try gc.allocString("__shr"),
            .eq = try gc.allocString("__eq"),
            .lt = try gc.allocString("__lt"),
            .le = try gc.allocString("__le"),
            .concat = try gc.allocString("__concat"),
            .len = try gc.allocString("__len"),
            .index = try gc.allocString("__index"),
            .newindex = try gc.allocString("__newindex"),
            .call = try gc.allocString("__call"),
            .metatable = try gc.allocString("__metatable"),
        };
    }
};

pub const VM = struct {
    // Re-export from execution for backward compatibility
    pub const ReturnValue = execution.ReturnValue;

    stack: [256]TValue,
    stack_last: u32,
    top: u32,
    base: u32,
    ci: ?*CallInfo,
    base_ci: CallInfo,
    callstack: [35]CallInfo, // Support up to 35 nested calls
    callstack_size: u8,
    globals: *TableObject,
    allocator: std.mem.Allocator,
    gc: GC, // Garbage collector (replaces arena)
    open_upvalues: ?*UpvalueObject, // Linked list of open upvalues (sorted by stack level)
    mm_keys: MetamethodKeys, // Pre-allocated metamethod strings
    lua_error_msg: ?*StringObject = null, // Stored Lua error message for pcall

    pub fn init(allocator: std.mem.Allocator) !VM {
        // Initialize GC first so we can allocate strings and tables
        var gc = GC.init(allocator);

        // Create globals table via GC
        const globals = try gc.allocTable();

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

        // === Mark phase: traverse from roots ===

        // 1. Mark VM stack (active portion)
        // vm.top is the authoritative stack boundary; only slots below vm.top are scanned.
        // Native functions MUST extend vm.top before using temporary slots.
        // Using maxstacksize is unsafe because slots above vm.top may contain
        // stale object pointers from previous calls.
        self.gc.markStack(self.stack[0..self.top]);

        // 2. Mark call frames
        // NOTE: base_ci is NOT in callstack[] - it's the main chunk's frame.
        // When inside a function call, base_ci still holds the main proto which
        // contains nested function protos. These must be marked or their
        // constants (strings, native closures) will be collected.
        if (self.base_ci.closure) |closure| {
            self.gc.mark(&closure.header);
        } else {
            // Main chunk: mark proto and all nested protos recursively
            self.gc.markProto(self.base_ci.func);
        }

        // Mark function call frames on the callstack
        for (self.callstack[0..self.callstack_size]) |frame| {
            if (frame.closure) |closure| {
                self.gc.mark(&closure.header);
            } else {
                self.gc.markProto(frame.func);
            }
        }

        // 3. Mark global environment
        self.gc.mark(&self.globals.header);

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

    /// Execute bytecode starting from the given proto.
    /// Delegates to Mnemonics.execute() which contains all execution logic.
    pub fn execute(self: *VM, proto: *const Proto) !ReturnValue {
        return Mnemonics.execute(self, proto);
    }
};
