const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");
const ThreadStatus = object.ThreadStatus;
const NativeFn = @import("../runtime/native.zig").NativeFn;
const VM = @import("../vm/vm.zig").VM;
const mnemonics = @import("../vm/mnemonics.zig");
const vm_gc = @import("../vm/gc.zig");

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

    // Return the thread object
    vm.stack[vm.base + func_reg] = TValue.fromThread(new_vm.thread);
}

/// coroutine.resume(co [, val1, ...]) - Starts or continues coroutine co
/// Returns (true, results...) on success, (false, error_message) on failure
pub fn nativeCoroutineResume(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    vm.gc().inhibitGC();
    defer vm.gc().allowGC();

    if (nargs < 1) {
        return vm.raiseString("bad argument #1 to 'resume' (thread expected)");
    }

    const thread_arg = vm.stack[vm.base + func_reg + 1];
    const thread = thread_arg.asThread() orelse {
        return vm.raiseString("bad argument #1 to 'resume' (thread expected)");
    };

    // Check if the coroutine can be resumed
    if (thread.status == .dead) {
        vm.stack[vm.base + func_reg] = .{ .boolean = false };
        vm.stack[vm.base + func_reg + 1] = TValue.fromString(try vm.gc().allocString("cannot resume dead coroutine"));
        return;
    }

    if (thread.status == .running) {
        vm.stack[vm.base + func_reg] = .{ .boolean = false };
        vm.stack[vm.base + func_reg + 1] = TValue.fromString(try vm.gc().allocString("cannot resume running coroutine"));
        return;
    }

    const co_vm: *VM = @ptrCast(@alignCast(thread.vm));
    const num_args: u32 = if (nargs > 1) nargs - 1 else 0;
    const arg_base = vm.base + func_reg + 2; // skip thread argument
    const is_first_resume = thread.status == .created;

    if (is_first_resume) {
        // First resume - check function type and set up call frame
        const is_lua_body = co_vm.stack[0].asClosure() != null;
        const is_native_body = co_vm.stack[0].isObject() and co_vm.stack[0].object.type == .native_closure;
        if (!is_lua_body and !is_native_body) {
            vm.stack[vm.base + func_reg] = .{ .boolean = false };
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(try vm.gc().allocString("coroutine body must be a Lua function"));
            return;
        }
        if (is_lua_body) {
            try setupFirstResume(co_vm, &vm.stack, arg_base, num_args);
        }
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
    const exec_result = if (is_first_resume and co_vm.stack[0].isObject() and co_vm.stack[0].object.type == .native_closure)
        executeNativeCoroutineFirstResume(co_vm, &vm.stack, arg_base, num_args, if (nresults > 0) nresults - 1 else 1)
    else
        executeCoroutine(co_vm);

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

            // Copy return values
            const max_results = if (nresults == 0) 0 else nresults - 1;
            var j: u32 = 0;
            while (j < result_count and j < max_results) : (j += 1) {
                vm.stack[vm.base + func_reg + 1 + j] = co_vm.stack[j];
            }
        },
        .yielded => |yield_info| {
            // Coroutine yielded - keep as suspended
            thread.status = .suspended;

            // Return (true, yield_values...)
            vm.stack[vm.base + func_reg] = .{ .boolean = true };

            // Copy yield values from coroutine stack to caller stack
            const max_results = if (nresults == 0) 0 else nresults - 1;
            var j: u32 = 0;
            while (j < yield_info.count and j < max_results) : (j += 1) {
                vm.stack[vm.base + func_reg + 1 + j] = co_vm.stack[yield_info.base + j];
            }
        },
        .errored => |err_val| {
            // Coroutine errored - mark as dead
            thread.status = .dead;
            vm.stack[vm.base + func_reg] = .{ .boolean = false };
            vm.stack[vm.base + func_reg + 1] = err_val;
        },
    }
}

/// Result of coroutine execution
const CoroutineResult = union(enum) {
    completed: u32,
    yielded: struct { base: u32, count: u32 },
    errored: TValue,
};

