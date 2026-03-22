//! Yield State
//!
//! Suspension metadata used to resume coroutines after `coroutine.yield`.

pub const YieldState = struct {
    base: u32 = 0,
    count: u32 = 0,
    ret_base: u32 = 0,
    nresults: i32 = 0, // -1 = variable results
    from_tailcall: bool = false,
};
