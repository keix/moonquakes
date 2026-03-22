const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");
const ThreadStatus = object.ThreadStatus;
const NativeFn = @import("../runtime/native.zig").NativeFn;
const opcodes = @import("../compiler/opcodes.zig");
const Instruction = opcodes.Instruction;
const VM = @import("../vm/vm.zig").VM;
const hook_state = @import("../vm/hook.zig");
const mnemonics = @import("../vm/mnemonics.zig");
const vm_gc = @import("../vm/gc.zig");

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
var coroutine_bootstrap_code = [_]Instruction{
    Instruction.initABC(.CALL, 0, 0, 0),
    Instruction.initABC(.RETURN, 0, 0, 0),
};
var coroutine_bootstrap_lineinfo = [_]u32{ 1, 1 };
var coroutine_bootstrap_proto = object.ProtoObject{
    .header = object.GCObject.init(.proto, null),
    .k = &.{},
    .code = coroutine_bootstrap_code[0..],
    .protos = &.{},
    .numparams = 0,
    .is_vararg = true,
    // R0=function plus one scratch slot for conservative frame-top handling.
    .maxstacksize = 2,
    .nups = 0,
    .upvalues = &.{},
    .allocator = std.heap.page_allocator,
    .source = "[coroutine bootstrap]",
    .lineinfo = coroutine_bootstrap_lineinfo[0..],
};

// Guard native recursion through coroutine.resume chains to avoid host stack crashes.
const resume_c_depth_limit: u32 = 197;

fn threadEntryBody(thread: *object.ThreadObject, co_vm: *VM) TValue {
    if (thread.entry_func) |entry_fn| return .{ .object = entry_fn };
    return co_vm.stack[0];
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

    // Must be a function (closure or native closure)
    if (!func_arg.isCallable()) {
        return vm.raiseString("bad argument #1 to 'create' (function expected)");
    }

    // Create a new VM for the coroutine (shares the same Runtime)
    const new_vm = try VM.init(vm.rt);

    // Set up the coroutine's initial state:
    // The function will be called when the coroutine is resumed
    // For now, store the function at stack[0]
    new_vm.stack[0] = func_arg;
    new_vm.top = 1;
    new_vm.thread.entry_func = if (func_arg == .object) func_arg.object else null;
    if (new_vm.thread.entry_func) |entry_fn| {
        vm.gc().barrierBack(&new_vm.thread.header, entry_fn);
    }

    // Return the thread object
    vm.stack[vm.base + func_reg] = TValue.fromThread(new_vm.thread);
}

