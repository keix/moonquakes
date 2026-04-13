const std = @import("std");

var pending = std.atomic.Value(bool).init(false);

fn handleSigint(_: c_int) callconv(.c) void {
    pending.store(true, .seq_cst);
}

pub fn install() void {
    const posix = std.posix;
    const act: posix.Sigaction = .{
        .handler = .{ .handler = handleSigint },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);
}

pub fn isPending() bool {
    return pending.load(.acquire);
}

/// Fast check + consume: only do atomic swap if interrupt is pending
pub fn consume() bool {
    // Fast path: relaxed load first to avoid expensive atomic swap
    if (!pending.load(.monotonic)) return false;
    // Slow path: actually consume the interrupt
    return pending.swap(false, .acq_rel);
}
