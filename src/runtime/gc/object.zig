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
};

/// Common header for all GC-managed objects
///
/// This header must be the first field in every GC object struct.
/// It provides the infrastructure for mark-and-sweep collection.
pub const GCObject = struct {
    /// Object type for dispatch in mark/sweep phases
    type: GCObjectType,

    /// Mark bit for garbage collection
    /// true = reachable, false = potentially garbage
    marked: bool,

    /// Linked list pointer for tracking all objects
    /// The GC maintains a list of all allocated objects
    next: ?*GCObject,

    /// Initialize a GC object header
    pub fn init(object_type: GCObjectType, next_obj: ?*GCObject) GCObject {
        return .{
            .type = object_type,
            .marked = false,
            .next = next_obj,
        };
    }

    /// Mark this object as reachable
    pub fn mark(self: *GCObject) void {
        self.marked = true;
    }

    /// Clear the mark (for next collection cycle)
    pub fn unmark(self: *GCObject) void {
        self.marked = false;
    }

    /// Check if object is marked
    pub fn isMarked(self: *const GCObject) bool {
        return self.marked;
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
/// Uses StringObject pointers as keys for GC safety.
/// Array part will be added later.
pub const TableObject = struct {
    const TValue = @import("../value.zig").TValue;

    /// Custom hash context for StringObject pointer keys
    /// Uses pre-computed hash and pointer equality (assumes interned strings)
    pub const StringKeyContext = struct {
        pub fn hash(_: StringKeyContext, key: *const StringObject) u64 {
            return key.hash;
        }

        pub fn eql(_: StringKeyContext, a: *const StringObject, b: *const StringObject) bool {
            return a == b; // Pointer equality (interned strings)
        }
    };

    pub const HashMap = std.HashMap(
        *const StringObject,
        TValue,
        StringKeyContext,
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

    /// Get a value by StringObject key
    pub fn get(self: *const TableObject, key: *const StringObject) ?TValue {
        return self.hash_part.get(key);
    }

    /// Set a value by StringObject key
    pub fn set(self: *TableObject, key: *const StringObject, value: TValue) !void {
        try self.hash_part.put(key, value);
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
