const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");
const TableObject = object.TableObject;

/// Lua 5.4 Input and Output Library
/// Corresponds to Lua manual chapter "Input and Output Facilities"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.8
/// Keys for file handle table fields
const FILE_OUTPUT_KEY = "_output";
const FILE_EXITCODE_KEY = "_exitcode";
const FILE_CLOSED_KEY = "_closed";
pub fn nativeIoWrite(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    const string = @import("string.zig");
    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    // Save original top to restore later
    const saved_top = vm.top;

    var i: u32 = 0;
    while (i < nargs) : (i += 1) {
        // Use temporary registers for tostring conversion
        const tmp_reg = vm.top;
        vm.top += 2;

        // Copy argument to temporary register
        const arg_reg = func_reg + 1 + i;
        vm.stack[vm.base + tmp_reg + 1] = vm.stack[vm.base + arg_reg];

        // Call tostring
        try string.nativeToString(vm, tmp_reg, 1, 1);

        // Get the string result
        const result = vm.stack[vm.base + tmp_reg];
        if (result.asString()) |str_val| {
            try stdout.writeAll(str_val.asSlice());
        }

        vm.top -= 2;
    }

    // Restore original top
    vm.top = saved_top;

    // Set result (io.write returns file object, but we return nil for simplicity)
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = .nil;
    }
}

/// io.close([file]) - Closes file or default output file
pub fn nativeIoClose(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement io.close
    // If file is nil, closes default output file
}

/// io.flush() - Saves any written data to default output file
pub fn nativeIoFlush(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    // stdout is unbuffered in Zig, so flush is a no-op
    // but we return true for compatibility
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = .{ .boolean = true };
    }
}

/// io.input([file]) - Sets default input file when called with a file name or handle
pub fn nativeIoInput(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement io.input
    // Returns current default input file when called with no arguments
}

/// io.lines([filename, ...]) - Returns an iterator function for reading files line by line
pub fn nativeIoLines(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement io.lines
    // If filename is nil, uses default input file
}

/// io.open(filename [, mode]) - Opens a file in specified mode
/// Returns file handle or nil, errmsg on error
/// Currently supports "r" mode (read) - reads entire file into memory
pub fn nativeIoOpen(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    // Reserve stack slots BEFORE any GC-triggering allocation.
    // Stack layout: func_reg (result), +1 (temp/errmsg), +2..+4 (metatable creation)
    vm.reserveSlots(func_reg, 5);

    if (nargs < 1) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Get filename
    const filename_arg = vm.stack[vm.base + func_reg + 1];
    const filename_obj = filename_arg.asString() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const filename = filename_obj.asSlice();

    // Get mode (optional, default "r")
    var mode: []const u8 = "r";
    if (nargs >= 2) {
        const mode_arg = vm.stack[vm.base + func_reg + 2];
        if (mode_arg.asString()) |m| {
            mode = m.asSlice();
        }
    }

    // Currently only support read mode
    if (mode.len == 0 or mode[0] != 'r') {
        // TODO: implement write modes
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        if (nresults > 1) {
            const err_str = try vm.gc.allocString("unsupported mode");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
        }
        return;
    }

    // Open and read the file
    const file = std.fs.cwd().openFile(filename, .{}) catch {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        if (nresults > 1) {
            const err_str = try vm.gc.allocString("cannot open file");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
        }
        return;
    };
    defer file.close();

    // Read entire file content
    const content = file.readToEndAlloc(vm.allocator, 10 * 1024 * 1024) catch {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        if (nresults > 1) {
            const err_str = try vm.gc.allocString("cannot read file");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
        }
        return;
    };
    defer vm.allocator.free(content);

    // Create file handle table
    const file_table = try vm.gc.allocTable();
    vm.stack[vm.base + func_reg] = TValue.fromTable(file_table);

    // Store file content
    const output_key = try vm.gc.allocString(FILE_OUTPUT_KEY);
    vm.stack[vm.base + func_reg + 1] = TValue.fromString(output_key);
    const output_str = try vm.gc.allocString(content);
    try file_table.set(output_key, TValue.fromString(output_str));

    // Store closed flag
    const closed_key = try vm.gc.allocString(FILE_CLOSED_KEY);
    try file_table.set(closed_key, .{ .boolean = false });

    // Store exit code (0 for regular files)
    const exitcode_key = try vm.gc.allocString(FILE_EXITCODE_KEY);
    try file_table.set(exitcode_key, .{ .integer = 0 });

    // Create metatable with file methods
    const mt = try createFileMetatable(vm, func_reg + 2);
    file_table.metatable = mt;

    // Result already in stack at func_reg
    if (nresults == 0) {
        vm.stack[vm.base + func_reg] = .nil;
    }
}

