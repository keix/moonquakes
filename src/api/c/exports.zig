//! Moonquakes C API Exports
//!
//! Aggregated exports for the C interface.

pub const constants = @import("constants.zig");

const std = @import("std");
const mq = @import("moonquakes");

const VM = mq.VM;
const Runtime = mq.Runtime;

const State = struct {
    vm: *VM,
};

pub const mq_State = opaque {};

pub export fn mq_version() [*:0]const u8 {
    return mq.version;
}

pub export fn mq_newstate() ?*mq_State {
    const allocator = std.heap.c_allocator;

    const rt = Runtime.init(allocator) catch return null;
    const vm = VM.init(rt) catch {
        rt.deinit();
        return null;
    };

    const state = allocator.create(State) catch {
        vm.deinit();
        rt.deinit();
        return null;
    };

    state.* = .{
        .vm = vm,
    };
    return @as(*mq_State, @ptrCast(state));
}

pub export fn mq_close(state: ?*mq_State) void {
    const s = state orelse return;
    const real: *State = @ptrCast(@alignCast(s));

    real.vm.deinit();
    real.vm.rt.deinit();

    std.heap.c_allocator.destroy(real);
}
