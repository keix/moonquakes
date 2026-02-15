const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");
const ClosureObject = object.ClosureObject;
const metamethod = @import("../vm/metamethod.zig");
const pipeline = @import("../compiler/pipeline.zig");
const call = @import("../vm/call.zig");

/// Lua 5.4 Debug Library
/// Corresponds to Lua manual chapter "The Debug Library"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.10

/// debug.debug() - Enters interactive mode with the user
/// Reads and executes each line entered by the user.
/// The session ends when the user enters a line containing only "cont".
/// Note: Commands are not lexically nested within any function,
/// so they have no direct access to local variables.
pub fn nativeDebugDebug(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = func_reg;
    _ = nargs;
    _ = nresults;

    const stdin_file = std.fs.File.stdin();
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;
    var stderr_writer = std.fs.File.stderr().writer(&.{});
    const stderr = &stderr_writer.interface;

    var buf: [4096]u8 = undefined;

    while (true) {
        // Print prompt
        stdout.writeAll("lua_debug> ") catch return;

        // Read line from stdin (character by character until newline)
        var pos: usize = 0;
        while (pos < buf.len - 1) {
            var char_buf: [1]u8 = undefined;
            const bytes_read = stdin_file.read(&char_buf) catch break;
            if (bytes_read == 0) {
                // EOF
                if (pos == 0) return;
                break;
            }
            if (char_buf[0] == '\n') break;
            buf[pos] = char_buf[0];
            pos += 1;
        }
        const line = buf[0..pos];

        // Trim whitespace
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Check for "cont" to exit
        if (std.mem.eql(u8, trimmed, "cont")) break;

        // Skip empty lines
        if (trimmed.len == 0) continue;

        // Compile the input
        const compile_result = pipeline.compile(vm.gc.allocator, trimmed, .{});
        switch (compile_result) {
            .err => |e| {
                defer e.deinit(vm.gc.allocator);
                stderr.print("syntax error: {s}\n", .{e.message}) catch {};
                continue;
            },
            .ok => {},
        }
        const raw_proto = compile_result.ok;
        defer pipeline.freeRawProto(vm.gc.allocator, raw_proto);

        // Materialize and execute
        vm.gc.inhibitGC();
        const proto = pipeline.materialize(&raw_proto, vm.gc, vm.gc.allocator) catch {
            vm.gc.allowGC();
            stderr.writeAll("error: failed to materialize chunk\n") catch {};
            continue;
        };

        const closure = vm.gc.allocClosure(proto) catch {
            vm.gc.allowGC();
            stderr.writeAll("error: failed to create closure\n") catch {};
            continue;
        };
        vm.gc.allowGC();

        // Execute the chunk using call.callValue (same pattern as dofile)
        const func_val = TValue.fromClosure(closure);
        const result = call.callValue(vm, func_val, &[_]TValue{}) catch {
            stderr.writeAll("error: runtime error\n") catch {};
            continue;
        };

        // Print non-nil result
        if (!result.isNil()) {
            printValue(stdout, result) catch {};
            stdout.writeAll("\n") catch {};
        }
    }
}

/// Helper to print a TValue
fn printValue(writer: anytype, val: TValue) !void {
    switch (val) {
        .nil => try writer.writeAll("nil"),
        .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |i| try writer.print("{d}", .{i}),
        .number => |n| try writer.print("{d}", .{n}),
        .object => |obj| {
            switch (obj.type) {
                .string => {
                    const str: *object.StringObject = @fieldParentPtr("header", obj);
                    try writer.writeAll(str.asSlice());
                },
                .table => try writer.print("table: 0x{x}", .{@intFromPtr(obj)}),
                .closure => try writer.print("function: 0x{x}", .{@intFromPtr(obj)}),
                .native_closure => try writer.print("function: 0x{x}", .{@intFromPtr(obj)}),
                .userdata => try writer.print("userdata: 0x{x}", .{@intFromPtr(obj)}),
                .proto => try writer.print("proto: 0x{x}", .{@intFromPtr(obj)}),
                .upvalue => try writer.print("upvalue: 0x{x}", .{@intFromPtr(obj)}),
            }
        },
    }
}

