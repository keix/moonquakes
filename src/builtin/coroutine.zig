//! Coroutine-library builtin functions and resume/yield helpers.
//!
//! Shared helper logic stays near the top of the file.
//! Dispatcher entrypoints are grouped below.

const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");
const ThreadStatus = object.ThreadStatus;
const NativeFn = @import("../runtime/native.zig").NativeFn;
const Instruction = @import("../compiler/opcodes.zig").Instruction;
const VM = @import("../vm/vm.zig").VM;
const CallInfo = @import("../vm/execution.zig").CallInfo;
const error_state = @import("../vm/error_state.zig");
const hook_state = @import("../vm/hook.zig");
const mnemonics = @import("../vm/mnemonics.zig");
const vm_gc = @import("../vm/gc.zig");
const synthetic_frame = @import("../vm/synthetic_frame.zig");
const yield_state = @import("../vm/yield.zig");

// Bootstrap frame for first coroutine resume:
//   CALL   R0, ... (body + resume args)
//   RETURN R0, ... (propagate all results)
// This keeps first resume on the same CALL/RETURN path as normal execution.
//
// Ownership model:
// - This proto is runtime-owned immutable static data (not GC-allocated).
// - It is intentionally never freed and reused by all coroutine starts.
// - GC may traverse it through CallInfo.func (closure=null path), which is safe
//   because its code/metadata slices are also static immutable storage.
var coroutine_bootstrap_proto = synthetic_frame.initCallReturnProto("[coroutine bootstrap]", 2);

// Guard native recursion through coroutine.resume chains to avoid host stack crashes.
const resume_c_depth_limit: u32 = 197;

fn threadEntryBody(thread: *object.ThreadObject, co_vm: *VM) TValue {
    if (thread.entry_func) |entry_fn| return .{ .object = entry_fn };
    return co_vm.stack[0];
}

/// Result of coroutine execution
const CoroutineResult = union(enum) {
    completed: u32,
    yielded: yield_state.YieldResult,
    errored: TValue,
};

const CoroutineLuaExceptionResult = union(enum) {
    disposition: mnemonics.LuaExceptionDisposition,
    yielded: yield_state.YieldResult,
};

const CoroutineInstructionStep = union(enum) {
    continue_loop,
    completed: u32,
    yielded: yield_state.YieldResult,
    errored: TValue,
};

fn writeCoroutinePayload(
    vm: *VM,
    result_base: u32,
    nresults: u32,
    payload_base: u32,
    payload_count: u32,
    comptime include_success_flag: bool,
    source_stack: []TValue,
) void {
    const prefix: u32 = if (include_success_flag) 1 else 0;
    if (include_success_flag) {
        vm.stack[result_base] = .{ .boolean = true };
    }

    const stack_room: u32 = @intCast(vm.stack.len - result_base);
    const payload_room: u32 = if (stack_room > prefix) stack_room - prefix else 0;
    const expected_payload: u32 = if (nresults == 0)
        0
    else if (nresults > prefix)
        @min(nresults - prefix, payload_room)
    else
        0;
    const max_copy: u32 = if (nresults == 0) payload_room else expected_payload;
    const actual_copy = @min(payload_count, max_copy);

    var j: u32 = 0;
    while (j < actual_copy) : (j += 1) {
        vm.stack[result_base + prefix + j] = source_stack[payload_base + j];
    }
    if (nresults > 0 and actual_copy < expected_payload) {
        var k = actual_copy;
        while (k < expected_payload) : (k += 1) {
            vm.stack[result_base + prefix + k] = .nil;
        }
    }
    vm.top = if (nresults == 0)
        result_base + prefix + actual_copy
    else
        result_base + prefix + expected_payload;
}

fn writeCoroutineStatusResult(vm: *VM, result_base: u32, ok: bool, err_val: ?TValue, nresults: u32) void {
    vm.stack[result_base] = .{ .boolean = ok };
    if (err_val) |err| {
        vm.stack[result_base + 1] = err;
        vm.top = if (nresults == 0) result_base + 2 else result_base + @min(@as(u32, 2), nresults);
        return;
    }

    if (nresults > 1) {
        var i: u32 = 1;
        while (i < nresults) : (i += 1) {
            vm.stack[result_base + i] = .nil;
        }
    }
    vm.top = if (nresults == 0) result_base + 1 else result_base + @min(@as(u32, 1), nresults);
}

