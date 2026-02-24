//! GC Object System
//!
//! All heap-allocated Lua values inherit from GCObject.
//! Uniform header enables polymorphic GC traversal.
//!
//! Object types:
//!   - StringObject: interned, immutable, hash cached
//!   - TableObject: hash + array hybrid (Lua table)
//!   - ClosureObject: function + captured upvalues
//!   - NativeClosureObject: C/Zig function + upvalues
//!   - UpvalueObject: open (stack ref) or closed (own storage)
//!   - ProtoObject: compiled bytecode (function prototype)
//!   - ThreadObject: coroutine state (VM reference)
//!   - UserdataObject: C-managed memory with optional metatable
//!
//! Layout invariant:
//!   Every object struct starts with GCObject header.
//!   @fieldParentPtr enables safe downcasting from header to concrete type.

const std = @import("std");
const proto_mod = @import("../../compiler/proto.zig");
pub const Instruction = @import("../../compiler/opcodes.zig").Instruction;
pub const Upvaldesc = proto_mod.Upvaldesc;

/// Types of GC-managed objects
pub const GCObjectType = enum(u8) {
    string,
    table,
    closure,
    native_closure,
    upvalue,
    userdata,
    proto,
    thread,
};

/// Common header for all GC-managed objects
///
/// This header must be the first field in every GC object struct.
/// It provides the infrastructure for mark-and-sweep collection.
///
/// Tri-color abstraction for incremental GC:
///   White: mark_bit != GC.current_mark (unreachable, potentially garbage)
///   Gray:  mark_bit == GC.current_mark AND in_gray == true (reachable, children not scanned)
///   Black: mark_bit == GC.current_mark AND in_gray == false (reachable, fully scanned)
pub const GCObject = struct {
    /// Object type for dispatch in mark/sweep phases
    type: GCObjectType,

    /// Mark bit for garbage collection (flip mark scheme)
    /// Compared with GC.current_mark to determine reachability
    mark_bit: bool,

    /// Gray list membership flag
    /// true = in gray list (awaiting child scan)
    in_gray: bool = false,

    /// Linked list pointer for tracking all objects
    /// The GC maintains a list of all allocated objects
    next: ?*GCObject,

    /// Gray list link for incremental marking
    gray_next: ?*GCObject = null,

    /// True if object has a pending __gc finalizer in the queue
    finalizer_queued: bool = false,

    /// Initialize a GC object header
    pub fn init(object_type: GCObjectType, next_obj: ?*GCObject) GCObject {
        return .{
            .type = object_type,
            .mark_bit = false,
            .in_gray = false,
            .next = next_obj,
            .gray_next = null,
            .finalizer_queued = false,
        };
    }

    /// Initialize with specific mark bit (for incremental GC)
    pub fn initWithMark(object_type: GCObjectType, next_obj: ?*GCObject, mark_value: bool) GCObject {
        return .{
            .type = object_type,
            .mark_bit = mark_value,
            .in_gray = false,
            .next = next_obj,
            .gray_next = null,
            .finalizer_queued = false,
        };
    }

    /// Mark this object as reachable (legacy, for compatibility)
    pub fn mark(self: *GCObject) void {
        self.mark_bit = true;
    }

    /// Clear the mark (for next collection cycle)
    pub fn unmark(self: *GCObject) void {
        self.mark_bit = false;
    }

    /// Check if object is marked (legacy, use GC.isMarked for flip mark)
    pub fn isMarkedLegacy(self: *const GCObject) bool {
        return self.mark_bit;
    }
};

/// String Object - GC-managed immutable strings
///
/// StringObject stores string data inline after the struct.
/// Layout: [GCObject header][len][hash][string bytes...]
pub const StringObject = struct {
    header: GCObject,
    len: usize,
    hash: u32, // FNV-1a hash for fast comparison and table keys

    /// Get pointer to the string data (stored inline after struct)
    pub fn data(self: *StringObject) [*]u8 {
        const base = @intFromPtr(self);
        const offset = @sizeOf(StringObject);
        return @ptrFromInt(base + offset);
    }

    /// Get string as a slice
    pub fn asSlice(self: *const StringObject) []const u8 {
        const ptr = @as(*StringObject, @constCast(self));
        return ptr.data()[0..self.len];
    }

    /// Calculate hash using FNV-1a algorithm
    pub fn hashString(str: []const u8) u32 {
        var hash: u32 = 2166136261; // FNV offset basis
        for (str) |byte| {
            hash ^= byte;
            hash *%= 16777619; // FNV prime
        }
        return hash;
    }
};