/// debug.gethook([thread]) - Returns current hook settings
/// Returns: hook function, mask string, count
pub fn nativeDebugGethook(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;

    // Return hook function (or nil)
    if (nresults > 0) {
        if (vm.hook_func) |hook| {
            vm.stack[vm.base + func_reg] = TValue.fromClosure(hook);
        } else {
            vm.stack[vm.base + func_reg] = TValue.nil;
        }
    }

    // Return mask string
    if (nresults > 1) {
        var mask_buf: [4]u8 = undefined;
        var pos: usize = 0;
        if (vm.hook_mask & 1 != 0) {
            mask_buf[pos] = 'c';
            pos += 1;
        }
        if (vm.hook_mask & 2 != 0) {
            mask_buf[pos] = 'r';
            pos += 1;
        }
        if (vm.hook_mask & 4 != 0) {
            mask_buf[pos] = 'l';
            pos += 1;
        }
        vm.stack[vm.base + func_reg + 1] = TValue.fromString(try vm.gc.allocString(mask_buf[0..pos]));
    }

    // Return count
    if (nresults > 2) {
        vm.stack[vm.base + func_reg + 2] = .{ .integer = @intCast(vm.hook_count) };
    }
}

/// debug.getinfo([thread,] f [, what]) - Returns table with information about a function
/// Supports:
/// - f as stack level (number): 0 = getinfo itself, 1 = caller, etc.
/// - f as function: returns info about that function
/// - what: string specifying what info to return (default: all)
///   "n": name, namewhat
///   "S": source, short_src, linedefined, lastlinedefined, what
///   "l": currentline
///   "t": istailcall
///   "u": nups, nparams, isvararg
///   "f": func
pub fn nativeDebugGetinfo(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    // Parse first argument (f)
    if (nargs < 1) {
        vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }

    const f_arg = vm.stack[vm.base + func_reg + 1];

    // Parse what argument (optional, default to "flnStu")
    var want_name = true;
    var want_source = true;
    var want_line = true;
    var want_tailcall = true;
    var want_upvalue = true;
    var want_func = true;

    if (nargs >= 2) {
        const what_arg = vm.stack[vm.base + func_reg + 2];
        if (what_arg.asString()) |what_str| {
            want_name = false;
            want_source = false;
            want_line = false;
            want_tailcall = false;
            want_upvalue = false;
            want_func = false;
            for (what_str.asSlice()) |c| {
                switch (c) {
                    'n' => want_name = true,
                    'S' => want_source = true,
                    'l' => want_line = true,
                    't' => want_tailcall = true,
                    'u' => want_upvalue = true,
                    'f' => want_func = true,
                    else => {},
                }
            }
        }
    }

    // Determine target closure
    var target_closure: ?*ClosureObject = null;
    const func_name: ?[]const u8 = null;

    if (f_arg.toInteger()) |level| {
        // f is a stack level
        // Level 0 = getinfo itself (current native call frame)
        // Level 1 = caller of getinfo
        // etc.

        if (level < 0) {
            vm.stack[vm.base + func_reg] = TValue.nil;
            return;
        }

        const ulevel: usize = @intCast(level);

        // Level 0 is getinfo itself - which is native, so we return C info
        if (ulevel == 0) {
            const result_table = try vm.gc.allocTable();
            if (want_source) {
                const what_key = try vm.gc.allocString("what");
                try result_table.set(TValue.fromString(what_key), TValue.fromString(try vm.gc.allocString("C")));
            }
            vm.stack[vm.base + func_reg] = TValue.fromTable(result_table);
            return;
        }

        // Find the closure at stack level
        // callstack_size is the number of Lua frames
        // level 1 = callstack[callstack_size - 1]
        // level 2 = callstack[callstack_size - 2]
        // etc.

        if (ulevel > vm.callstack_size) {
            vm.stack[vm.base + func_reg] = TValue.nil;
            return;
        }

        const stack_idx = vm.callstack_size - ulevel;
        const ci = &vm.callstack[stack_idx];
        target_closure = ci.closure;

        // Try to get function name from the caller's call site
        // This is complex - would require analyzing the calling code's bytecode
        // to find the name from GETFIELD/GETTABUP instructions.
        // For now, we leave func_name as null.
    } else if (f_arg.asClosure()) |closure| {
        // f is a function
        target_closure = closure;
    } else {
        vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }

    // Create result table
    const result_table = try vm.gc.allocTable();

    if (target_closure) |closure| {
        const proto = closure.proto;

        if (want_name) {
            if (func_name) |name| {
                const name_key = try vm.gc.allocString("name");
                try result_table.set(TValue.fromString(name_key), TValue.fromString(try vm.gc.allocString(name)));
                const namewhat_key = try vm.gc.allocString("namewhat");
                try result_table.set(TValue.fromString(namewhat_key), TValue.fromString(try vm.gc.allocString("field")));
            }
        }

        if (want_source) {
            const what_key = try vm.gc.allocString("what");
            try result_table.set(TValue.fromString(what_key), TValue.fromString(try vm.gc.allocString("Lua")));
            const source_key = try vm.gc.allocString("source");
            try result_table.set(TValue.fromString(source_key), TValue.fromString(try vm.gc.allocString("?")));
            const short_src_key = try vm.gc.allocString("short_src");
            try result_table.set(TValue.fromString(short_src_key), TValue.fromString(try vm.gc.allocString("?")));
            const linedefined_key = try vm.gc.allocString("linedefined");
            try result_table.set(TValue.fromString(linedefined_key), .{ .integer = 0 });
            const lastlinedefined_key = try vm.gc.allocString("lastlinedefined");
            try result_table.set(TValue.fromString(lastlinedefined_key), .{ .integer = 0 });
        }

        if (want_line) {
            const currentline_key = try vm.gc.allocString("currentline");
            try result_table.set(TValue.fromString(currentline_key), .{ .integer = -1 });
        }

        if (want_tailcall) {
            const istailcall_key = try vm.gc.allocString("istailcall");
            try result_table.set(TValue.fromString(istailcall_key), .{ .boolean = false });
        }

        if (want_upvalue) {
            const nups_key = try vm.gc.allocString("nups");
            try result_table.set(TValue.fromString(nups_key), .{ .integer = @intCast(proto.upvalues.len) });
            const nparams_key = try vm.gc.allocString("nparams");
            try result_table.set(TValue.fromString(nparams_key), .{ .integer = @intCast(proto.numparams) });
            const isvararg_key = try vm.gc.allocString("isvararg");
            try result_table.set(TValue.fromString(isvararg_key), .{ .boolean = proto.is_vararg });
        }

        if (want_func) {
            const func_key = try vm.gc.allocString("func");
            try result_table.set(TValue.fromString(func_key), TValue.fromClosure(closure));
        }
    }

    vm.stack[vm.base + func_reg] = TValue.fromTable(result_table);
}