// Coroutine execution keeps shared LuaException semantics, then converts them
// into the resume protocol's yielded/errored shape.
fn handleCoroutineLuaException(co_vm: *VM) CoroutineLuaExceptionResult {
    const disposition = mnemonics.classifyLuaException(co_vm, null) catch |herr| switch (herr) {
        error.Yield => return .{ .yielded = yield_state.currentResult(co_vm) },
    };
    return .{ .disposition = disposition };
}

const CoroutineUnwindResult = union(enum) {
    done,
    yielded: yield_state.YieldResult,
};

fn unwindCoroutineErrorFrames(co_vm: *VM, err_obj: TValue) CoroutineUnwindResult {
    while (co_vm.ci) |unwind_ci| {
        mnemonics.popErrorFrame(co_vm, unwind_ci, err_obj) catch |err| switch (err) {
            error.Yield => return .{ .yielded = yield_state.currentResult(co_vm) },
        };
        if (co_vm.callstack_size == 0) {
            co_vm.ci = null;
            break;
        }
    }
    return .done;
}

fn convertCoroutineVmRuntimeError(co_vm: *VM, inst: Instruction, err: anyerror) ?TValue {
    var msg_buf: [128]u8 = undefined;
    const msg = mnemonics.formatVmRuntimeErrorMessage(co_vm, inst, err, &msg_buf);
    var full_msg_buf: [320]u8 = undefined;
    const full_msg = mnemonics.runtimeErrorWithCurrentLocation(co_vm, inst, err, msg, &full_msg_buf);
    const msg_obj = co_vm.gc().allocString(full_msg) catch return null;
    return TValue.fromString(msg_obj);
}

fn finishCoroutineReturn(co_vm: *VM, ret_val: @import("../vm/execution.zig").ReturnValue) ?CoroutineInstructionStep {
    if (co_vm.ci) |current_ci| {
        if (current_ci.previous == null) {
            return switch (ret_val) {
                .none => .{ .completed = 0 },
                .single => |val| blk: {
                    co_vm.stack[0] = val;
                    break :blk .{ .completed = 1 };
                },
                .multiple => |vals| blk: {
                    for (vals, 0..) |val, i| {
                        co_vm.stack[i] = val;
                    }
                    break :blk .{ .completed = @intCast(vals.len) };
                },
            };
        }
    }
    return null;
}

fn runCoroutineInstruction(co_vm: *VM, inst: Instruction) CoroutineInstructionStep {
    const exec_result = mnemonics.do(co_vm, inst) catch |err| {
        if (err == error.HandledException) return .continue_loop;
        if (err == error.LuaException) {
            switch (handleCoroutineLuaException(co_vm)) {
                .disposition => |d| switch (d) {
                    .continue_loop => return .continue_loop,
                    .handled_at_boundary => return .continue_loop,
                    .unhandled => {},
                },
                .yielded => |yielded| return .{ .yielded = yielded },
            }
            switch (unwindCoroutineErrorFrames(co_vm, error_state.getRaisedValue(co_vm))) {
                .done => {},
                .yielded => |yielded| return .{ .yielded = yielded },
            }
            return .{ .errored = error_state.getRaisedValue(co_vm) };
        }
        if (err == error.Yield) {
            hook_state.onReturnOnYield(co_vm, mnemonics.executeSyncMM) catch {};
            return .{ .yielded = yield_state.currentResult(co_vm) };
        }
        if (mnemonics.isVmRuntimeError(err)) {
            const raised = convertCoroutineVmRuntimeError(co_vm, inst, err) orelse return .{ .errored = .nil };
            error_state.setRaisedValue(co_vm, raised);
            switch (handleCoroutineLuaException(co_vm)) {
                .disposition => |d| switch (d) {
                    .continue_loop => return .continue_loop,
                    .handled_at_boundary => return .continue_loop,
                    .unhandled => return .{ .errored = error_state.getRaisedValue(co_vm) },
                },
                .yielded => |yielded| return .{ .yielded = yielded },
            }
        }

        const err_str = co_vm.gc().allocString(@errorName(err)) catch return .{ .errored = .nil };
        return .{ .errored = TValue.fromString(err_str) };
    };

    return switch (exec_result) {
        .Continue, .LoopContinue => .continue_loop,
        .ReturnVM => |ret_val| finishCoroutineReturn(co_vm, ret_val) orelse .continue_loop,
    };
}

