const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;

/// Lua 5.4 Operating System Library
/// Corresponds to Lua manual chapter "Operating System Facilities"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.9
/// os.clock() - Returns CPU time used by the program in seconds
pub fn nativeOsClock(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    // Use nanoTimestamp as approximation of CPU time
    const time_ns = std.time.nanoTimestamp();
    const time_sec: f64 = @as(f64, @floatFromInt(time_ns)) / 1_000_000_000.0;
    vm.stack[vm.base + func_reg] = .{ .number = time_sec };
}

/// os.date([format [, time]]) - Returns a string or a table containing date and time
pub fn nativeOsDate(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement os.date
    // format: "*t" returns table, otherwise formatted string
}

/// os.difftime(t2, t1) - Returns the difference in seconds between two time values
pub fn nativeOsDifftime(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 2) {
        vm.stack[vm.base + func_reg] = .{ .number = 0.0 };
        return;
    }

    const t2_arg = vm.stack[vm.base + func_reg + 1];
    const t1_arg = vm.stack[vm.base + func_reg + 2];

    const t2 = t2_arg.toNumber() orelse 0.0;
    const t1 = t1_arg.toNumber() orelse 0.0;

    vm.stack[vm.base + func_reg] = .{ .number = t2 - t1 };
}

/// os.execute([command]) - Executes an operating system command
pub fn nativeOsExecute(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement os.execute
    // Returns true/false and exit status
}

/// os.exit([code [, close]]) - Terminates the host program
pub fn nativeOsExit(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement os.exit
    // Should terminate with given exit code
}

/// os.getenv(varname) - Returns the value of the environment variable varname
pub fn nativeOsGetenv(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 1) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    const name_arg = vm.stack[vm.base + func_reg + 1];
    const name_obj = name_arg.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const name = name_obj.asSlice();

    // Get environment variable
    const value = std.posix.getenv(name) orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    const result = try vm.gc.allocString(value);
    vm.stack[vm.base + func_reg] = TValue.fromString(result);
}

/// os.remove(filename) - Deletes the file (or empty directory) with the given name
pub fn nativeOsRemove(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 1) {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults >= 2) {
            const err_msg = try vm.gc.allocString("bad argument #1 to 'remove' (string expected)");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_msg);
        }
        return;
    }

    const filename_arg = vm.stack[vm.base + func_reg + 1];
    const filename_obj = filename_arg.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults >= 2) {
            const err_msg = try vm.gc.allocString("bad argument #1 to 'remove' (string expected)");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_msg);
        }
        return;
    };
    const filename = filename_obj.asSlice();

    // Try to delete as file first, then as directory
    const cwd = std.fs.cwd();
    cwd.deleteFile(filename) catch |file_err| {
        // If file deletion fails due to IsDir, try as directory
        if (file_err == error.IsDir) {
            cwd.deleteDir(filename) catch |dir_err| {
                vm.stack[vm.base + func_reg] = .nil;
                if (nresults >= 2) {
                    const err_msg = switch (dir_err) {
                        error.FileNotFound => try vm.gc.allocString("No such file or directory"),
                        error.AccessDenied => try vm.gc.allocString("Permission denied"),
                        error.DirNotEmpty => try vm.gc.allocString("Directory not empty"),
                        else => try vm.gc.allocString("Unknown error"),
                    };
                    vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_msg);
                }
                return;
            };
            vm.stack[vm.base + func_reg] = .{ .boolean = true };
            return;
        }
        // File deletion failed for other reason
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults >= 2) {
            const err_msg = switch (file_err) {
                error.FileNotFound => try vm.gc.allocString("No such file or directory"),
                error.AccessDenied => try vm.gc.allocString("Permission denied"),
                else => try vm.gc.allocString("Unknown error"),
            };
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_msg);
        }
        return;
    };

    vm.stack[vm.base + func_reg] = .{ .boolean = true };
}

/// os.rename(oldname, newname) - Renames file or directory from oldname to newname
pub fn nativeOsRename(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 2) {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults >= 2) {
            const msg = if (nargs < 1)
                "bad argument #1 to 'rename' (string expected)"
            else
                "bad argument #2 to 'rename' (string expected)";
            const err_msg = try vm.gc.allocString(msg);
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_msg);
        }
        return;
    }

    const oldname_arg = vm.stack[vm.base + func_reg + 1];
    const oldname_obj = oldname_arg.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults >= 2) {
            const err_msg = try vm.gc.allocString("bad argument #1 to 'rename' (string expected)");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_msg);
        }
        return;
    };

    const newname_arg = vm.stack[vm.base + func_reg + 2];
    const newname_obj = newname_arg.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults >= 2) {
            const err_msg = try vm.gc.allocString("bad argument #2 to 'rename' (string expected)");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_msg);
        }
        return;
    };

    const oldname = oldname_obj.asSlice();
    const newname = newname_obj.asSlice();

    const cwd = std.fs.cwd();
    cwd.rename(oldname, newname) catch |err| {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults >= 2) {
            const err_msg = switch (err) {
                error.FileNotFound => try vm.gc.allocString("No such file or directory"),
                error.AccessDenied => try vm.gc.allocString("Permission denied"),
                error.PathAlreadyExists => try vm.gc.allocString("File exists"),
                else => try vm.gc.allocString("Unknown error"),
            };
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_msg);
        }
        return;
    };

    vm.stack[vm.base + func_reg] = .{ .boolean = true };
}

/// os.setlocale(locale [, category]) - Sets the current locale of the program
pub fn nativeOsSetlocale(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement os.setlocale
    // Returns new locale or nil on failure
}

/// os.time([table]) - Returns the current time when called without arguments
pub fn nativeOsTime(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    // Return current Unix timestamp (seconds since epoch)
    const timestamp = std.time.timestamp();
    vm.stack[vm.base + func_reg] = .{ .integer = timestamp };
}

/// os.tmpname() - Returns a string with a file name that can be used for a temporary file
pub fn nativeOsTmpname(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    // Generate unique filename using timestamp and random value
    const timestamp: u64 = @intCast(std.time.nanoTimestamp());
    var prng = std.Random.DefaultPrng.init(timestamp);
    const random = prng.random();
    const rand_val = random.int(u32);

    var buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "/tmp/lua_{x}_{x}", .{ timestamp, rand_val }) catch {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    const result = try vm.gc.allocString(name);
    vm.stack[vm.base + func_reg] = TValue.fromString(result);
}