/// debug.getlocal([thread,] f, local) - Returns name and value of local variable
/// f can be stack level (number) or function
/// local is 1-based index
/// Returns: name, value (or nil if local doesn't exist)
/// Note: Names are not available (we don't store locvar debug info), returns "(local N)"
pub fn nativeDebugGetlocal(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 2) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }

    const f_arg = vm.stack[vm.base + func_reg + 1];
    const local_arg = vm.stack[vm.base + func_reg + 2];

    // Get local index (1-based)
    const local_int = local_arg.toInteger() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    };

    if (local_int < 1) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }
    const local_idx: usize = @intCast(local_int - 1);

    // Handle f as stack level
    if (f_arg.toInteger()) |level| {
        if (level < 0) {
            if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
            return;
        }

        const ulevel: usize = @intCast(level);

        // Level 0 is getlocal itself (native), level 1 is caller, etc.
        if (ulevel == 0 or ulevel > vm.callstack_size) {
            if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
            return;
        }

        // Get the call frame at that level
        const stack_idx = vm.callstack_size - ulevel;
        const ci = &vm.callstack[stack_idx];

        // Check if local index is within the frame's stack range
        // Locals are at base + 0, base + 1, etc.
        const max_locals = ci.func.maxstacksize;
        if (local_idx >= max_locals) {
            if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
            return;
        }

        // Get the value from the stack
        const stack_pos = ci.base + @as(u32, @intCast(local_idx));
        const value = vm.stack[stack_pos];

        // Generate a name since we don't have locvar info
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "(local {d})", .{local_int}) catch "(local)";

        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = TValue.fromString(try vm.gc.allocString(name));
        }
        if (nresults > 1) {
            vm.stack[vm.base + func_reg + 1] = value;
        }
        return;
    }

    // Handle f as function (can only get parameter info)
    if (f_arg.asClosure()) |closure| {
        const proto = closure.proto;

        // For functions, we can only report info about parameters
        if (local_idx >= proto.numparams) {
            if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
            return;
        }

        // Generate parameter name
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "(param {d})", .{local_int}) catch "(param)";

        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = TValue.fromString(try vm.gc.allocString(name));
        }
        // For function objects (not active frames), we can't get the value
        if (nresults > 1) {
            vm.stack[vm.base + func_reg + 1] = TValue.nil;
        }
        return;
    }

    // Invalid argument
    if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
}