/// Set up coroutine for first resume (initialize call frame)
fn setupFirstResume(co_vm: *VM, caller_stack: []TValue, arg_base: u32, num_args: u32) void {
    // Copy arguments to coroutine stack
    var i: u32 = 0;
    while (i < num_args) : (i += 1) {
        co_vm.stack[1 + i] = caller_stack[arg_base + i];
    }

    // Bootstrap frame executes CALL/RETURN at base 0.
    co_vm.base = 0;
    co_vm.top = 1 + num_args;
    co_vm.base_ci = CallInfo.initRoot(
        &coroutine_bootstrap_proto,
        // Bootstrap bytecode is CALL/RETURN only; no upvalue/env opcodes.
        null,
        0,
        0,
        -1,
        0,
        0,
    );
    co_vm.ci = &co_vm.base_ci;
}

/// Set up coroutine for resume after yield (pass values to yield return)
fn setupResumeAfterYield(co_vm: *VM, caller_stack: []TValue, arg_base: u32, num_args: u32) void {
    yield_state.resumeWithValues(co_vm, caller_stack, arg_base, num_args, mnemonics.popCallInfo);
}

/// Execute coroutine until completion or yield
fn executeCoroutine(co_vm: *VM) CoroutineResult {
    // Execute instructions until we return from the main function
    while (co_vm.ci != null) {
        if (error_state.hasPendingUnwindAtCurrentFrame(co_vm)) {
            switch (handleCoroutineLuaException(co_vm)) {
                .disposition => |d| switch (d) {
                    .continue_loop => continue,
                    .handled_at_boundary => continue,
                    .unhandled => return .{ .errored = error_state.getRaisedValue(co_vm) },
                },
                .yielded => |yielded| return .{ .yielded = yielded },
            }
        }
        const ci = co_vm.ci.?;
        const step = mnemonics.advanceFrame(co_vm, ci, false) catch |cerr| switch (cerr) {
            error.Yield => return .{ .yielded = yield_state.currentResult(co_vm) },
            else => return .{ .errored = error_state.getRaisedValue(co_vm) },
        };
        switch (step) {
            .continue_loop => continue,
            .top_frame_exhausted => return .{ .completed = co_vm.top },
            .instruction => |inst| {
                switch (runCoroutineInstruction(co_vm, inst)) {
                    .continue_loop => continue,
                    .completed => |count| return .{ .completed = count },
                    .yielded => |yielded| return .{ .yielded = yielded },
                    .errored => |err_val| return .{ .errored = err_val },
                }
            },
        }
    }

    // ci became null without explicit return - treat as empty return
    return .{ .completed = 0 };
}

// Lua 5.4 Coroutine Library
// Reference: https://www.lua.org/manual/5.4/manual.html#2.6

/// coroutine.create(f) - Creates a new coroutine with body f
pub fn nativeCoroutineCreate(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nresults;

    if (nargs < 1) {
        return vm.raiseString("bad argument #1 to 'create' (function expected)");
    }

    const func_arg = vm.stack[vm.base + func_reg + 1];
    if (!func_arg.isCallable()) {
        return vm.raiseString("bad argument #1 to 'create' (function expected)");
    }

    const new_vm = try VM.init(vm.rt);
    new_vm.stack[0] = func_arg;
    new_vm.top = 1;
    new_vm.thread.entry_func = if (func_arg == .object) func_arg.object else null;
    if (new_vm.thread.entry_func) |entry_fn| {
        vm.gc().barrierBack(&new_vm.thread.header, entry_fn);
    }

    vm.stack[vm.base + func_reg] = TValue.fromThread(new_vm.thread);
}