/// io.output([file]) - Sets default output file when called with a file name or handle
pub fn nativeIoOutput(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement io.output
    // Returns current default output file when called with no arguments
}

/// io.popen(prog [, mode]) - Opens a pipe to program prog
/// Returns a file handle table with captured output and exit code
/// The file handle supports :read('*a') and :close() methods
pub fn nativeIoPopen(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 1) {
        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = .nil;
        }
        return;
    }

    // Get command string
    const cmd_arg = vm.stack[vm.base + func_reg + 1];
    const cmd_str = cmd_arg.asString() orelse {
        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = .nil;
        }
        return;
    };
    const cmd = cmd_str.asSlice();

    // Run the command and capture output
    const result = runCommand(vm.allocator, cmd) catch {
        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = .nil;
        }
        return;
    };

    // GC SAFETY CONTRACT:
    // Native functions must protect allocated objects from GC.
    // Objects in Zig local variables are NOT GC roots.
    //
    // REQUIRED PATTERN: allocate -> store in stack -> allocate next
    //   1. Allocate object
    //   2. Immediately store in VM stack slot (now a GC root)
    //   3. Safe to allocate more - previous object is protected
    //
    // UNSAFE PATTERN (causes use-after-free):
    //   const obj1 = try gc.allocTable();
    //   const obj2 = try gc.allocString("key");  // GC may run here!
    //   try obj1.set(...);  // obj1 might be freed
    //
    // Stack slot usage in this function:
    //   func_reg:     file_table (result)
    //   func_reg+1:   temp for intermediate allocations
    //   func_reg+2-4: reserved for createFileMetatable

    // CRITICAL: Reserve stack slots BEFORE any GC-triggering allocation.
    // GC uses vm.top as the boundary; only slots below vm.top are scanned as roots.
    // Stack layout: func_reg (result), +1 (temp), +2..+4 (metatable creation)
    vm.reserveSlots(func_reg, 5);

    const file_table = try vm.gc.allocTable();
    vm.stack[vm.base + func_reg] = TValue.fromTable(file_table);

    // output_key must be protected before allocating output_str
    const output_key = try vm.gc.allocString(FILE_OUTPUT_KEY);
    vm.stack[vm.base + func_reg + 1] = TValue.fromString(output_key);
    const output_str = try vm.gc.allocString(result.output);
    try file_table.set(output_key, TValue.fromString(output_str));
    vm.allocator.free(result.output);

    // Store exit code
    const exitcode_key = try vm.gc.allocString(FILE_EXITCODE_KEY);
    try file_table.set(exitcode_key, .{ .integer = result.exit_code });

    // Store closed flag
    const closed_key = try vm.gc.allocString(FILE_CLOSED_KEY);
    try file_table.set(closed_key, .{ .boolean = false });

    // Create metatable with file methods (use func_reg + 2 as temp slot)
    const mt = try createFileMetatable(vm, func_reg + 2);
    file_table.metatable = mt;

    // Result already in stack at func_reg
    if (nresults == 0) {
        vm.stack[vm.base + func_reg] = .nil;
    }
}

/// Result from running a command
const CommandResult = struct {
    output: []u8,
    exit_code: i64,
};

/// Run a shell command and capture its output
fn runCommand(allocator: std.mem.Allocator, cmd: []const u8) !CommandResult {
    // Use /bin/sh -c to run the command (handles pipes, redirects, etc.)
    const argv = [_][]const u8{ "/bin/sh", "-c", cmd };

    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // Read all stdout
    var stdout_list: std.ArrayList(u8) = .{};
    defer stdout_list.deinit(allocator);

    // Read stdout in chunks
    var stdout_reader = child.stdout.?;
    while (true) {
        var buf: [4096]u8 = undefined;
        const bytes_read = try stdout_reader.read(&buf);
        if (bytes_read == 0) break;
        try stdout_list.appendSlice(allocator, buf[0..bytes_read]);
    }

    // Also read stderr and append (for 2>&1 behavior)
    var stderr_reader = child.stderr.?;
    while (true) {
        var buf: [4096]u8 = undefined;
        const bytes_read = try stderr_reader.read(&buf);
        if (bytes_read == 0) break;
        try stdout_list.appendSlice(allocator, buf[0..bytes_read]);
    }

    // Wait for process to complete
    const term = try child.wait();

    const exit_code: i64 = switch (term) {
        .Exited => |code| code,
        .Signal => |sig| -@as(i64, sig),
        .Stopped => |sig| -@as(i64, sig),
        .Unknown => |val| -@as(i64, val),
    };

    // Transfer ownership of the output buffer
    const output = try stdout_list.toOwnedSlice(allocator);

    return .{
        .output = output,
        .exit_code = exit_code,
    };
}