/// debug.getmetatable(value) - Returns metatable of given value
/// Unlike getmetatable(), this bypasses __metatable protection
/// Works for all types including primitives (returns shared metatables)
pub fn nativeDebugGetmetatable(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;

    const value = vm.stack[vm.base + func_reg + 1];

    // Get metatable directly, bypassing __metatable protection
    // Uses metamethod.getMetatable which handles both individual and shared metatables
    const result: TValue = if (metamethod.getMetatable(value, &vm.gc.shared_mt)) |mt|
        TValue.fromTable(mt)
    else
        TValue.nil;

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = result;
    }
}

/// debug.setmetatable(value, table) - Sets metatable for given value
/// Unlike setmetatable(), this works for all types:
/// - Tables/userdata: sets individual metatable
/// - Primitives (string, number, boolean, function, nil): sets shared metatable
/// Returns the value (first argument)
pub fn nativeDebugSetmetatable(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;

    const value = vm.stack[vm.base + func_reg + 1];
    const mt_arg = vm.stack[vm.base + func_reg + 2];

    // Get the metatable (nil clears it)
    const new_mt: ?*object.TableObject = if (mt_arg.isNil())
        null
    else if (mt_arg.asTable()) |mt|
        mt
    else {
        // Invalid metatable argument - should be table or nil
        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = value;
        }
        return;
    };

    // Try to set metatable based on value type
    if (value.asTable()) |table| {
        // Table: set individual metatable (no protection check in debug.setmetatable)
        table.metatable = new_mt;
    } else if (value.asUserdata()) |ud| {
        // Userdata: set individual metatable
        ud.metatable = new_mt;
    } else {
        // Primitive type: set shared metatable
        _ = vm.gc.shared_mt.setForValue(value, new_mt);
    }

    // Return the original value
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = value;
    }
}

/// debug.getregistry() - Returns the registry table
/// The registry is a global table used to store internal data
pub fn nativeDebugGetregistry(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = TValue.fromTable(vm.registry);
    }
}

/// debug.getupvalue(f, up) - Returns name and value of upvalue up of function f
/// Returns the upvalue name and its current value
/// up is 1-based index
pub fn nativeDebugGetupvalue(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;

    const func_arg = vm.stack[vm.base + func_reg + 1];
    const up_arg = vm.stack[vm.base + func_reg + 2];

    // Get function closure
    const closure = func_arg.asClosure() orelse {
        // Not a Lua function - return nil
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    };

    // Get upvalue index (1-based in Lua)
    const up_int = up_arg.toInteger() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    };

    // Invalid index (< 1) returns nil
    if (up_int < 1) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }
    const up_idx: usize = @intCast(up_int - 1);

    // Check bounds
    if (up_idx >= closure.upvalues.len) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }

    // Get upvalue name from proto
    const name = if (up_idx < closure.proto.upvalues.len)
        closure.proto.upvalues[up_idx].name orelse "(no name)"
    else
        "(no name)";

    // Get upvalue value
    const upval = closure.upvalues[up_idx];
    const value = upval.get();

    // Return name and value
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = TValue.fromString(try vm.gc.allocString(name));
    }
    if (nresults > 1) {
        vm.stack[vm.base + func_reg + 1] = value;
    }
}

/// debug.getuservalue(u [, n]) - Returns the n-th user value associated with userdata u
/// Returns nil and false if the userdata does not have that value
pub fn nativeDebugGetuservalue(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    // Get userdata argument
    const arg0 = vm.stack[vm.base + func_reg + 1];
    const ud = arg0.asUserdata() orelse {
        // Not userdata - return nil, false
        vm.stack[vm.base + func_reg] = TValue.nil;
        if (nresults > 1) {
            vm.stack[vm.base + func_reg + 1] = .{ .boolean = false };
        }
        return;
    };

    // Get index n (default 1, Lua is 1-indexed)
    const n_raw: i64 = if (nargs >= 2)
        vm.stack[vm.base + func_reg + 2].toInteger() orelse 1
    else
        1;

    // Convert to u8, treating negative and out-of-range as 0 (will fail bounds check)
    const n: u8 = if (n_raw < 1 or n_raw > 255) 0 else @intCast(n_raw);

    // Check bounds (1-indexed)
    if (n < 1 or n > ud.nuvalue) {
        vm.stack[vm.base + func_reg] = TValue.nil;
        if (nresults > 1) {
            vm.stack[vm.base + func_reg + 1] = .{ .boolean = false };
        }
        return;
    }

    // Get user value at index n-1 (convert to 0-indexed)
    const user_values = ud.userValues();
    vm.stack[vm.base + func_reg] = user_values[n - 1];
    if (nresults > 1) {
        vm.stack[vm.base + func_reg + 1] = .{ .boolean = true };
    }
}