/// Table Object - GC-managed Lua table
///
/// Supports any TValue as key (Lua 5.4 compatible).
/// Keys can be: strings, numbers, booleans, tables, functions, userdata.
/// nil cannot be a key (Lua semantics).
pub const TableObject = struct {
    const TValue = @import("../value.zig").TValue;

    /// Custom hash context for TValue keys
    /// Supports all Lua key types: strings, numbers, booleans, objects
    pub const TValueKeyContext = struct {
        pub fn hash(_: TValueKeyContext, key: TValue) u64 {
            return switch (key) {
                .nil => 0, // nil can't be a key, but need a hash for HashMap
                .boolean => |b| if (b) 1 else 2,
                .integer => |i| @bitCast(i),
                .number => |n| blk: {
                    // Check if float is actually an integer value
                    if (n == @floor(n) and n >= -9007199254740992 and n <= 9007199254740992) {
                        // Use same hash as integer for int-representable floats
                        const as_int: i64 = @intFromFloat(n);
                        break :blk @bitCast(as_int);
                    }
                    break :blk @bitCast(n);
                },
                .object => |obj| blk: {
                    if (obj.type == .string) {
                        // Use string's pre-computed hash for consistency
                        const str: *StringObject = @fieldParentPtr("header", obj);
                        break :blk str.hash;
                    }
                    // For other objects, use pointer as hash
                    break :blk @intFromPtr(obj);
                },
            };
        }

        pub fn eql(_: TValueKeyContext, a: TValue, b: TValue) bool {
            return a.eql(b);
        }
    };

    pub const HashMap = std.HashMap(
        TValue,
        TValue,
        TValueKeyContext,
        std.hash_map.default_max_load_percentage,
    );

    /// Weak table mode for __mode metamethod
    pub const WeakMode = enum(u2) {
        none = 0, // Strong table (default)
        weak_keys = 1, // __mode contains 'k'
        weak_values = 2, // __mode contains 'v'
        weak_both = 3, // __mode contains both 'k' and 'v'
    };

    header: GCObject,
    hash_part: HashMap,
    allocator: std.mem.Allocator,
    /// Metatable for metamethod dispatch (null if no metatable)
    metatable: ?*TableObject,
    /// Weak mode, cached from metatable.__mode during GC cycle
    weak_mode: WeakMode = .none,

    /// Check if this table has weak keys
    pub fn hasWeakKeys(self: *const TableObject) bool {
        return self.weak_mode == .weak_keys or self.weak_mode == .weak_both;
    }

    /// Check if this table has weak values
    pub fn hasWeakValues(self: *const TableObject) bool {
        return self.weak_mode == .weak_values or self.weak_mode == .weak_both;
    }

    /// Get a value by TValue key
    pub fn get(self: *const TableObject, key: TValue) ?TValue {
        return self.hash_part.get(key);
    }

    /// Set a value by TValue key
    /// Note: nil and NaN keys are not allowed (Lua 5.4 semantics)
    pub fn set(self: *TableObject, key: TValue, value: TValue) !void {
        if (key.isNil()) return error.InvalidTableKey;
        if (key == .number and std.math.isNan(key.number)) return error.InvalidTableKey;
        // Setting to nil removes the entry
        if (value.isNil()) {
            _ = self.hash_part.remove(key);
        } else {
            try self.hash_part.put(key, value);
        }
    }

    /// Clean up internal data structures (called by GC during sweep)
    pub fn deinit(self: *TableObject) void {
        self.hash_part.deinit();
    }
};

