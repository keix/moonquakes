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
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement io.flush
    // Flushes default output file
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
pub fn nativeIoOpen(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement io.open
    // Returns file handle or nil on error
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

    // Create file handle table
    const file_table = try vm.gc.allocTable();

    // Store output
    const output_key = try vm.gc.allocString(FILE_OUTPUT_KEY);
    const output_str = try vm.gc.allocString(result.output);
    try file_table.set(output_key, TValue.fromString(output_str));
    vm.allocator.free(result.output);

    // Store exit code
    const exitcode_key = try vm.gc.allocString(FILE_EXITCODE_KEY);
    try file_table.set(exitcode_key, .{ .integer = result.exit_code });

    // Store closed flag
    const closed_key = try vm.gc.allocString(FILE_CLOSED_KEY);
    try file_table.set(closed_key, .{ .boolean = false });

    // Create metatable with file methods
    const mt = try createFileMetatable(vm);
    file_table.metatable = mt;

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = TValue.fromTable(file_table);
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
fn createFileMetatable(vm: anytype) !*TableObject {
    const mt = try vm.gc.allocTable();

    // Create __index table with methods
    const index_table = try vm.gc.allocTable();

    // Add 'read' method
    const read_key = try vm.gc.allocString("read");
    const read_nc = try vm.gc.allocNativeClosure(.{ .id = .file_read });
    try index_table.set(read_key, TValue.fromNativeClosure(read_nc));

    // Add 'close' method
    const close_key = try vm.gc.allocString("close");
    const close_nc = try vm.gc.allocNativeClosure(.{ .id = .file_close });
    try index_table.set(close_key, TValue.fromNativeClosure(close_nc));

    // Set __index
    const index_key = try vm.gc.allocString("__index");
    try mt.set(index_key, TValue.fromTable(index_table));

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
pub fn nativeIoType(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement io.type
    // Returns "file", "closed file", or nil
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

        // Update remaining output
        const remaining = if (end < output.len) output[end + 1 ..] else "";
        const remaining_str = try vm.gc.allocString(remaining);
        try file_table.set(output_key, TValue.fromString(remaining_str));

        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = TValue.fromString(line_str);
        }
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

        // Update remaining output
        const remaining = output[end..];
        const remaining_str = try vm.gc.allocString(remaining);
        try file_table.set(output_key, TValue.fromString(remaining_str));

        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = TValue.fromString(line_str);
        }
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