/// debug.sethook([thread,] hook, mask [, count]) - Sets given function as a hook
/// hook: function to call (or nil to clear)
/// mask: string with 'c' (call), 'r' (return), 'l' (line)
/// count: call hook every count instructions (optional)
/// Note: Hooks are stored but not yet invoked by the VM
pub fn nativeDebugSethook(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nresults;

    // No args or nil first arg = clear hook
    if (nargs == 0) {
        vm.hook_func = null;
        vm.hook_mask = 0;
        vm.hook_count = 0;
        return;
    }

    const hook_arg = vm.stack[vm.base + func_reg + 1];

    // nil clears the hook
    if (hook_arg.isNil()) {
        vm.hook_func = null;
        vm.hook_mask = 0;
        vm.hook_count = 0;
        return;
    }

    // Get hook function
    const hook_func = hook_arg.asClosure() orelse return;

    // Get mask string
    var mask: u8 = 0;
    if (nargs >= 2) {
        const mask_arg = vm.stack[vm.base + func_reg + 2];
        if (mask_arg.asString()) |mask_str| {
            for (mask_str.asSlice()) |c| {
                switch (c) {
                    'c' => mask |= 1, // call
                    'r' => mask |= 2, // return
                    'l' => mask |= 4, // line
                    else => {},
                }
            }
        }
    }

    // Get count (optional)
    var count: u32 = 0;
    if (nargs >= 3) {
        const count_arg = vm.stack[vm.base + func_reg + 3];
        if (count_arg.toInteger()) |c| {
            if (c > 0) count = @intCast(c);
        }
    }

    // Store hook settings
    vm.hook_func = hook_func;
    vm.hook_mask = mask;
    vm.hook_count = count;
}

/// debug.setlocal([thread,] level, local, value) - Assigns value to local variable
/// level is the stack level (1 = caller of setlocal)
/// local is 1-based index
/// value is the new value to assign
/// Returns: name of local variable (or nil if doesn't exist)
pub fn nativeDebugSetlocal(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 3) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }

    const level_arg = vm.stack[vm.base + func_reg + 1];
    const local_arg = vm.stack[vm.base + func_reg + 2];
    const value = vm.stack[vm.base + func_reg + 3];

    // Get level
    const level = level_arg.toInteger() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    };

    if (level < 1) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }

    const ulevel: usize = @intCast(level);
    if (ulevel > vm.callstack_size) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }

    // Get local index (1-based)
    const local_int = local_arg.toInteger() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    };

    if (local_int < 1) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }
    const local_idx: usize = @intCast(local_int - 1);

    // Get the call frame at that level
    const stack_idx = vm.callstack_size - ulevel;
    const ci = &vm.callstack[stack_idx];

    // Check if local index is within the frame's stack range
    const max_locals = ci.func.maxstacksize;
    if (local_idx >= max_locals) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }

    // Set the value on the stack
    const stack_pos = ci.base + @as(u32, @intCast(local_idx));
    vm.stack[stack_pos] = value;

    // Generate a name since we don't have locvar info
    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "(local {d})", .{local_int}) catch "(local)";

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = TValue.fromString(try vm.gc.allocString(name));
    }
}

/// debug.setupvalue(f, up, value) - Assigns value to upvalue up of function f
/// Returns the upvalue name, or nil if upvalue doesn't exist
/// up is 1-based index
pub fn nativeDebugSetupvalue(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;

    const func_arg = vm.stack[vm.base + func_reg + 1];
    const up_arg = vm.stack[vm.base + func_reg + 2];
    const value = vm.stack[vm.base + func_reg + 3];

    // Get function closure
    const closure = func_arg.asClosure() orelse {
        // Not a Lua function - return nil
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    };

    // Get upvalue index (1-based in Lua)
    const up_int = up_arg.toInteger() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    };

    // Invalid index (< 1) returns nil
    if (up_int < 1) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }
    const up_idx: usize = @intCast(up_int - 1);

    // Check bounds
    if (up_idx >= closure.upvalues.len) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }

    // Get upvalue name from proto
    const name = if (up_idx < closure.proto.upvalues.len)
        closure.proto.upvalues[up_idx].name orelse "(no name)"
    else
        "(no name)";

    // Set upvalue value
    const upval = closure.upvalues[up_idx];
    upval.set(value);

    // Return name
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = TValue.fromString(try vm.gc.allocString(name));
    }
}