/// coroutine.resume(co [, val1, ...]) - Starts or continues coroutine co
/// Returns (true, results...) on success, (false, error_message) on failure
pub fn nativeCoroutineResume(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    vm.beginGCGuard();
    defer vm.endGCGuard();

    if (nargs < 1) {
        return vm.raiseString("bad argument #1 to 'resume' (thread expected)");
    }

    const thread_arg = vm.stack[vm.base + func_reg + 1];
    const thread = thread_arg.asThread() orelse {
        return vm.raiseString("bad argument #1 to 'resume' (thread expected)");
    };

    if (vm.rt.resume_c_depth >= resume_c_depth_limit) {
        vm.stack[vm.base + func_reg] = .{ .boolean = false };
        vm.stack[vm.base + func_reg + 1] = TValue.fromString(try vm.gc().allocString("C stack overflow"));
        vm.top = vm.base + func_reg + 2;
        return;
    }
    vm.rt.resume_c_depth += 1;
    defer vm.rt.resume_c_depth -= 1;

    // Check if the coroutine can be resumed
    if (thread.status == .dead) {
        vm.stack[vm.base + func_reg] = .{ .boolean = false };
        vm.stack[vm.base + func_reg + 1] = TValue.fromString(try vm.gc().allocString("cannot resume dead coroutine"));
        return;
    }

    if (thread.status == .running) {
        vm.stack[vm.base + func_reg] = .{ .boolean = false };
        vm.stack[vm.base + func_reg + 1] = TValue.fromString(try vm.gc().allocString("cannot resume non-suspended coroutine"));
        return;
    }
    if (thread.status == .normal) {
        vm.stack[vm.base + func_reg] = .{ .boolean = false };
        vm.stack[vm.base + func_reg + 1] = TValue.fromString(try vm.gc().allocString("cannot resume non-suspended coroutine"));
        return;
    }

    const co_vm: *VM = @ptrCast(@alignCast(thread.vm));
    const num_args: u32 = if (nargs > 1) nargs - 1 else 0;
    const arg_base = vm.base + func_reg + 2; // skip thread argument
    const is_first_resume = thread.status == .created;
    const body = threadEntryBody(thread, co_vm);

    if (is_first_resume) {
        // First resume - check function type and set up call frame
        co_vm.stack[0] = body;
        const is_lua_body = body.asClosure() != null;
        const is_native_body = body.isObject() and body.object.type == .native_closure;
        if (!is_lua_body and !is_native_body) {
            vm.stack[vm.base + func_reg] = .{ .boolean = false };
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(try vm.gc().allocString("coroutine body must be a Lua function"));
            return;
        }
        setupFirstResume(co_vm, &vm.stack, arg_base, num_args);
    } else {
        // Resume after yield
        setupResumeAfterYield(co_vm, &vm.stack, arg_base, num_args);
    }

    // Update statuses
    const caller_thread = vm.thread;
    caller_thread.status = .normal; // Caller is waiting
    thread.status = .running; // Coroutine is now running
    vm.rt.setCurrentThread(thread);
    vm.rt.gc.setFinalizerExecutor(vm_gc.finalizerExecutor(co_vm));

    // Execute the coroutine
    const exec_result = executeCoroutine(co_vm);

    // Restore caller status
    caller_thread.status = .running;
    vm.rt.setCurrentThread(caller_thread);
    vm.rt.gc.setFinalizerExecutor(vm_gc.finalizerExecutor(vm));

    // Handle result
    switch (exec_result) {
        .completed => |result_count| {
            // Coroutine completed - mark as dead
            thread.status = .dead;

            // Return (true, results...)
            vm.stack[vm.base + func_reg] = .{ .boolean = true };

            const stack_room: u32 = @intCast(vm.stack.len - (vm.base + func_reg));
            const payload_cap: u32 = if (stack_room > 0) stack_room - 1 else 0;
            const expected_payload: u32 = if (nresults == 0) 0 else @min(nresults - 1, payload_cap);
            const max_copy: u32 = if (nresults == 0) payload_cap else expected_payload;
            const actual_copy = @min(result_count, max_copy);
            var j: u32 = 0;
            while (j < actual_copy) : (j += 1) {
                vm.stack[vm.base + func_reg + 1 + j] = co_vm.stack[j];
            }
            if (nresults > 0 and actual_copy < expected_payload) {
                var k = actual_copy;
                while (k < expected_payload) : (k += 1) {
                    vm.stack[vm.base + func_reg + 1 + k] = .nil;
                }
            }
            vm.top = if (nresults == 0)
                vm.base + func_reg + 1 + actual_copy
            else
                vm.base + func_reg + 1 + expected_payload;
        },
        .yielded => |yield_info| {
            // Coroutine yielded - keep as suspended
            thread.status = .suspended;

            // Return (true, yield_values...)
            vm.stack[vm.base + func_reg] = .{ .boolean = true };

            // Copy yield values from coroutine stack to caller stack
            const stack_room: u32 = @intCast(vm.stack.len - (vm.base + func_reg));
            const payload_cap: u32 = if (stack_room > 0) stack_room - 1 else 0;
            const expected_payload: u32 = if (nresults == 0) 0 else @min(nresults - 1, payload_cap);
            const max_copy: u32 = if (nresults == 0) payload_cap else expected_payload;
            const actual_copy = @min(yield_info.count, max_copy);
            var j: u32 = 0;
            while (j < actual_copy) : (j += 1) {
                vm.stack[vm.base + func_reg + 1 + j] = co_vm.stack[yield_info.base + j];
            }
            if (nresults > 0 and actual_copy < expected_payload) {
                var k = actual_copy;
                while (k < expected_payload) : (k += 1) {
                    vm.stack[vm.base + func_reg + 1 + k] = .nil;
                }
            }
            vm.top = if (nresults == 0)
                vm.base + func_reg + 1 + actual_copy
            else
                vm.base + func_reg + 1 + expected_payload;
        },
        .errored => |err_val| {
            // Coroutine errored - mark as dead
            thread.status = .dead;
            vm.stack[vm.base + func_reg] = .{ .boolean = false };
            vm.stack[vm.base + func_reg + 1] = err_val;
            // Update vm.top for MULTRET support (false + error message)
            vm.top = vm.base + func_reg + 2;
        },
    }
}