fn executeNativeCoroutineFirstResume(co_vm: *VM, caller_stack: []TValue, arg_base: u32, num_args: u32, want_results: u32) CoroutineResult {
    const func_val = co_vm.stack[0];
    if (!(func_val.isObject() and func_val.object.type == .native_closure)) {
        const err_str = co_vm.gc().allocString("coroutine body must be a Lua function") catch return .{ .errored = .nil };
        return .{ .errored = TValue.fromString(err_str) };
    }

    const nc = object.getObject(object.NativeClosureObject, func_val.object);

    var i: u32 = 0;
    while (i < num_args) : (i += 1) {
        co_vm.stack[1 + i] = caller_stack[arg_base + i];
    }

    var r: u32 = 0;
    while (r < want_results) : (r += 1) {
        co_vm.stack[r] = .nil;
    }
    co_vm.top = 1 + num_args;

    co_vm.callNative(nc.func.id, 0, num_args, want_results) catch |err| {
        if (err == error.LuaException) return .{ .errored = co_vm.lua_error_value };
        const err_str = co_vm.gc().allocString(@errorName(err)) catch return .{ .errored = .nil };
        return .{ .errored = TValue.fromString(err_str) };
    };

    co_vm.top = want_results;
    return .{ .completed = want_results };
}

/// Set up coroutine for first resume (initialize call frame)
fn setupFirstResume(co_vm: *VM, caller_stack: []TValue, arg_base: u32, num_args: u32) error{OutOfMemory}!void {
    const func_val = co_vm.stack[0];
    const closure = func_val.asClosure().?;
    const proto = closure.proto;

    // Copy arguments to coroutine stack
    var i: u32 = 0;
    while (i < num_args) : (i += 1) {
        co_vm.stack[1 + i] = caller_stack[arg_base + i];
    }
    while (i < proto.numparams) : (i += 1) {
        co_vm.stack[1 + i] = .nil;
    }

    // Set up initial call frame
    co_vm.base = 1;
    co_vm.top = 1 + proto.maxstacksize;
    co_vm.base_ci = .{
        .func = proto,
        .closure = closure,
        .pc = proto.code.ptr,
        .savedpc = null,
        .base = 1,
        .ret_base = 0,
        .nresults = -1,
        .previous = null,
    };
    co_vm.ci = &co_vm.base_ci;
}