/// debug.setuservalue(udata, value [, n]) - Sets the n-th user value of userdata udata to value
/// Returns udata, or nil if n is out of bounds
pub fn nativeDebugSetuservalue(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    // Get userdata argument
    const arg0 = vm.stack[vm.base + func_reg + 1];
    const ud = arg0.asUserdata() orelse {
        // Not userdata - return nil
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    };

    // Get value argument
    const value = if (nargs >= 2) vm.stack[vm.base + func_reg + 2] else TValue.nil;

    // Get index n (default 1, Lua is 1-indexed)
    const n_raw: i64 = if (nargs >= 3)
        vm.stack[vm.base + func_reg + 3].toInteger() orelse 1
    else
        1;

    // Convert to u8, treating negative and out-of-range as 0 (will fail bounds check)
    const n: u8 = if (n_raw < 1 or n_raw > 255) 0 else @intCast(n_raw);

    // Check bounds (1-indexed)
    if (n < 1 or n > ud.nuvalue) {
        // Out of bounds - return nil
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }

    // Set user value at index n-1 (convert to 0-indexed)
    const user_values = ud.userValues();
    user_values[n - 1] = value;

    // Return udata
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = arg0;
    }
}

/// debug.newuserdata(size [, nuvalue]) - Create a new full userdata (for testing)
/// This is NOT part of standard Lua - it mirrors T.newuserdata() in the Lua test suite
/// size: size of raw data block in bytes (default 0)
/// nuvalue: number of user values (default 0, max 255)
/// Returns: userdata object
pub fn nativeDebugNewuserdata(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    // Get size argument (default 0)
    const size: usize = if (nargs >= 1)
        @intCast(@max(0, vm.stack[vm.base + func_reg + 1].toInteger() orelse 0))
    else
        0;

    // Get nuvalue argument (default 0)
    const nuvalue: u8 = if (nargs >= 2)
        @intCast(@min(255, @max(0, vm.stack[vm.base + func_reg + 2].toInteger() orelse 0)))
    else
        0;

    // Allocate userdata
    const ud = try vm.gc.allocUserdata(size, nuvalue);

    // Return userdata
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = TValue.fromUserdata(ud);
    }
}

/// debug.traceback([thread,] [message [, level]]) - Returns a string with a traceback of the call stack
/// Returns a formatted string with the call stack trace
///
/// NOTE: ProtoObject lacks source filename and line number metadata,
/// so frames are displayed as "[Lua function]" without location info.
/// To add source/line info, ProtoObject would need:
///   - source: ?[]const u8 (filename)
///   - linedefined: u32
///   - PC-to-line mapping table
///
/// NOTE: Tail call optimization (TAILCALL opcode) reuses frames,
/// so the stack may appear shallower than the logical call depth.
pub fn nativeDebugTraceback(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    // Parse arguments
    var message: ?[]const u8 = null;
    var level: i64 = 1;

    if (nargs >= 1) {
        const arg1 = vm.stack[vm.base + func_reg + 1];
        if (arg1.asString()) |str| {
            message = str.asSlice();
        }
    }
    if (nargs >= 2) {
        const arg2 = vm.stack[vm.base + func_reg + 2];
        if (arg2.toInteger()) |l| {
            level = l;
        }
    }

    // Build traceback string
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    // Add message if provided
    if (message) |msg| {
        const copy_len = @min(msg.len, buf.len - pos);
        @memcpy(buf[pos..][0..copy_len], msg[0..copy_len]);
        pos += copy_len;
        if (pos < buf.len) {
            buf[pos] = '\n';
            pos += 1;
        }
    }

    // Add "stack traceback:" header
    const header = "stack traceback:";
    if (pos + header.len < buf.len) {
        @memcpy(buf[pos..][0..header.len], header);
        pos += header.len;
    }

    // Walk the call stack
    var frame_num: i64 = 0;

    // Note: callstack_size may be smaller than expected due to tail call optimization

    // First, count backwards from current callstack
    // Skip frames based on level parameter
    var i: i32 = @as(i32, @intCast(vm.callstack_size)) - 1;
    while (i >= 0) : (i -= 1) {
        frame_num += 1;
        if (frame_num < level) continue;

        const ci = &vm.callstack[@intCast(i)];

        // Add newline and tab
        if (pos + 2 < buf.len) {
            buf[pos] = '\n';
            buf[pos + 1] = '\t';
            pos += 2;
        }

        // Format frame info
        const frame_info = formatFrame(ci);
        const copy_len = @min(frame_info.len, buf.len - pos);
        @memcpy(buf[pos..][0..copy_len], frame_info[0..copy_len]);
        pos += copy_len;
    }

    // Add base_ci (main chunk) if we have room
    frame_num += 1;
    if (frame_num >= level) {
        if (pos + 2 < buf.len) {
            buf[pos] = '\n';
            buf[pos + 1] = '\t';
            pos += 2;
        }
        const main_info = "[main chunk]";
        if (pos + main_info.len < buf.len) {
            @memcpy(buf[pos..][0..main_info.len], main_info);
            pos += main_info.len;
        }
    }

    // Create result string
    const result_str = try vm.gc.allocString(buf[0..pos]);

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = TValue.fromString(result_str);
    }
}

