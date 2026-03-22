//! Field Cache State
//!
//! Small optimization cache for recent field access context and integer
//! representation diagnostics.

const StringObject = @import("../runtime/gc/object.zig").StringObject;

pub const FieldCache = struct {
    last_field_reg: ?u8 = null,
    last_field_key: ?*StringObject = null,
    last_field_is_global: bool = false,
    last_field_is_method: bool = false,
    last_field_tick: u64 = 0,
    int_repr_field_key: ?*StringObject = null,
    exec_tick: u64 = 0,
};