/// Create metatable for file handles with read/close methods
///
/// GC SAFETY CONTRACT:
/// Uses temp stack slots to protect intermediate allocations.
/// Pattern: allocate -> store in stack[temp_slot+N] -> allocate next
///
/// Stack slot usage:
///   temp_slot:   metatable (mt)
///   temp_slot+1: index_table
///   temp_slot+2: scratch for native closures
fn createFileMetatable(vm: anytype, temp_slot: u32) !*TableObject {
    // Stack slot usage:
    //   temp_slot:   metatable (mt)
    //   temp_slot+1: index_table
    //   temp_slot+2: scratch for native closures

    const mt = try vm.gc.allocTable();
    vm.stack[vm.base + temp_slot] = TValue.fromTable(mt);

    const index_table = try vm.gc.allocTable();
    vm.stack[vm.base + temp_slot + 1] = TValue.fromTable(index_table);

    // Both tables protected, safe to set __index
    try mt.set(vm.mm_keys.index, TValue.fromTable(index_table));

    // Native closure must be protected before allocating its key string
    const read_nc = try vm.gc.allocNativeClosure(.{ .id = .file_read });
    vm.stack[vm.base + temp_slot + 2] = TValue.fromNativeClosure(read_nc);
    const read_key = try vm.gc.allocString("read");
    try index_table.set(read_key, TValue.fromNativeClosure(read_nc));

    // Reuse scratch slot for close method
    const close_nc = try vm.gc.allocNativeClosure(.{ .id = .file_close });
    vm.stack[vm.base + temp_slot + 2] = TValue.fromNativeClosure(close_nc);
    const close_key = try vm.gc.allocString("close");
    try index_table.set(close_key, TValue.fromNativeClosure(close_nc));

    return mt;
}

/// io.read(...) - Reads from default input file according to given formats
pub fn nativeIoRead(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement io.read
    // Supports formats like "*a", "*l", "*n", number
}

/// io.tmpfile() - Returns a handle for a temporary file
pub fn nativeIoTmpfile(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement io.tmpfile
    // File is opened in "w+b" mode and automatically removed when closed
}

/// io.type(obj) - Checks whether obj is a valid file handle
/// Returns "file", "closed file", or nil
pub fn nativeIoType(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 1) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const arg = vm.stack[vm.base + func_reg + 1];
    const file_table = arg.asTable() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    // Check if it has _closed field (our file handle marker)
    const closed_key = try vm.gc.allocString(FILE_CLOSED_KEY);
    if (file_table.get(closed_key)) |closed_val| {
        if (closed_val.toBoolean()) {
            const result = try vm.gc.allocString("closed file");
            vm.stack[vm.base + func_reg] = TValue.fromString(result);
        } else {
            const result = try vm.gc.allocString("file");
            vm.stack[vm.base + func_reg] = TValue.fromString(result);
        }
    } else {
        vm.stack[vm.base + func_reg] = .nil;
    }
}

// File handle methods (these would be implemented when userdata/file handles are added)