/// Set up coroutine for resume after yield (pass values to yield return)
fn setupResumeAfterYield(co_vm: *VM, caller_stack: []TValue, arg_base: u32, num_args: u32) void {
    const ret_base = co_vm.yield_ret_base;
    const nres = co_vm.yield_nresults;

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
        const ci = co_vm.ci.?;
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
            // Handle LuaException
            if (err == error.LuaException) {
                if (mnemonics.handleLuaException(co_vm)) continue;
                // Unhandled exception - return error
                return .{ .errored = co_vm.lua_error_value };
            }

            // Handle yield - coroutine suspended
            if (err == error.Yield) {
                return .{ .yielded = .{ .base = co_vm.yield_base, .count = co_vm.yield_count } };
            }

            // Other errors - create error message
            const err_str = co_vm.gc().allocString(@errorName(err)) catch {
                return .{ .errored = .nil };
            };
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
    // Store original body function at index 2 to recover from stale coroutine stack[0].
    try wrapper.set(.{ .integer = 2 }, func_arg);

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
    vm.gc().inhibitGC();
    defer vm.gc().allowGC();

    // When __call is invoked, the table (wrapper) is at func_reg
    // and original args are at func_reg+1, func_reg+2, ...
    // But nargs includes the wrapper itself as first arg

    // Get the wrapper table
    const wrapper_val = vm.stack[vm.base + func_reg];
    const wrapper = wrapper_val.asTable() orelse {
        return vm.raiseString("invalid wrapped coroutine");
    };

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
        return vm.raiseString("cannot resume running coroutine");
    }

    const co_vm: *VM = @ptrCast(@alignCast(thread.vm));
    const num_args: u32 = if (nargs > 1) nargs - 1 else 0;
    const arg_base = vm.base + func_reg + 1; // __call: args after wrapper
    const is_first_resume = thread.status == .created;

    if (is_first_resume) {
        if (wrapper.get(.{ .integer = 2 })) |body| {
            co_vm.stack[0] = body;
        }
        // First resume
        const body = co_vm.stack[0];
        const is_lua_body = body.asClosure() != null;
        const is_native_body = body.isObject() and body.object.type == .native_closure;
        if (!is_lua_body and !is_native_body) {
            return vm.raiseString("coroutine body must be a Lua function");
        }
        if (is_lua_body) {
            try setupFirstResume(co_vm, &vm.stack, arg_base, num_args);
        }
    } else {
        // Resume after yield
        setupResumeAfterYield(co_vm, &vm.stack, arg_base, num_args);
    }

    // Update statuses and execute
    const caller_thread = vm.thread;
    caller_thread.status = .normal;
    thread.status = .running;
    vm.rt.setCurrentThread(thread);

    const is_native_first = is_first_resume and co_vm.stack[0].isObject() and co_vm.stack[0].object.type == .native_closure;
    const exec_result = if (is_native_first)
        executeNativeCoroutineFirstResume(co_vm, &vm.stack, arg_base, num_args, if (nresults > 0) nresults else 1)
    else
        executeCoroutine(co_vm);

    caller_thread.status = .running;
    vm.rt.setCurrentThread(caller_thread);

    // Handle result - wrap propagates errors instead of returning false
    switch (exec_result) {
        .completed => |result_count| {
            thread.status = .dead;
            // Return results directly (no leading true)
            const max_results = nresults;
            var j: u32 = 0;
            while (j < result_count and j < max_results) : (j += 1) {
                vm.stack[vm.base + func_reg + j] = co_vm.stack[j];
            }
        },
        .yielded => |yield_info| {
            thread.status = .suspended;
            // Return yield values directly (no leading true)
            const max_results = nresults;
            var j: u32 = 0;
            while (j < yield_info.count and j < max_results) : (j += 1) {
                vm.stack[vm.base + func_reg + j] = co_vm.stack[yield_info.base + j];
            }
        },
        .errored => |err_val| {
            thread.status = .dead;
            // Propagate the error (unlike resume which returns false)
            vm.lua_error_value = err_val;
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
    vm.yield_base = vm.base + func_reg + 1;
    vm.yield_count = nargs;

    // Store where resume's return values should go (when coroutine is resumed)
    // This is where CALL expects its results: stack[base + func_reg]
    vm.yield_ret_base = vm.base + func_reg;
    vm.yield_nresults = @as(i32, @intCast(nresults));

    // Suspend execution - will be caught by executeCoroutine
    return error.Yield;
}

/// coroutine.isyieldable() - Returns true if running coroutine can yield
/// Returns false for main thread
pub fn nativeCoroutineIsYieldable(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;

    if (nresults == 0) return;

    // Main thread cannot yield
    const can_yield = !vm.isMainThread();
    vm.stack[vm.base + func_reg] = .{ .boolean = can_yield };
}

/// coroutine.close(co) - Closes coroutine co (Lua 5.4 feature)
/// Closes coroutine and runs to-be-closed variables
pub fn nativeCoroutineClose(vm: *VM, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 1) {
        return vm.raiseString("bad argument #1 to 'close' (thread expected)");
    }

    const thread_arg = vm.stack[vm.base + func_reg + 1];
    const thread = thread_arg.asThread() orelse {
        return vm.raiseString("bad argument #1 to 'close' (thread expected)");
    };

    // Can only close suspended or dead coroutines
    if (thread.status == .running or thread.status == .normal) {
        vm.stack[vm.base + func_reg] = .{ .boolean = false };
        if (nresults >= 2) {
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(try vm.gc().allocString("cannot close a running coroutine"));
        }
        return;
    }

    thread.status = .dead;
    // NOTE: To-be-closed variables (__close) not yet implemented
    vm.stack[vm.base + func_reg] = .{ .boolean = true };
}