/// coroutine.resume(co [, val1, ...]) - Starts or continues coroutine co
/// Returns (true, results...) on success, (false, error_message) on failure
pub fn nativeCoroutineResume(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    vm.beginGCGuard();
    defer vm.endGCGuard();
    const result_base = vm.base + func_reg;

    if (nargs < 1) {
        return vm.raiseString("bad argument #1 to 'resume' (thread expected)");
    }

    const thread_arg = vm.stack[vm.base + func_reg + 1];
    const thread = thread_arg.asThread() orelse {
        return vm.raiseString("bad argument #1 to 'resume' (thread expected)");
    };

    if (vm.rt.resume_c_depth >= resume_c_depth_limit) {
        writeCoroutineStatusResult(vm, result_base, false, TValue.fromString(try vm.gc().allocString("C stack overflow")), nresults);
        return;
    }
    vm.rt.resume_c_depth += 1;
    defer vm.rt.resume_c_depth -= 1;

    if (thread.status == .dead) {
        writeCoroutineStatusResult(vm, result_base, false, TValue.fromString(try vm.gc().allocString("cannot resume dead coroutine")), nresults);
        return;
    }

    if (thread.status == .running or thread.status == .normal) {
        writeCoroutineStatusResult(vm, result_base, false, TValue.fromString(try vm.gc().allocString("cannot resume non-suspended coroutine")), nresults);
        return;
    }

    const co_vm: *VM = @ptrCast(@alignCast(thread.vm));
    const num_args: u32 = if (nargs > 1) nargs - 1 else 0;
    const arg_base = vm.base + func_reg + 2;
    const is_first_resume = thread.status == .created;
    const body = threadEntryBody(thread, co_vm);

    if (is_first_resume) {
        co_vm.stack[0] = body;
        const is_lua_body = body.asClosure() != null;
        const is_native_body = body.isObject() and body.object.type == .native_closure;
        if (!is_lua_body and !is_native_body) {
            writeCoroutineStatusResult(vm, result_base, false, TValue.fromString(try vm.gc().allocString("coroutine body must be a Lua function")), nresults);
            return;
        }
        setupFirstResume(co_vm, &vm.stack, arg_base, num_args);
    } else {
        setupResumeAfterYield(co_vm, &vm.stack, arg_base, num_args);
    }

    const caller_thread = vm.thread;
    caller_thread.status = .normal;
    thread.status = .running;
    vm.rt.setCurrentThread(thread);
    vm.rt.gc.setFinalizerExecutor(vm_gc.finalizerExecutor(co_vm));

    const exec_result = executeCoroutine(co_vm);

    caller_thread.status = .running;
    vm.rt.setCurrentThread(caller_thread);
    vm.rt.gc.setFinalizerExecutor(vm_gc.finalizerExecutor(vm));

    switch (exec_result) {
        .completed => |result_count| {
            thread.status = .dead;
            writeCoroutinePayload(vm, result_base, nresults, 0, result_count, true, &co_vm.stack);
        },
        .yielded => |yield_info| {
            thread.status = .suspended;
            writeCoroutinePayload(vm, result_base, nresults, yield_info.base, yield_info.count, true, &co_vm.stack);
        },
        .errored => |err_val| {
            thread.status = .dead;
            writeCoroutineStatusResult(vm, result_base, false, err_val, nresults);
        },
    }
}

/// coroutine.running() - Returns running coroutine plus boolean indicating main thread
/// Returns (thread, is_main) where is_main is true if this is the main coroutine
pub fn nativeCoroutineRunning(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;

    // Get the current thread (this VM's thread)
    const current_thread = vm.thread;
    const is_main = vm.isMainThread();

    // Return the thread
    if (nresults >= 1) {
        vm.stack[vm.base + func_reg] = TValue.fromThread(current_thread);
    }

    // Return whether this is the main thread
    if (nresults >= 2) {
        vm.stack[vm.base + func_reg + 1] = .{ .boolean = is_main };
    }
}