/// file:close() - Closes file handle
/// For popen handles, returns: true/nil, "exit", exit_code
pub fn nativeFileClose(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 1) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Get the file handle table (self)
    const self_arg = vm.stack[vm.base + func_reg + 1];
    const file_table = self_arg.asTable() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    // Check if already closed
    const closed_key = try vm.gc.allocString(FILE_CLOSED_KEY);
    if (file_table.get(closed_key)) |closed_val| {
        if (closed_val.toBoolean()) {
            // Already closed
            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
            return;
        }
    }

    // Mark as closed
    try file_table.set(closed_key, .{ .boolean = true });

    // Get exit code
    const exitcode_key = try vm.gc.allocString(FILE_EXITCODE_KEY);
    const exit_code = if (file_table.get(exitcode_key)) |v| v.toInteger() orelse 0 else 0;

    // Return: ok, "exit", code
    // ok is true if exit_code == 0, nil otherwise
    const ok: TValue = if (exit_code == 0) .{ .boolean = true } else .nil;

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = ok;
    }
    if (nresults > 1) {
        const exit_str = try vm.gc.allocString("exit");
        vm.stack[vm.base + func_reg + 1] = TValue.fromString(exit_str);
    }
    if (nresults > 2) {
        vm.stack[vm.base + func_reg + 2] = .{ .integer = exit_code };
    }
}

/// file:flush() - Saves any written data to file
pub fn nativeFileFlush(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement file:flush method
}

/// file:lines(...) - Returns iterator for reading file line by line
pub fn nativeFileLines(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement file:lines method
}

/// file:read(...) - Reads from file according to given formats
/// Supports: "*a" (read all), "*l" (read line), "*n" (read number)
/// For popen handles, returns the captured output
pub fn nativeFileRead(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 1) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Get the file handle table (self)
    const self_arg = vm.stack[vm.base + func_reg + 1];
    const file_table = self_arg.asTable() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    // Check if closed
    const closed_key = try vm.gc.allocString(FILE_CLOSED_KEY);
    if (file_table.get(closed_key)) |closed_val| {
        if (closed_val.toBoolean()) {
            // File is closed
            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
            return;
        }
    }

    // Get format argument (default to "*l")
    var format: []const u8 = "*l";
    if (nargs > 1) {
        const fmt_arg = vm.stack[vm.base + func_reg + 2];
        if (fmt_arg.asString()) |s| {
            format = s.asSlice();
        }
    }

    // Get stored output
    const output_key = try vm.gc.allocString(FILE_OUTPUT_KEY);
    const output_val = file_table.get(output_key) orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const output_str = output_val.asString() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const output = output_str.asSlice();

    // Handle different formats
    if (std.mem.eql(u8, format, "*a") or std.mem.eql(u8, format, "a")) {
        // Read all - return entire output
        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = output_val;
        }
        // Clear the output (it's been consumed)
        const empty_str = try vm.gc.allocString("");
        try file_table.set(output_key, TValue.fromString(empty_str));
    } else if (std.mem.eql(u8, format, "*l") or std.mem.eql(u8, format, "l")) {
        // Read line (without newline)
        if (output.len == 0) {
            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
            return;
        }

        // Find newline
        var end: usize = 0;
        while (end < output.len and output[end] != '\n') : (end += 1) {}

        const line = output[0..end];
        const line_str = try vm.gc.allocString(line);
        // Store in stack immediately to protect from GC
        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = TValue.fromString(line_str);
        }

        // Now safe to allocate remaining
        const remaining = if (end < output.len) output[end + 1 ..] else "";
        const remaining_str = try vm.gc.allocString(remaining);
        try file_table.set(output_key, TValue.fromString(remaining_str));
    } else if (std.mem.eql(u8, format, "*L") or std.mem.eql(u8, format, "L")) {
        // Read line (with newline)
        if (output.len == 0) {
            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
            return;
        }

        // Find newline
        var end: usize = 0;
        while (end < output.len and output[end] != '\n') : (end += 1) {}
        if (end < output.len) end += 1; // Include newline

        const line = output[0..end];
        const line_str = try vm.gc.allocString(line);
        // Store in stack immediately to protect from GC
        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = TValue.fromString(line_str);
        }

        // Now safe to allocate remaining
        const remaining = output[end..];
        const remaining_str = try vm.gc.allocString(remaining);
        try file_table.set(output_key, TValue.fromString(remaining_str));
    } else {
        // Unknown format, return nil
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
    }
}

/// file:seek([whence [, offset]]) - Sets and gets file position
pub fn nativeFileSeek(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement file:seek method
    // whence can be "set", "cur", "end"
}

/// file:setvbuf(mode [, size]) - Sets buffering mode for file
pub fn nativeFileSetvbuf(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement file:setvbuf method
    // mode can be "no", "full", "line"
}

/// file:write(...) - Writes values to file
pub fn nativeFileWrite(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement file:write method
}
