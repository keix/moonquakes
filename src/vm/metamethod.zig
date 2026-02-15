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
    gc, // __gc (garbage collection finalizer)
    tostring, // __tostring
    metatable, // __metatable
    name, // __name
    pairs, // __pairs
    mode, // __mode (weak table mode)

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
            .gc => "__gc",
            .tostring => "__tostring",
            .metatable => "__metatable",
            .name => "__name",
            .pairs => "__pairs",
            .mode => "__mode",
        };
    }
};

/// Pre-allocated metamethod key strings
/// These are interned once at VM initialization and never allocated again
/// This is critical for performance - metamethod lookup must not allocate
pub const MetamethodKeys = struct {
    strings: [@typeInfo(MetaEvent).@"enum".fields.len]*StringObject,

    pub fn init(gc: *GC) !MetamethodKeys {
        var keys: MetamethodKeys = undefined;
        inline for (@typeInfo(MetaEvent).@"enum".fields, 0..) |field, i| {
            const event: MetaEvent = @enumFromInt(field.value);
            keys.strings[i] = try gc.allocString(event.key());
        }
        return keys;
    }

    /// Get the pre-allocated string for a metamethod event
    /// This is O(1) and allocation-free
    pub fn get(self: *const MetamethodKeys, event: MetaEvent) *StringObject {
        return self.strings[@intFromEnum(event)];
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
/// NOTE: This function does NOT allocate - it uses pre-interned keys
pub fn getMetamethod(value: TValue, event: MetaEvent, keys: *const MetamethodKeys) ?TValue {
    const mt = getMetatable(value) orelse return null;

    // Use pre-allocated key string - no allocation!
    const key_str = keys.get(event);

    // Look up the metamethod
    return mt.get(key_str);
}

/// Try to get a metamethod from either operand (for binary operations)
/// Lua checks the first operand first, then the second
/// NOTE: This function does NOT allocate
pub fn getBinMetamethod(a: TValue, b: TValue, event: MetaEvent, keys: *const MetamethodKeys) ?TValue {
    // Try first operand
    if (getMetamethod(a, event, keys)) |mm| {
        return mm;
    }
    // Try second operand
    return getMetamethod(b, event, keys);
}