/// Result of coroutine execution
const CoroutineResult = union(enum) {
    completed: u32,
    yielded: struct { base: u32, count: u32 },
    errored: TValue,
};

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
    co_vm.base_ci = .{
        .func = &coroutine_bootstrap_proto,
        // Bootstrap bytecode is CALL/RETURN only; no upvalue/env opcodes.
        .closure = null,
        .pc = coroutine_bootstrap_proto.code.ptr,
        .savedpc = null,
        .base = 0,
        .ret_base = 0,
        .nresults = -1,
        .previous = null,
    };
    co_vm.ci = &co_vm.base_ci;
}

/// Set up coroutine for resume after yield (pass values to yield return)
fn setupResumeAfterYield(co_vm: *VM, caller_stack: []TValue, arg_base: u32, num_args: u32) void {
    if (co_vm.yield.from_tailcall) {
        co_vm.yield.from_tailcall = false;
        const ci = co_vm.ci orelse return;
        const dst_base = ci.ret_base;
        const nresults = ci.nresults;

        if (ci.previous != null) {
            if (nresults < 0) {
                var i: u32 = 0;
                while (i < num_args) : (i += 1) {
                    co_vm.stack[dst_base + i] = caller_stack[arg_base + i];
                }
            } else {
                const expected: u32 = @intCast(nresults);
                const copy_count = @min(num_args, expected);
                var i: u32 = 0;
                while (i < copy_count) : (i += 1) {
                    co_vm.stack[dst_base + i] = caller_stack[arg_base + i];
                }
                while (i < expected) : (i += 1) {
                    co_vm.stack[dst_base + i] = .nil;
                }
            }
            mnemonics.popCallInfo(co_vm);
            const caller_frame_max = co_vm.base + co_vm.ci.?.func.maxstacksize;
            co_vm.top = if (nresults < 0) dst_base + num_args else caller_frame_max;
            return;
        }
    }

    const ret_base = co_vm.yield.ret_base;
    const nres = co_vm.yield.nresults;

    if (nres < 0) {
        var i: u32 = 0;
        while (i < num_args) : (i += 1) {
            co_vm.stack[ret_base + i] = caller_stack[arg_base + i];
        }
        co_vm.top = ret_base + num_args;
    } else {
        const max_copy = @as(u32, @intCast(nres));
        var i: u32 = 0;
        while (i < num_args and i < max_copy) : (i += 1) {
            co_vm.stack[ret_base + i] = caller_stack[arg_base + i];
        }
        while (i < max_copy) : (i += 1) {
            co_vm.stack[ret_base + i] = .nil;
        }
    }
}

