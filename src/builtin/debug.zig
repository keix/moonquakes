const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");
const ClosureObject = object.ClosureObject;

/// Lua 5.4 Debug Library
/// Corresponds to Lua manual chapter "The Debug Library"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.10
/// debug.debug() - Enters interactive mode, reads and executes each string
pub fn nativeDebugDebug(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.debug
    // Interactive debugging mode
}

/// debug.gethook([thread]) - Returns current hook settings
pub fn nativeDebugGethook(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.gethook
    // Returns hook function, mask, and count
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
                try result_table.set(what_key, TValue.fromString(try vm.gc.allocString("C")));
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
                try result_table.set(name_key, TValue.fromString(try vm.gc.allocString(name)));
                const namewhat_key = try vm.gc.allocString("namewhat");
                try result_table.set(namewhat_key, TValue.fromString(try vm.gc.allocString("field")));
            }
        }

        if (want_source) {
            const what_key = try vm.gc.allocString("what");
            try result_table.set(what_key, TValue.fromString(try vm.gc.allocString("Lua")));
            const source_key = try vm.gc.allocString("source");
            try result_table.set(source_key, TValue.fromString(try vm.gc.allocString("?")));
            const short_src_key = try vm.gc.allocString("short_src");
            try result_table.set(short_src_key, TValue.fromString(try vm.gc.allocString("?")));
            const linedefined_key = try vm.gc.allocString("linedefined");
            try result_table.set(linedefined_key, .{ .integer = 0 });
            const lastlinedefined_key = try vm.gc.allocString("lastlinedefined");
            try result_table.set(lastlinedefined_key, .{ .integer = 0 });
        }

        if (want_line) {
            const currentline_key = try vm.gc.allocString("currentline");
            try result_table.set(currentline_key, .{ .integer = -1 });
        }

        if (want_tailcall) {
            const istailcall_key = try vm.gc.allocString("istailcall");
            try result_table.set(istailcall_key, .{ .boolean = false });
        }

        if (want_upvalue) {
            const nups_key = try vm.gc.allocString("nups");
            try result_table.set(nups_key, .{ .integer = @intCast(proto.upvalues.len) });
            const nparams_key = try vm.gc.allocString("nparams");
            try result_table.set(nparams_key, .{ .integer = @intCast(proto.numparams) });
            const isvararg_key = try vm.gc.allocString("isvararg");
            try result_table.set(isvararg_key, .{ .boolean = proto.is_vararg });
        }

        if (want_func) {
            const func_key = try vm.gc.allocString("func");
            try result_table.set(func_key, TValue.fromClosure(closure));
        }
    }

    vm.stack[vm.base + func_reg] = TValue.fromTable(result_table);
}

/// debug.getlocal([thread,] f, local) - Returns name and value of local variable
pub fn nativeDebugGetlocal(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.getlocal
    // f can be function or stack level
}

/// debug.getmetatable(value) - Returns metatable of given value
/// Unlike getmetatable(), this bypasses __metatable protection
pub fn nativeDebugGetmetatable(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;

    const value = vm.stack[vm.base + func_reg + 1];

    // Get metatable directly, bypassing __metatable protection
    const result: TValue = if (value.asTable()) |table|
        if (table.metatable) |mt| TValue.fromTable(mt) else TValue.nil
    else
        TValue.nil;

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = result;
    }
}

/// debug.getregistry() - Returns the registry table
pub fn nativeDebugGetregistry(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.getregistry
    // Returns global registry table
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
pub fn nativeDebugGetuservalue(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.getuservalue
    // Works with userdata only
}

/// debug.sethook([thread,] hook, mask [, count]) - Sets given function as a hook
pub fn nativeDebugSethook(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.sethook
    // mask can contain 'c', 'r', 'l'
}

/// debug.setlocal([thread,] level, local, value) - Assigns value to local variable
pub fn nativeDebugSetlocal(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.setlocal
    // Returns name of local variable or nil
}

/// debug.setmetatable(value, table) - Sets metatable for given value
/// Unlike setmetatable(), this bypasses __metatable protection
/// Returns the value
pub fn nativeDebugSetmetatable(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;

    const value = vm.stack[vm.base + func_reg + 1];
    const mt_arg = vm.stack[vm.base + func_reg + 2];

    // Get the table to modify
    if (value.asTable()) |table| {
        // Set metatable directly, bypassing __metatable protection
        if (mt_arg.isNil()) {
            table.metatable = null;
        } else if (mt_arg.asTable()) |mt| {
            table.metatable = mt;
        }
        // Invalid metatable type is silently ignored (Lua behavior)
    }

    // Return the original value
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = value;
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
pub fn nativeDebugSetuservalue(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.setuservalue
    // Returns udata
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
pub fn nativeDebugUpvalueid(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.upvalueid
    // Returns unique identifier (light userdata)
}

/// debug.upvaluejoin(f1, n1, f2, n2) - Makes upvalue n1 of function f1 refer to upvalue n2 of function f2
pub fn nativeDebugUpvaluejoin(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement debug.upvaluejoin
    // Joins upvalue references
}