/// Closure Object - GC-managed function instance
///
/// Wraps a ProtoObject (bytecode) with upvalues for captured variables.
pub const ClosureObject = struct {
    header: GCObject,
    proto: *ProtoObject,
    upvalues: []*UpvalueObject,

    /// Get the underlying ProtoObject
    pub fn getProto(self: *const ClosureObject) *ProtoObject {
        return self.proto;
    }
};

/// Native Closure Object - GC-managed native function
///
/// Wraps a native function pointer. Always reachable via globals,
/// so effectively never collected, but visible to GC for consistency.
pub const NativeClosureObject = struct {
    const NativeFn = @import("../native.zig").NativeFn;

    header: GCObject,
    func: NativeFn,

    /// Get the native function
    pub fn getFunc(self: *const NativeClosureObject) NativeFn {
        return self.func;
    }
};

/// Upvalue Object - GC-managed captured variable
///
/// Upvalues capture variables from enclosing scopes for closures.
/// - "Open" upvalue: location points to a stack slot (variable still on stack)
/// - "Closed" upvalue: location points to self.closed (stack frame popped)
pub const UpvalueObject = struct {
    const TValue = @import("../value.zig").TValue;

    header: GCObject,
    /// Pointer to the value (stack slot when open, &closed when closed)
    location: *TValue,
    /// Storage for the value when the upvalue is closed
    closed: TValue,
    /// Linked list of open upvalues (for efficient closing when stack frame pops)
    next_open: ?*UpvalueObject,

    /// Check if this upvalue is closed
    pub fn isClosed(self: *const UpvalueObject) bool {
        return self.location == &@constCast(self).closed;
    }

    /// Close this upvalue: copy the value and point to internal storage
    pub fn close(self: *UpvalueObject) void {
        self.closed = self.location.*;
        self.location = &self.closed;
    }

    /// Get the current value
    pub fn get(self: *const UpvalueObject) TValue {
        return self.location.*;
    }

    /// Set the value
    pub fn set(self: *UpvalueObject, value: TValue) void {
        self.location.* = value;
    }
};

/// Proto Object - GC-managed function prototype
///
/// Contains bytecode, constants, and metadata for Lua functions.
/// Previously allocated via raw allocator, now GC-managed for proper lifecycle.
///
/// Lua semantics: Proto contains TValues (constants) and nested ProtoObjects,
/// forming a tree structure that must be traced by GC.
pub const ProtoObject = struct {
    const TValue = @import("../value.zig").TValue;

    header: GCObject,
    /// Constants table (may contain GC objects like strings)
    k: []const TValue,
    /// Bytecode instructions
    code: []const Instruction,
    /// Nested function prototypes (GC-managed)
    protos: []const *ProtoObject,
    /// Number of fixed parameters
    numparams: u8,
    /// Whether function accepts varargs
    is_vararg: bool,
    /// Maximum stack size needed
    maxstacksize: u8,
    /// Number of upvalues
    nups: u8,
    /// Upvalue descriptors
    upvalues: []const Upvaldesc,

    /// Allocator used to allocate k, code, protos, upvalues arrays
    /// Needed for deallocation during GC sweep
    allocator: std.mem.Allocator,

    // Debug/error info
    /// Source name (e.g., "@file.lua" or "[string \"...\"]")
    source: []const u8 = "",
    /// Line number for each instruction
    lineinfo: []const u32 = &.{},
};

