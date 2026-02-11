const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");
const TableObject = object.TableObject;
const StringObject = object.StringObject;
const GC = @import("../runtime/gc/gc.zig").GC;

/// Metamethod event names
/// These correspond to Lua's metamethod keys (__add, __sub, etc.)
pub const MetaEvent = enum {
    // Arithmetic
    add, // __add
    sub, // __sub
    mul, // __mul
    div, // __div
    mod, // __mod
    pow, // __pow
    unm, // __unm
    idiv, // __idiv
    // Bitwise
    band, // __band
    bor, // __bor
    bxor, // __bxor
    bnot, // __bnot
    shl, // __shl
    shr, // __shr
    // Comparison
    eq, // __eq
    lt, // __lt
    le, // __le
    // Other
    concat, // __concat
    len, // __len
    index, // __index
    newindex, // __newindex
    call, // __call
    close, // __close (Lua 5.4 to-be-closed)

    /// Get the metamethod key string for this event
    pub fn key(self: MetaEvent) []const u8 {
        return switch (self) {
            .add => "__add",
            .sub => "__sub",
            .mul => "__mul",
            .div => "__div",
            .mod => "__mod",
            .pow => "__pow",
            .unm => "__unm",
            .idiv => "__idiv",
            .band => "__band",
            .bor => "__bor",
            .bxor => "__bxor",
            .bnot => "__bnot",
            .shl => "__shl",
            .shr => "__shr",
            .eq => "__eq",
            .lt => "__lt",
            .le => "__le",
            .concat => "__concat",
            .len => "__len",
            .index => "__index",
            .newindex => "__newindex",
            .call => "__call",
            .close => "__close",
        };
    }
};

/// Get the metatable for a value
/// Returns null if the value has no metatable
pub fn getMetatable(value: TValue) ?*TableObject {
    if (value.asTable()) |table| {
        return table.metatable;
    }
    // TODO: Support shared metatables for strings, numbers, etc.
    return null;
}

/// Look up a metamethod in a value's metatable
/// Returns the metamethod value if found, null otherwise
pub fn getMetamethod(value: TValue, event: MetaEvent, gc: *GC) !?TValue {
    const mt = getMetatable(value) orelse return null;

    // Get the metamethod key string
    const key_str = try gc.allocString(event.key());

    // Look up the metamethod
    return mt.get(key_str);
}

/// Try to get a metamethod from either operand (for binary operations)
/// Lua checks the first operand first, then the second
pub fn getBinMetamethod(a: TValue, b: TValue, event: MetaEvent, gc: *GC) !?TValue {
    // Try first operand
    if (try getMetamethod(a, event, gc)) |mm| {
        return mm;
    }
    // Try second operand
    return try getMetamethod(b, event, gc);
}
