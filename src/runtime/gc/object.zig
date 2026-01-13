const std = @import("std");

/// Types of GC-managed objects
pub const GCObjectType = enum(u8) {
    string,
    table,
    function,
    userdata,
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
/// Example: Table Object (future implementation)
///
/// ```zig
/// pub const TableObject = struct {
///     header: GCObject,
///     array_part: ?[]TValue,
///     hash_part: ?HashMap(*StringObject, TValue),
///
///     // Implementation details...
/// };
/// ```
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
