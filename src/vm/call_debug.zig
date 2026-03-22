//! Call Debug State
//!
//! Deferred debug naming hints for the next pushed call frame.

pub const CallDebugState = struct {
    next_name: ?[]const u8 = null,
    next_namewhat: ?[]const u8 = null,
};