/// Execute coroutine until completion or yield
fn executeCoroutine(co_vm: *VM) CoroutineResult {
    // Execute instructions until we return from the main function
    while (co_vm.ci != null) {
        if (co_vm.errors.pending_error_unwind and co_vm.errors.pending_error_unwind_ci != null and co_vm.ci == co_vm.errors.pending_error_unwind_ci.?) {
            if (mnemonics.handleLuaException(co_vm) catch |herr| switch (herr) {
                error.Yield => return .{ .yielded = .{ .base = co_vm.yield.base, .count = co_vm.yield.count } },
            }) continue;
            return .{ .errored = co_vm.errors.lua_error_value };
        }
        const ci = co_vm.ci.?;
        if (ci.pending_compare_active) {
            var is_true = co_vm.stack[ci.pending_compare_result_slot].toBoolean();
            if (ci.pending_compare_invert) is_true = !is_true;
            if ((is_true and ci.pending_compare_negate == 0) or (!is_true and ci.pending_compare_negate != 0)) {
                ci.skip();
            }
            ci.pending_compare_active = false;
        }
        if (ci.pending_concat_active) {
            if (mnemonics.continueConcatFold(co_vm, ci) catch |cerr| switch (cerr) {
                error.Yield => return .{ .yielded = .{ .base = co_vm.yield.base, .count = co_vm.yield.count } },
                else => return .{ .errored = co_vm.errors.lua_error_value },
            }) continue;
        }
        const inst = ci.fetch() catch {
            // End of function - check if this is the base frame
            if (ci.previous == null) {
                // Main coroutine function completed
                // Return values are at stack[0..top]
                const result_count = co_vm.top;
                return .{ .completed = result_count };
            }

            // Pop this frame and continue with caller
            mnemonics.popCallInfo(co_vm);
            if (co_vm.ci) |prev_ci| {
                co_vm.base = prev_ci.ret_base;
                co_vm.top = prev_ci.ret_base + prev_ci.func.maxstacksize;
            }
            continue;
        };

        const exec_result = mnemonics.do(co_vm, inst) catch |err| {
            if (err == error.HandledException) continue;
            // Handle LuaException
            if (err == error.LuaException) {
                if (mnemonics.handleLuaException(co_vm) catch |herr| switch (herr) {
                    error.Yield => return .{ .yielded = .{ .base = co_vm.yield.base, .count = co_vm.yield.count } },
                }) continue;
                while (co_vm.ci) |unwind_ci| {
                    mnemonics.closeTBCVariables(co_vm, unwind_ci, 0, co_vm.errors.lua_error_value) catch |cerr| switch (cerr) {
                        error.Yield => return .{ .yielded = .{ .base = co_vm.yield.base, .count = co_vm.yield.count } },
                        else => {},
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
                // Unhandled exception - return error
                return .{ .errored = co_vm.errors.lua_error_value };
            }

            // Handle yield - coroutine suspended
            if (err == error.Yield) {
                hook_state.dispatchReturnOnYield(co_vm, mnemonics.executeSyncMM) catch {};
                return .{ .yielded = .{ .base = co_vm.yield.base, .count = co_vm.yield.count } };
            }

            if (err == error.CallStackOverflow) {
                const msg = if (co_vm.errors.error_handling_depth > 0) "error in error handling" else "stack overflow";
                const msg_obj = co_vm.gc().allocString(msg) catch return .{ .errored = .nil };
                co_vm.errors.lua_error_value = TValue.fromString(msg_obj);
                if (mnemonics.handleLuaException(co_vm) catch |herr| switch (herr) {
                    error.Yield => return .{ .yielded = .{ .base = co_vm.yield.base, .count = co_vm.yield.count } },
                }) continue;
                return .{ .errored = co_vm.errors.lua_error_value };
            }

            // Convert ordinary VM runtime errors into catchable Lua exceptions,
            // matching the main execution and call paths.
            if (err == error.ArithmeticError or
                err == error.DivideByZero or
                err == error.ModuloByZero or
                err == error.IntegerRepresentation or
                err == error.OrderComparisonError or
                err == error.LengthError or
                err == error.NotATable or
                err == error.NotAFunction or
                err == error.InvalidTableKey or
                err == error.InvalidTableOperation or
                err == error.InvalidForLoopInit or
                err == error.InvalidForLoopLimit or
                err == error.InvalidForLoopStep or
                err == error.NoCloseMetamethod or
                err == error.FormatError)
            {
                var msg_buf: [128]u8 = undefined;
                const msg = switch (err) {
                    error.ArithmeticError => mnemonics.formatArithmeticError(co_vm, inst, &msg_buf),
                    error.DivideByZero => "divide by zero",
                    error.ModuloByZero => "attempt to perform 'n%0'",
                    error.IntegerRepresentation => mnemonics.formatIntegerRepresentationError(co_vm, inst, &msg_buf),
                    error.NotATable => mnemonics.formatIndexOnNonTableError(co_vm, inst, &msg_buf),
                    error.NotAFunction => "attempt to call a non-function value",
                    error.OrderComparisonError => "attempt to compare values",
                    error.LengthError => "attempt to get length of a value",
                    error.InvalidTableKey => "table index is nil or NaN",
                    error.InvalidTableOperation => mnemonics.formatIndexOnNonTableError(co_vm, inst, &msg_buf),
                    error.InvalidForLoopInit => mnemonics.formatForLoopError(co_vm, inst, err, &msg_buf),
                    error.InvalidForLoopLimit => mnemonics.formatForLoopError(co_vm, inst, err, &msg_buf),
                    error.InvalidForLoopStep => mnemonics.formatForLoopError(co_vm, inst, err, &msg_buf),
                    error.NoCloseMetamethod => mnemonics.formatNoCloseMetamethodError(co_vm, inst, &msg_buf),
                    error.FormatError => "bad argument to string format",
                    else => "runtime error",
                };
                var full_msg_buf: [320]u8 = undefined;
                const full_msg = mnemonics.runtimeErrorWithCurrentLocation(co_vm, inst, err, msg, &full_msg_buf);
                const msg_obj = co_vm.gc().allocString(full_msg) catch return .{ .errored = .nil };
                co_vm.errors.lua_error_value = TValue.fromString(msg_obj);
                if (mnemonics.handleLuaException(co_vm) catch |herr| switch (herr) {
                    error.Yield => return .{ .yielded = .{ .base = co_vm.yield.base, .count = co_vm.yield.count } },
                }) continue;
                return .{ .errored = co_vm.errors.lua_error_value };
            }

            const err_str = co_vm.gc().allocString(@errorName(err)) catch return .{ .errored = .nil };
            return .{ .errored = TValue.fromString(err_str) };
        };

        // Handle execution result
        switch (exec_result) {
            .Continue, .LoopContinue => continue,
            .ReturnVM => |ret_val| {
                // Function returned - check if this is the main coroutine frame
                if (co_vm.ci) |current_ci| {
                    if (current_ci.previous == null) {
                        // Main coroutine function completed
                        // Copy return values to stack[0..]
                        switch (ret_val) {
                            .none => return .{ .completed = 0 },
                            .single => |val| {
                                co_vm.stack[0] = val;
                                return .{ .completed = 1 };
                            },
                            .multiple => |vals| {
                                for (vals, 0..) |val, i| {
                                    co_vm.stack[i] = val;
                                }
                                return .{ .completed = @intCast(vals.len) };
                            },
                        }
                    }
                }
                // Otherwise handled by instruction processing
            },
        }
    }

    // ci became null without explicit return - treat as empty return
    return .{ .completed = 0 };
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
    try wrapper.set(.{ .integer = 1 }, TValue.fromThread(new_vm.thread));

    // Create metatable with __call
    const metatable = try vm.gc().allocTable();
    _ = vm.pushTempRoot(TValue.fromTable(metatable));
    defer vm.popTempRoots(1);

    const call_key = try vm.gc().allocString("__call");
    const call_fn = try vm.gc().allocNativeClosure(NativeFn.init(.coroutine_wrap_call));
    try metatable.set(TValue.fromString(call_key), TValue.fromNativeClosure(call_fn));

    // Set metatable
    wrapper.metatable = metatable;

    // Return the wrapper table (acts as function due to __call)
    vm.stack[vm.base + func_reg] = TValue.fromTable(wrapper);
}

/// Internal: __call handler for wrapped coroutine
/// Called when a wrapped coroutine is invoked as a function
pub fn nativeCoroutineWrapCall(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    vm.beginGCGuard();
    defer vm.endGCGuard();

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
        if (thread == vm.thread and vm.errors.close_metamethod_depth > 0) {
            vm.stack[vm.base + func_reg] = .{ .boolean = false };
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(try vm.gc().allocString("cannot resume non-suspended coroutine"));
            vm.top = vm.base + func_reg + 2;
            return;
        }
        return vm.raiseString("cannot resume non-suspended coroutine");
    }
    if (thread.status == .normal) {
        if (thread == vm.thread and vm.errors.close_metamethod_depth > 0) {
            vm.stack[vm.base + func_reg] = .{ .boolean = false };
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(try vm.gc().allocString("cannot resume non-suspended coroutine"));
            vm.top = vm.base + func_reg + 2;
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
            // Return results directly (no leading true)
            const stack_room: u32 = @intCast(vm.stack.len - (vm.base + func_reg));
            const expected_count: u32 = if (nresults == 0) 0 else @min(nresults, stack_room);
            const max_copy: u32 = if (nresults == 0) stack_room else expected_count;
            const actual_copy = @min(result_count, max_copy);
            var j: u32 = 0;
            while (j < actual_copy) : (j += 1) {
                vm.stack[vm.base + func_reg + j] = co_vm.stack[j];
            }
            if (nresults > 0 and actual_copy < expected_count) {
                var k = actual_copy;
                while (k < expected_count) : (k += 1) {
                    vm.stack[vm.base + func_reg + k] = .nil;
                }
            }
            vm.top = if (nresults == 0)
                vm.base + func_reg + actual_copy
            else
                vm.base + func_reg + expected_count;
        },
        .yielded => |yield_info| {
            thread.status = .suspended;
            // Return yield values directly (no leading true)
            const stack_room: u32 = @intCast(vm.stack.len - (vm.base + func_reg));
            const expected_count: u32 = if (nresults == 0) 0 else @min(nresults, stack_room);
            const max_copy: u32 = if (nresults == 0) stack_room else expected_count;
            const actual_copy = @min(yield_info.count, max_copy);
            var j: u32 = 0;
            while (j < actual_copy) : (j += 1) {
                vm.stack[vm.base + func_reg + j] = co_vm.stack[yield_info.base + j];
            }
            if (nresults > 0 and actual_copy < expected_count) {
                var k = actual_copy;
                while (k < expected_count) : (k += 1) {
                    vm.stack[vm.base + func_reg + k] = .nil;
                }
            }
            vm.top = if (nresults == 0)
                vm.base + func_reg + actual_copy
            else
                vm.base + func_reg + expected_count;
        },
        .errored => |err_val| {
            thread.status = .dead;
            // Propagate the error (unlike resume which returns false)
            vm.errors.lua_error_value = err_val;
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

    // Store yield value location for resume to read
    // Arguments are at stack[base + func_reg + 1 .. + nargs]
    //
    // NOTE: nargs follows Moonquakes native call convention where nargs is
    // the count of arguments passed (not including the function itself).
    // If this convention changes, yield_count calculation may need adjustment.
    vm.yield.base = vm.base + func_reg + 1;
    vm.yield.count = nargs;

    // Store where resume's return values should go (when coroutine is resumed)
    // This is where CALL expects its results: stack[base + func_reg]
    const ci = vm.ci orelse return vm.raiseString("attempt to yield from outside a coroutine");
    const is_tailcall_site = blk: {
        const code_start = @intFromPtr(ci.func.code.ptr);
        const pc_addr = @intFromPtr(ci.pc);
        if (pc_addr <= code_start) break :blk false;
        const prev_inst = (ci.pc - 1)[0];
        break :blk prev_inst.getOpCode() == .TAILCALL;
    };
    vm.yield.from_tailcall = is_tailcall_site;
    vm.yield.ret_base = if (is_tailcall_site) ci.ret_base else vm.base + func_reg;
    vm.yield.nresults = if (nresults == 0) -1 else @as(i32, @intCast(nresults));

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
    const setResult = struct {
        fn run(vm2: *VM, base: u32, ok: bool, err_val: ?TValue, nres: u32) void {
            vm2.stack[base] = .{ .boolean = ok };
            if (err_val) |err| {
                vm2.stack[base + 1] = err;
                vm2.top = if (nres == 0) base + 2 else base + @min(@as(u32, 2), nres);
            } else {
                if (nres > 1) {
                    var i: u32 = 1;
                    while (i < nres) : (i += 1) {
                        vm2.stack[base + i] = .nil;
                    }
                }
                vm2.top = if (nres == 0) base + 1 else base + @min(@as(u32, 1), nres);
            }
        }
    }.run;

    if (nargs < 1) {
        return vm.raiseString("bad argument #1 to 'close' (thread expected)");
    }

    const thread_arg = vm.stack[result_base + 1];
    const thread = thread_arg.asThread() orelse {
        return vm.raiseString("bad argument #1 to 'close' (thread expected)");
    };

    if (vm.rt.resume_c_depth >= resume_c_depth_limit) {
        const err_str = try vm.gc().allocString("C stack overflow");
        setResult(vm, result_base, false, TValue.fromString(err_str), nresults);
        return;
    }
    vm.rt.resume_c_depth += 1;
    defer vm.rt.resume_c_depth -= 1;

    const co_vm: *VM = @ptrCast(@alignCast(thread.vm));

    // Reentrant self-close while running __close must fail.
    if (thread == vm.thread and vm.errors.close_metamethod_depth > 0) {
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
        if (!co_vm.errors.lua_error_value.isNil()) {
            const err_val = co_vm.errors.lua_error_value;
            co_vm.errors.lua_error_value = .nil;
            setResult(vm, result_base, false, err_val, nresults);
            return;
        }
        setResult(vm, result_base, true, null, nresults);
        return;
    }

    // Closing a suspended coroutine must run pending to-be-closed variables.
    if (thread.status == .suspended) {
        while (co_vm.ci) |unwind_ci| {
            mnemonics.closeTBCVariables(co_vm, unwind_ci, 0, .nil) catch |cerr| switch (cerr) {
                error.LuaException => {
                    thread.status = .dead;
                    const err_val = co_vm.errors.lua_error_value;
                    co_vm.errors.lua_error_value = .nil;
                    setResult(vm, result_base, false, err_val, nresults);
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
    setResult(vm, result_base, true, null, nresults);
}