/// coroutine.status(co) - Returns status of coroutine co
/// Returns "running", "suspended", "normal", or "dead"
pub fn nativeCoroutineStatus(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    // Validate argument first (before checking nresults)
    if (nargs < 1) {
        return vm.raiseString("bad argument #1 to 'status' (thread expected)");
    }

    const thread_arg = vm.stack[vm.base + func_reg + 1];
    const thread = thread_arg.asThread() orelse {
        return vm.raiseString("bad argument #1 to 'status' (thread expected)");
    };

    if (nresults == 0) return;

    const status_str: []const u8 = switch (thread.status) {
        .running => "running",
        .created, .suspended => "suspended",
        .normal => "normal",
        .dead => "dead",
    };

    const str_obj = try vm.gc().allocString(status_str);
    vm.stack[vm.base + func_reg] = TValue.fromString(str_obj);
}

/// coroutine.wrap(f) - Creates a coroutine and returns a function that resumes it
/// Like create but returns function instead of thread
/// Returns a function that, when called, resumes the coroutine and returns the results.
/// If the coroutine errors, the error is propagated (unlike resume which returns false).
pub fn nativeCoroutineWrap(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nresults;

    if (nargs < 1) {
        return vm.raiseString("bad argument #1 to 'wrap' (function expected)");
    }

    const func_arg = vm.stack[vm.base + func_reg + 1];

    // Must be a function (closure or native closure)
    if (!func_arg.isCallable()) {
        return vm.raiseString("bad argument #1 to 'wrap' (function expected)");
    }

    // Create a new VM for the coroutine (same as create)
    const new_vm = try VM.init(vm.rt);
    new_vm.stack[0] = func_arg;
    new_vm.top = 1;
    new_vm.thread.entry_func = if (func_arg == .object) func_arg.object else null;
    if (new_vm.thread.entry_func) |entry_fn| {
        vm.gc().barrierBack(&new_vm.thread.header, entry_fn);
    }

    // CRITICAL: Protect the new thread from GC before any more allocations.
    // VM.init may increase bytes_allocated (if tracking enabled), and subsequent
    // allocations might trigger GC. The thread is not yet reachable from any root.
    _ = vm.pushTempRoot(TValue.fromThread(new_vm.thread));
    defer vm.popTempRoots(1);

    // Create wrapper table to store the thread
    // Must protect intermediate allocations from GC during multi-allocation sequence
    const wrapper = try vm.gc().allocTable();
    _ = vm.pushTempRoot(TValue.fromTable(wrapper));
    defer vm.popTempRoots(1);

    // Store thread at index 1
    try object.tableSetWithBarrier(vm.gc(), wrapper, .{ .integer = 1 }, TValue.fromThread(new_vm.thread));

    // Create metatable with __call
    const metatable = try vm.gc().allocTable();
    _ = vm.pushTempRoot(TValue.fromTable(metatable));
    defer vm.popTempRoots(1);

    const call_key = try vm.gc().allocString("__call");
    const call_fn = try vm.gc().allocNativeClosure(NativeFn.init(.coroutine_wrap_call));
    try object.tableSetWithBarrier(vm.gc(), metatable, TValue.fromString(call_key), TValue.fromNativeClosure(call_fn));

    // Set metatable
    object.tableSetMetatableWithBarrier(vm.gc(), wrapper, metatable);

    // Return the wrapper table (acts as function due to __call)
    vm.stack[vm.base + func_reg] = TValue.fromTable(wrapper);
}

