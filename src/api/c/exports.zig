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

pub export fn mq_gc_collect(state: ?*mq_State) void {
    const s = state orelse return;
    const real: *State = @ptrCast(@alignCast(s));
    real.vm.collectGarbage();
}

pub export fn mq_gettop(state: ?*mq_State) c_int {
    const s = state orelse return 0;
    const real: *State = @ptrCast(@alignCast(s));
    return @intCast(real.vm.top - real.vm.base);
}

pub export fn mq_settop(state: ?*mq_State, idx: c_int) void {
    const s = state orelse return;
    const real: *State = @ptrCast(@alignCast(s));
    const vm = real.vm;

    const base_i: i32 = @intCast(vm.base);
    const top_i: i32 = @intCast(vm.top);
    var new_top_i: i32 = if (idx >= 0)
        base_i + idx
    else
        top_i + idx + 1;

    if (new_top_i < base_i) new_top_i = base_i;
    const max_top_i: i32 = @intCast(vm.stack.len);
    if (new_top_i > max_top_i) new_top_i = max_top_i;

    const new_top: u32 = @intCast(new_top_i);
    if (new_top > vm.top) {
        var i: u32 = vm.top;
        while (i < new_top) : (i += 1) {
            vm.stack[i] = .nil;
        }
    }
    vm.top = new_top;
}