/// Format a single stack frame for traceback
/// NOTE: Limited info available - ProtoObject has numparams, is_vararg, nups
/// but no function name, source file, or line numbers.
fn formatFrame(ci: anytype) []const u8 {
    if (ci.closure != null) {
        if (ci.func.is_vararg) {
            return "[Lua function (vararg)]";
        } else if (ci.func.numparams == 0) {
            return "[Lua function]";
        } else {
            // We can't easily format the number, so just indicate it has params
            return "[Lua function (with params)]";
        }
    } else {
        return "[Lua function]";
    }
}

/// debug.upvalueid(f, n) - Returns unique identifier for upvalue n of function f
/// Returns a unique identifier (as integer, since we don't have light userdata)
/// Two upvalues share the same id iff they refer to the same variable
pub fn nativeDebugUpvalueid(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 2) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }

    const func_arg = vm.stack[vm.base + func_reg + 1];
    const n_arg = vm.stack[vm.base + func_reg + 2];

    // Get function closure
    const closure = func_arg.asClosure() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    };

    // Get upvalue index (1-based in Lua)
    const n_int = n_arg.toInteger() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    };

    if (n_int < 1) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }
    const up_idx: usize = @intCast(n_int - 1);

    if (up_idx >= closure.upvalues.len) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }

    // Return the pointer address of the UpvalueObject as the unique id
    // This works because two upvalues that share the same variable
    // will point to the same UpvalueObject
    const upval_ptr = closure.upvalues[up_idx];
    const id: i64 = @intCast(@intFromPtr(upval_ptr));

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = .{ .integer = id };
    }
}

/// debug.upvaluejoin(f1, n1, f2, n2) - Makes upvalue n1 of function f1 refer to upvalue n2 of function f2
/// After this call, upvalue n1 of f1 and upvalue n2 of f2 share the same value
pub fn nativeDebugUpvaluejoin(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nresults;

    if (nargs < 4) return;

    const f1_arg = vm.stack[vm.base + func_reg + 1];
    const n1_arg = vm.stack[vm.base + func_reg + 2];
    const f2_arg = vm.stack[vm.base + func_reg + 3];
    const n2_arg = vm.stack[vm.base + func_reg + 4];

    // Get both closures
    const closure1 = f1_arg.asClosure() orelse return;
    const closure2 = f2_arg.asClosure() orelse return;

    // Get upvalue indices (1-based in Lua)
    const n1_int = n1_arg.toInteger() orelse return;
    const n2_int = n2_arg.toInteger() orelse return;

    if (n1_int < 1 or n2_int < 1) return;

    const idx1: usize = @intCast(n1_int - 1);
    const idx2: usize = @intCast(n2_int - 1);

    if (idx1 >= closure1.upvalues.len or idx2 >= closure2.upvalues.len) return;

    // Make f1's upvalue n1 point to the same UpvalueObject as f2's upvalue n2
    // This requires mutable access to the closure's upvalues array
    const upvalues1 = @constCast(closure1.upvalues);
    upvalues1[idx1] = closure2.upvalues[idx2];
}