/// Internal: __call handler for wrapped coroutine
/// Called when a wrapped coroutine is invoked as a function
pub fn nativeCoroutineWrapCall(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    vm.beginGCGuard();
    defer vm.endGCGuard();
    const result_base = vm.base + func_reg;

    if (vm.rt.resume_c_depth >= resume_c_depth_limit) {
        return vm.raiseString("C stack overflow");
    }
    vm.rt.resume_c_depth += 1;
    defer vm.rt.resume_c_depth -= 1;

    // __call is invoked as a native function.
    // Preferred layout: function at func_reg, wrapper at func_reg+1, user args after that.
    // For compatibility with older call paths, also accept wrapper at func_reg.
    var wrapper_slot = vm.base + func_reg + 1;
    if (nargs == 0 or !vm.stack[wrapper_slot].isObject() or vm.stack[wrapper_slot].object.type != .table) {
        wrapper_slot = vm.base + func_reg;
    }

    const wrapper_val = vm.stack[wrapper_slot];
    const wrapper = wrapper_val.asTable() orelse return vm.raiseString("invalid wrapped coroutine");

    // Get thread from wrapper[1]
    const thread_val = wrapper.get(.{ .integer = 1 }) orelse {
        return vm.raiseString("invalid wrapped coroutine (no thread)");
    };
    const thread = thread_val.asThread() orelse {
        return vm.raiseString("invalid wrapped coroutine (not a thread)");
    };

    // Check if the coroutine can be resumed
    if (thread.status == .dead) {
        return vm.raiseString("cannot resume dead coroutine");
    }

    if (thread.status == .running) {
        if (thread == vm.thread and error_state.isClosingMetamethod(vm)) {
            writeCoroutineStatusResult(vm, result_base, false, TValue.fromString(try vm.gc().allocString("cannot resume non-suspended coroutine")), nresults);
            return;
        }
        return vm.raiseString("cannot resume non-suspended coroutine");
    }
    if (thread.status == .normal) {
        if (thread == vm.thread and error_state.isClosingMetamethod(vm)) {
            writeCoroutineStatusResult(vm, result_base, false, TValue.fromString(try vm.gc().allocString("cannot resume non-suspended coroutine")), nresults);
            return;
        }
        return vm.raiseString("cannot resume non-suspended coroutine");
    }

    const co_vm: *VM = @ptrCast(@alignCast(thread.vm));
    const num_args: u32 = if (nargs > 0) nargs - 1 else 0;
    const arg_base = wrapper_slot + 1;
    const is_first_resume = thread.status == .created;
    const body = threadEntryBody(thread, co_vm);

    if (is_first_resume) {
        // First resume
        co_vm.stack[0] = body;
        const is_lua_body = body.asClosure() != null;
        const is_native_body = body.isObject() and body.object.type == .native_closure;
        if (!is_lua_body and !is_native_body) {
            return vm.raiseString("coroutine body must be a Lua function");
        }
        setupFirstResume(co_vm, &vm.stack, arg_base, num_args);
    } else {
        // Resume after yield
        setupResumeAfterYield(co_vm, &vm.stack, arg_base, num_args);
    }

    // Update statuses and execute
    const caller_thread = vm.thread;
    caller_thread.status = .normal;
    thread.status = .running;
    vm.rt.setCurrentThread(thread);
    vm.rt.gc.setFinalizerExecutor(vm_gc.finalizerExecutor(co_vm));

    const exec_result = executeCoroutine(co_vm);

    caller_thread.status = .running;
    vm.rt.setCurrentThread(caller_thread);
    vm.rt.gc.setFinalizerExecutor(vm_gc.finalizerExecutor(vm));

    // Handle result - wrap propagates errors instead of returning false
    switch (exec_result) {
        .completed => |result_count| {
            thread.status = .dead;
            writeCoroutinePayload(vm, result_base, nresults, 0, result_count, false, &co_vm.stack);
        },
        .yielded => |yield_info| {
            thread.status = .suspended;
            writeCoroutinePayload(vm, result_base, nresults, yield_info.base, yield_info.count, false, &co_vm.stack);
        },
        .errored => |err_val| {
            thread.status = .dead;
            // Propagate the error (unlike resume which returns false)
            error_state.setRaisedValue(vm, err_val);
            return error.LuaException;
        },
    }
}