/// Userdata Object - GC-managed arbitrary data block
///
/// Full userdata in Lua 5.4:
/// - Raw memory block of arbitrary size
/// - Optional metatable for metamethod dispatch
/// - Up to 255 "user values" (TValues associated with the userdata)
///
/// Memory layout: [UserdataObject header][nuvalue * TValue][size bytes]
pub const UserdataObject = struct {
    const TValue = @import("../value.zig").TValue;

    header: GCObject,
    /// Size of the raw data block in bytes
    size: usize,
    /// Number of user values (0-255)
    nuvalue: u8,
    /// Optional metatable for metamethod dispatch
    metatable: ?*TableObject,

    /// Get the user values array (stored inline after struct)
    pub fn userValues(self: *UserdataObject) []TValue {
        const base = @intFromPtr(self);
        const offset = @sizeOf(UserdataObject);
        const ptr: [*]TValue = @ptrFromInt(base + offset);
        return ptr[0..self.nuvalue];
    }

    /// Get the user values array (const version)
    pub fn userValuesConst(self: *const UserdataObject) []const TValue {
        const base = @intFromPtr(self);
        const offset = @sizeOf(UserdataObject);
        const ptr: [*]const TValue = @ptrFromInt(base + offset);
        return ptr[0..self.nuvalue];
    }

    /// Get pointer to the raw data block (stored after user values)
    pub fn data(self: *UserdataObject) [*]u8 {
        const base = @intFromPtr(self);
        const offset = @sizeOf(UserdataObject) + self.nuvalue * @sizeOf(TValue);
        return @ptrFromInt(base + offset);
    }

    /// Get data as a slice
    pub fn dataSlice(self: *UserdataObject) []u8 {
        return self.data()[0..self.size];
    }

    /// Calculate total allocation size for a userdata
    pub fn allocationSize(data_size: usize, num_user_values: u8) usize {
        return @sizeOf(UserdataObject) + @as(usize, num_user_values) * @sizeOf(TValue) + data_size;
    }
};

/// Thread Status for coroutines
pub const ThreadStatus = enum(u8) {
    suspended, // Created or yielded, ready to be resumed
    running, // Currently executing
    normal, // Resumed another coroutine (waiting for it to finish)
    dead, // Finished execution or errored
};

/// Thread Object - GC-managed coroutine/thread
///
/// Represents a Lua thread (coroutine). Each thread has its own execution
/// state (stack, call stack, etc.) but shares the global environment with
/// other threads via Runtime.
///
/// The main thread is also a ThreadObject, returned by coroutine.running().
pub const ThreadObject = struct {
    header: GCObject,

    /// Coroutine status
    status: ThreadStatus,

    /// Pointer to VM execution state (actually *VM, using anyopaque to avoid circular import)
    /// The VM contains: stack, top, base, ci, callstack, open_upvalues, etc.
    vm: *anyopaque,

    /// Callback to mark VM roots (stack, callframes, upvalues, etc.)
    /// Set by VM.init. GC calls this during mark phase for coroutine threads.
    /// Main thread is marked via its RootProvider registration.
    /// Signature: fn(vm: *anyopaque, gc: *anyopaque) void
    /// Uses anyopaque for GC to avoid circular import with gc.zig.
    mark_vm: ?*const fn (*anyopaque, *anyopaque) void = null,

    /// Callback to free VM memory.
    /// Set by VM.init. GC calls this during sweep phase for coroutine threads.
    /// Main thread is freed by Runtime.deinit, not by GC.
    free_vm: ?*const fn (*anyopaque, std.mem.Allocator) void = null,

    /// Get VM pointer (casts from anyopaque)
    pub fn getVM(self: *ThreadObject) *anyopaque {
        return self.vm;
    }
};

/// Utility functions for working with GC objects
/// Get the concrete object from a GCObject header
///
/// Example usage:
/// ```zig
/// const str_obj = getObject(StringObject, gc_obj);
/// ```
pub fn getObject(comptime T: type, header: *GCObject) *T {
    return @fieldParentPtr("header", header);
}

/// Calculate the size of a GC object including extra data
pub fn objectSize(comptime T: type, extra_bytes: usize) usize {
    return @sizeOf(T) + extra_bytes;
}

/// Validate that a type is a valid GC object (has header field)
pub fn validateGCObject(comptime T: type) void {
    if (!@hasField(T, "header")) {
        @compileError("GC object type must have 'header: GCObject' as first field");
    }

    const header_field = @typeInfo(T).Struct.fields[0];
    if (!std.mem.eql(u8, header_field.name, "header")) {
        @compileError("GC object 'header' must be the first field");
    }

    if (header_field.type != GCObject) {
        @compileError("GC object header field must be of type GCObject");
    }
}
