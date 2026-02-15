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
///
/// TODO: Consider moving to GC (global state) when implementing coroutines.
/// Currently in VM, but mm_keys are just pointers to interned strings in GC,
/// so sharing works correctly. Moving to GC would be cleaner architecturally.
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

/// Shared metatables for primitive types (string, number, boolean, etc.)
/// These are global to the VM state and set via debug.setmetatable()
/// Unlike table metatables, these are shared across all values of that type
///
/// Stored in GC (global state) so coroutines share the same metatables.
pub const SharedMetatables = struct {
    string: ?*TableObject = null,
    number: ?*TableObject = null,
    boolean: ?*TableObject = null,
    function: ?*TableObject = null, // For closures/native closures
    nil: ?*TableObject = null, // Lua 5.4 supports this via debug.setmetatable

    /// Get shared metatable for a primitive type based on value
    pub fn getForValue(self: *const SharedMetatables, value: TValue) ?*TableObject {
        if (value.isNil()) {
            return self.nil;
        }
        if (value.isBoolean()) {
            return self.boolean;
        }
        if (value.isInteger() or value.isNumber()) {
            return self.number;
        }
        if (value.asString()) |_| {
            return self.string;
        }
        if (value.asClosure()) |_| {
            return self.function;
        }
        if (value.isObject()) {
            const obj = value.object;
            if (obj.type == .native_closure) {
                return self.function;
            }
        }
        return null;
    }

    /// Set shared metatable for a primitive type
    /// Returns true if the type supports shared metatables (non-table types)
    pub fn setForValue(self: *SharedMetatables, value: TValue, mt: ?*TableObject) bool {
        if (value.isNil()) {
            self.nil = mt;
            return true;
        }
        if (value.isBoolean()) {
            self.boolean = mt;
            return true;
        }
        if (value.isInteger() or value.isNumber()) {
            self.number = mt;
            return true;
        }
        if (value.asString()) |_| {
            self.string = mt;
            return true;
        }
        if (value.asClosure()) |_| {
            self.function = mt;
            return true;
        }
        if (value.isObject()) {
            const obj = value.object;
            if (obj.type == .native_closure) {
                self.function = mt;
                return true;
            }
        }
        return false;
    }
};

/// Get the metatable for a value
/// - Tables: return table's individual metatable
/// - Userdata: return userdata's individual metatable
/// - Primitives: return shared metatable from GC
pub fn getMetatable(value: TValue, shared: *const SharedMetatables) ?*TableObject {
    // Tables have their own metatables
    if (value.asTable()) |table| {
        return table.metatable;
    }
    // Userdata has its own metatable
    if (value.asUserdata()) |ud| {
        return ud.metatable;
    }
    // Primitive types use shared metatables
    return shared.getForValue(value);
}

/// Look up a metamethod in a value's metatable
/// Returns the metamethod value if found, null otherwise
/// NOTE: This function does NOT allocate - it uses pre-interned keys
pub fn getMetamethod(value: TValue, event: MetaEvent, keys: *const MetamethodKeys, shared: *const SharedMetatables) ?TValue {
    const mt = getMetatable(value, shared) orelse return null;

    // Use pre-allocated key string - no allocation!
    const key_str = keys.get(event);

    // Look up the metamethod
    return mt.get(key_str);
}

/// Try to get a metamethod from either operand (for binary operations)
/// Lua checks the first operand first, then the second
/// NOTE: This function does NOT allocate
pub fn getBinMetamethod(a: TValue, b: TValue, event: MetaEvent, keys: *const MetamethodKeys, shared: *const SharedMetatables) ?TValue {
    // Try first operand
    if (getMetamethod(a, event, keys, shared)) |mm| {
        return mm;
    }
    // Try second operand
    return getMetamethod(b, event, keys, shared);
}
