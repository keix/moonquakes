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
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement os.remove
    // Returns true on success, nil and error message on failure
}

/// os.rename(oldname, newname) - Renames file or directory from oldname to newname
pub fn nativeOsRename(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement os.rename
    // Returns true on success, nil and error message on failure
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
    _ = vm;
    _ = func_reg;
    _ = nargs;
    _ = nresults;
    // TODO: Implement os.tmpname
    // Should return unique temporary filename
}