/// coroutine.yield(...) - Suspends execution of calling coroutine
/// Can only be called from inside a coroutine (not main thread)
/// Returns the values passed to the next resume call
pub fn nativeCoroutineYield(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    // Check if we're in the main thread (cannot yield from main)
    if (vm.isMainThread()) {
        return vm.raiseString("attempt to yield from outside a coroutine");
    }

    const ci = vm.ci orelse return vm.raiseString("attempt to yield from outside a coroutine");
    _ = ci;
    yield_state.saveSuspendPoint(vm, func_reg, nargs, nresults);

    // Suspend execution - will be caught by executeCoroutine
    return error.Yield;
}

/// coroutine.isyieldable() - Returns true if running coroutine can yield
/// Returns false for main thread
pub fn nativeCoroutineIsYieldable(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    const can_yield = blk: {
        if (nargs >= 1) {
            const thread_arg = vm.stack[vm.base + func_reg + 1];
            const thread = thread_arg.asThread() orelse {
                return vm.raiseString("bad argument #1 to 'isyieldable' (thread expected)");
            };
            if (vm.rt.main_thread) |main_thread| {
                if (thread == main_thread) break :blk false;
            }
            break :blk switch (thread.status) {
                .dead, .normal => false,
                .created, .suspended => true,
                .running => thread == vm.thread and !vm.isMainThread() and vm.errors.native_call_depth <= 1,
            };
        }
        break :blk !vm.isMainThread() and vm.errors.native_call_depth <= 1;
    };

    vm.stack[vm.base + func_reg] = .{ .boolean = can_yield };
}

/// coroutine.close(co) - Closes coroutine co (Lua 5.4 feature)
/// Closes coroutine and runs to-be-closed variables
pub fn nativeCoroutineClose(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    vm.beginGCGuard();
    defer vm.endGCGuard();

    const result_base = vm.base + func_reg;

    if (nargs < 1) {
        return vm.raiseString("bad argument #1 to 'close' (thread expected)");
    }

    const thread_arg = vm.stack[result_base + 1];
    const thread = thread_arg.asThread() orelse {
        return vm.raiseString("bad argument #1 to 'close' (thread expected)");
    };

    if (vm.rt.resume_c_depth >= resume_c_depth_limit) {
        const err_str = try vm.gc().allocString("C stack overflow");
        writeCoroutineStatusResult(vm, result_base, false, TValue.fromString(err_str), nresults);
        return;
    }
    vm.rt.resume_c_depth += 1;
    defer vm.rt.resume_c_depth -= 1;

    const co_vm: *VM = @ptrCast(@alignCast(thread.vm));

    // Reentrant self-close while running __close must fail.
    if (thread == vm.thread and error_state.isClosingMetamethod(vm)) {
        return vm.raiseString("cannot close a running coroutine");
    }

    // Can only close suspended or dead coroutines.
    if (thread.status == .running) {
        return vm.raiseString("cannot close a running coroutine");
    }
    if (thread.status == .normal) {
        return vm.raiseString("cannot close a normal coroutine");
    }

    // Dead coroutines: first close after an unhandled error returns that error.
    if (thread.status == .dead) {
        if (!error_state.getRaisedValue(co_vm).isNil()) {
            const err_val = error_state.takeRaisedValue(co_vm);
            writeCoroutineStatusResult(vm, result_base, false, err_val, nresults);
            return;
        }
        writeCoroutineStatusResult(vm, result_base, true, null, nresults);
        return;
    }

    // Closing a suspended coroutine must run pending to-be-closed variables.
    if (thread.status == .suspended) {
        while (co_vm.ci) |unwind_ci| {
            mnemonics.closeTBCVariables(co_vm, unwind_ci, 0, .nil) catch |cerr| switch (cerr) {
                error.LuaException => {
                    thread.status = .dead;
                    const err_val = error_state.takeRaisedValue(co_vm);
                    writeCoroutineStatusResult(vm, result_base, false, err_val, nresults);
                    return;
                },
                else => return cerr,
            };
            co_vm.closeUpvalues(unwind_ci.base);
            if (unwind_ci.previous != null) {
                mnemonics.popCallInfo(co_vm);
            } else {
                co_vm.ci = null;
                co_vm.callstack_size = 0;
                break;
            }
        }
    }

    thread.status = .dead;
    writeCoroutineStatusResult(vm, result_base, true, null, nresults);
}
