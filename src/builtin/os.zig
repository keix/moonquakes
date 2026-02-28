const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const TableObject = @import("../runtime/gc/object.zig").TableObject;

fn makeShellScript(allocator: std.mem.Allocator, cmd: []const u8) ![]u8 {
    if (std.mem.trim(u8, cmd, " \t\r\n").len == 0) {
        return allocator.dupe(u8, "exit 0");
    }
    return std.fmt.allocPrint(
        allocator,
        "mq_status=0\n{{ {s}; mq_status=$?; }}\nexit $mq_status",
        .{cmd},
    );
}

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
    if (nresults == 0) return;

    // Get format string (default: "%c")
    var format: []const u8 = "%c";
    var use_utc = false;

    if (nargs >= 1) {
        const format_arg = vm.stack[vm.base + func_reg + 1];
        if (format_arg.asString()) |str_obj| {
            format = str_obj.asSlice();
            // Check for UTC prefix
            if (format.len > 0 and format[0] == '!') {
                use_utc = true;
                format = format[1..];
            }
        }
    }

    // Get timestamp (default: current time)
    var timestamp: i64 = std.time.timestamp();
    if (nargs >= 2) {
        const time_arg = vm.stack[vm.base + func_reg + 2];
        if (time_arg.toInteger()) |t| {
            timestamp = t;
        }
    }

    // Match Lua/C behavior for extremely large epoch values that cannot be
    // represented through the host date conversion path.
    const max_representable_ts: i64 = (@as(i64, 1) << 55);
    if (timestamp > max_representable_ts or timestamp < -max_representable_ts) {
        return vm.raiseString("time cannot be represented in this installation");
    }

    // Convert to broken-down time
    const dt = epochToDateTime(timestamp, use_utc);

    // Check for "*t" format - return table
    if (std.mem.eql(u8, format, "*t")) {
        vm.reserveSlots(func_reg, 3);
        const table = try vm.gc().allocTable();

        // year
        const year_key = try vm.gc().allocString("year");
        try table.set(TValue.fromString(year_key), .{ .integer = dt.year });

        // month (1-12)
        const month_key = try vm.gc().allocString("month");
        try table.set(TValue.fromString(month_key), .{ .integer = dt.month });

        // day (1-31)
        const day_key = try vm.gc().allocString("day");
        try table.set(TValue.fromString(day_key), .{ .integer = dt.day });

        // hour (0-23)
        const hour_key = try vm.gc().allocString("hour");
        try table.set(TValue.fromString(hour_key), .{ .integer = dt.hour });

        // min (0-59)
        const min_key = try vm.gc().allocString("min");
        try table.set(TValue.fromString(min_key), .{ .integer = dt.min });

        // sec (0-59)
        const sec_key = try vm.gc().allocString("sec");
        try table.set(TValue.fromString(sec_key), .{ .integer = dt.sec });

        // wday (1-7, Sunday is 1)
        const wday_key = try vm.gc().allocString("wday");
        try table.set(TValue.fromString(wday_key), .{ .integer = dt.wday });

        // yday (1-366)
        const yday_key = try vm.gc().allocString("yday");
        try table.set(TValue.fromString(yday_key), .{ .integer = dt.yday });

        // isdst (daylight saving, always false for now)
        const isdst_key = try vm.gc().allocString("isdst");
        try table.set(TValue.fromString(isdst_key), .{ .boolean = false });

        vm.stack[vm.base + func_reg] = TValue.fromTable(table);
        return;
    }

    // Format string output
    const result = formatDateTimeAlloc(vm.gc().allocator, format, &dt) catch |err| switch (err) {
        error.InvalidConversionSpecifier => return vm.raiseString("invalid conversion specifier"),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer vm.gc().allocator.free(result);

    const result_str = try vm.gc().allocString(result);
    vm.stack[vm.base + func_reg] = TValue.fromString(result_str);
}

/// Broken-down time structure
const DateTime = struct {
    year: i64,
    month: i64, // 1-12
    day: i64, // 1-31
    hour: i64, // 0-23
    min: i64, // 0-59
    sec: i64, // 0-59
    wday: i64, // 1-7, Sunday is 1
    yday: i64, // 1-366
};

/// Convert Unix timestamp to broken-down time
fn epochToDateTime(timestamp: i64, use_utc: bool) DateTime {
    _ = use_utc; // TODO: handle timezone offset for local time

    // Days since Unix epoch (1970-01-01)
    var days = @divFloor(timestamp, 86400);
    var remaining = @mod(timestamp, 86400);
    if (remaining < 0) {
        remaining += 86400;
        days -= 1;
    }

    const hour = @divFloor(remaining, 3600);
    remaining = @mod(remaining, 3600);
    const min = @divFloor(remaining, 60);
    const sec = @mod(remaining, 60);

    // Calculate weekday (1970-01-01 was Thursday = 5)
    var wday = @mod(days + 4, 7) + 1; // 1 = Sunday, 7 = Saturday
    if (wday < 1) wday += 7;

    const civil = civilFromDays(days);
    const yday = dayOfYear(civil.year, civil.month, civil.day);

    return .{
        .year = civil.year,
        .month = civil.month,
        .day = civil.day,
        .hour = hour,
        .min = min,
        .sec = sec,
        .wday = wday,
        .yday = yday,
    };
}

fn isLeapYear(year: i64) bool {
    if (@mod(year, 400) == 0) return true;
    if (@mod(year, 100) == 0) return false;
    if (@mod(year, 4) == 0) return true;
    return false;
}

const DateFormatError = error{InvalidConversionSpecifier};

/// Format datetime using strftime-like format
fn formatDateTimeAlloc(allocator: std.mem.Allocator, format: []const u8, dt: *const DateTime) (DateFormatError || error{OutOfMemory})![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    var i: usize = 0;

    const weekday_abbrev = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const weekday_full = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
    const month_abbrev = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const month_full = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

    // Convert to unsigned for proper formatting
    const day: u64 = @intCast(dt.day);
    const month: u64 = @intCast(dt.month);
    const hour: u64 = @intCast(dt.hour);
    const min: u64 = @intCast(dt.min);
    const sec: u64 = @intCast(dt.sec);
    const yday: u64 = @intCast(dt.yday);
    const year_short: u64 = @intCast(@mod(dt.year, 100));

    while (i < format.len) {
        if (format[i] != '%') {
            try out.append(allocator, format[i]);
            i += 1;
            continue;
        }
        if (i + 1 >= format.len) return error.InvalidConversionSpecifier;

        var spec = format[i + 1];
        var advance: usize = 2;
        if (spec == 'E' or spec == 'O') {
            const modifier = spec;
            if (i + 2 >= format.len) return error.InvalidConversionSpecifier;
            spec = format[i + 2];
            advance = 3;
            const valid_with_modifier = switch (modifier) {
                'E' => switch (spec) {
                    'c', 'C', 'x', 'X', 'y', 'Y' => true,
                    else => false,
                },
                'O' => switch (spec) {
                    'd', 'e', 'H', 'I', 'm', 'M', 'S', 'u', 'U', 'V', 'w', 'W', 'y' => true,
                    else => false,
                },
                else => false,
            };
            if (!valid_with_modifier) return error.InvalidConversionSpecifier;
        }

        switch (spec) {
            'a' => try out.appendSlice(allocator, weekday_abbrev[@intCast(dt.wday - 1)]),
            'A' => try out.appendSlice(allocator, weekday_full[@intCast(dt.wday - 1)]),
            'b', 'h' => try out.appendSlice(allocator, month_abbrev[@intCast(dt.month - 1)]),
            'B' => try out.appendSlice(allocator, month_full[@intCast(dt.month - 1)]),
            'c' => try appendFmtList(&out, allocator, "{s} {s} {d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {d}", .{
                weekday_abbrev[@intCast(dt.wday - 1)],
                month_abbrev[@intCast(dt.month - 1)],
                day,
                hour,
                min,
                sec,
                dt.year,
            }),
            'd' => try appendFmtList(&out, allocator, "{d:0>2}", .{day}),
            'e' => try appendFmtList(&out, allocator, "{d:>2}", .{day}),
            'H' => try appendFmtList(&out, allocator, "{d:0>2}", .{hour}),
            'I' => try appendFmtList(&out, allocator, "{d:0>2}", .{hour12u(hour)}),
            'j' => try appendFmtList(&out, allocator, "{d:0>3}", .{yday}),
            'm' => try appendFmtList(&out, allocator, "{d:0>2}", .{month}),
            'M' => try appendFmtList(&out, allocator, "{d:0>2}", .{min}),
            'p' => try out.appendSlice(allocator, if (dt.hour < 12) "AM" else "PM"),
            'S' => try appendFmtList(&out, allocator, "{d:0>2}", .{sec}),
            'w' => try appendFmtList(&out, allocator, "{d}", .{@as(u64, @intCast(dt.wday - 1))}),
            'x' => try appendFmtList(&out, allocator, "{d:0>2}/{d:0>2}/{d:0>2}", .{ month, day, year_short }),
            'X' => try appendFmtList(&out, allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, min, sec }),
            'y' => try appendFmtList(&out, allocator, "{d:0>2}", .{year_short}),
            'Y' => try appendFmtList(&out, allocator, "{d}", .{dt.year}),
            '%' => try out.appendSlice(allocator, "%"),
            else => return error.InvalidConversionSpecifier,
        }
        i += advance;
    }

    return out.toOwnedSlice(allocator);
}

fn hour12u(hour: u64) u64 {
    const h = @mod(hour, 12);
    return if (h == 0) 12 else h;
}

const CivilDate = struct {
    year: i64,
    month: i64,
    day: i64,
};

fn civilFromDays(days_since_epoch: i64) CivilDate {
    const z = days_since_epoch + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365); // [0, 399]
    var year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100)); // [0, 365]
    const mp = @divFloor(5 * doy + 2, 153); // [0, 11]
    const day = doy - @divFloor(153 * mp + 2, 5) + 1; // [1, 31]
    const month = mp + (if (mp < 10) @as(i64, 3) else @as(i64, -9)); // [1, 12]
    if (month <= 2) year += 1;
    return .{ .year = year, .month = month, .day = day };
}

fn dayOfYear(year: i64, month: i64, day: i64) i64 {
    const month_offsets = if (isLeapYear(year))
        [_]i64{ 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335 }
    else
        [_]i64{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    return month_offsets[@intCast(month - 1)] + day;
}

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    var y = year;
    y -= if (month <= 2) 1 else 0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = month + (if (month > 2) @as(i64, -3) else @as(i64, 9));
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn getDateField(table: *TableObject, vm: anytype, name: []const u8) !?TValue {
    const key = try vm.gc().allocString(name);
    return table.get(TValue.fromString(key));
}

fn readDateFieldInt(table: *TableObject, vm: anytype, name: []const u8, required: bool, default_value: i64) !i64 {
    const value_opt = try getDateField(table, vm, name);
    const value = value_opt orelse {
        if (required) {
            var msg_buf: [96]u8 = undefined;
            const msg = try std.fmt.bufPrint(&msg_buf, "field '{s}' is missing in date table", .{name});
            return vm.raiseString(msg);
        }
        return default_value;
    };
    return value.toInteger() orelse {
        var msg_buf: [80]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "field '{s}' is not an integer", .{name});
        return vm.raiseString(msg);
    };
}

fn checkFieldIntBound(vm: anytype, name: []const u8, value: i64) !void {
    if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) {
        var msg_buf: [80]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "field '{s}' is out-of-bound", .{name});
        return vm.raiseString(msg);
    }
}

fn normalizeYearMonth(year: *i64, month: *i64) void {
    const month_zero = month.* - 1;
    year.* += @divFloor(month_zero, 12);
    month.* = @mod(month_zero, 12) + 1;
}

fn writeDateField(table: *TableObject, vm: anytype, name: []const u8, value: TValue) !void {
    const key = try vm.gc().allocString(name);
    try table.set(TValue.fromString(key), value);
}

fn appendFmtList(out: *std.ArrayList(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
    var tmp: [96]u8 = undefined;
    const formatted = std.fmt.bufPrint(&tmp, fmt, args) catch {
        return error.OutOfMemory;
    };
    try out.appendSlice(allocator, formatted);
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
/// Returns: true, "exit", exitcode OR nil, "signal", signum
/// If command is nil, returns true if shell is available
pub fn nativeOsExecute(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    // If no command, check if shell is available
    if (nargs < 1 or vm.stack[vm.base + func_reg + 1] == .nil) {
        // Shell is available on POSIX systems
        vm.stack[vm.base + func_reg] = .{ .boolean = true };
        return;
    }

    const cmd_arg = vm.stack[vm.base + func_reg + 1];
    const cmd_obj = cmd_arg.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults >= 2) {
            const err_msg = try vm.gc().allocString("bad argument #1 to 'execute' (string expected)");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_msg);
        }
        return;
    };
    const cmd = cmd_obj.asSlice();
    const script = try makeShellScript(vm.gc().allocator, cmd);
    defer vm.gc().allocator.free(script);

    // Execute command using /bin/sh -c
    const result = std.process.Child.run(.{
        .allocator = vm.gc().allocator,
        .argv = &[_][]const u8{ "/bin/sh", "-c", script },
    }) catch {
        // Command failed to execute
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults >= 2) {
            const exit_key = try vm.gc().allocString("exit");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(exit_key);
        }
        if (nresults >= 3) {
            vm.stack[vm.base + func_reg + 2] = .{ .integer = 127 };
        }
        return;
    };
    defer vm.gc().allocator.free(result.stdout);
    defer vm.gc().allocator.free(result.stderr);

    // Check termination type
    switch (result.term) {
        .Exited => |code| {
            // Normal exit
            if (code == 0) {
                vm.stack[vm.base + func_reg] = .{ .boolean = true };
            } else {
                vm.stack[vm.base + func_reg] = .nil;
            }
            if (nresults >= 2) {
                const exit_key = try vm.gc().allocString("exit");
                vm.stack[vm.base + func_reg + 1] = TValue.fromString(exit_key);
            }
            if (nresults >= 3) {
                vm.stack[vm.base + func_reg + 2] = .{ .integer = @intCast(code) };
            }
        },
        .Signal => |sig| {
            // Killed by signal
            vm.stack[vm.base + func_reg] = .nil;
            if (nresults >= 2) {
                const sig_key = try vm.gc().allocString("signal");
                vm.stack[vm.base + func_reg + 1] = TValue.fromString(sig_key);
            }
            if (nresults >= 3) {
                vm.stack[vm.base + func_reg + 2] = .{ .integer = @intCast(sig) };
            }
        },
        else => {
            // Unknown termination (stopped, etc.)
            vm.stack[vm.base + func_reg] = .nil;
        },
    }
}

/// os.exit([code [, close]]) - Terminates the host program
/// code: exit code (default 0), true means 0, false means 1
/// close: if true, close Lua state before exiting (ignored, we always clean up)
pub fn nativeOsExit(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nresults;

    var exit_code: u8 = 0;

    if (nargs >= 1) {
        const code_arg = vm.stack[vm.base + func_reg + 1];
        if (code_arg == .boolean) {
            // true = 0 (success), false = 1 (failure)
            exit_code = if (code_arg.boolean) 0 else 1;
        } else if (code_arg.toInteger()) |code| {
            exit_code = @intCast(@mod(code, 256));
        }
    }

    // Note: In a real implementation, we would clean up VM state here
    // For now, just exit immediately
    std.process.exit(exit_code);
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

    const result = try vm.gc().allocString(value);
    vm.stack[vm.base + func_reg] = TValue.fromString(result);
}

/// os.remove(filename) - Deletes the file (or empty directory) with the given name
pub fn nativeOsRemove(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 1) {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults >= 2) {
            const err_msg = try vm.gc().allocString("bad argument #1 to 'remove' (string expected)");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_msg);
        }
        return;
    }

    const filename_arg = vm.stack[vm.base + func_reg + 1];
    const filename_obj = filename_arg.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults >= 2) {
            const err_msg = try vm.gc().allocString("bad argument #1 to 'remove' (string expected)");
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
                        error.FileNotFound => try vm.gc().allocString("No such file or directory"),
                        error.AccessDenied => try vm.gc().allocString("Permission denied"),
                        error.DirNotEmpty => try vm.gc().allocString("Directory not empty"),
                        else => try vm.gc().allocString("Unknown error"),
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
                error.FileNotFound => try vm.gc().allocString("No such file or directory"),
                error.AccessDenied => try vm.gc().allocString("Permission denied"),
                else => try vm.gc().allocString("Unknown error"),
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
            const err_msg = try vm.gc().allocString(msg);
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_msg);
        }
        return;
    }

    const oldname_arg = vm.stack[vm.base + func_reg + 1];
    const oldname_obj = oldname_arg.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults >= 2) {
            const err_msg = try vm.gc().allocString("bad argument #1 to 'rename' (string expected)");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_msg);
        }
        return;
    };

    const newname_arg = vm.stack[vm.base + func_reg + 2];
    const newname_obj = newname_arg.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults >= 2) {
            const err_msg = try vm.gc().allocString("bad argument #2 to 'rename' (string expected)");
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
                error.FileNotFound => try vm.gc().allocString("No such file or directory"),
                error.AccessDenied => try vm.gc().allocString("Permission denied"),
                error.PathAlreadyExists => try vm.gc().allocString("File exists"),
                else => try vm.gc().allocString("Unknown error"),
            };
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_msg);
        }
        return;
    };

    vm.stack[vm.base + func_reg] = .{ .boolean = true };
}

/// os.setlocale(locale [, category]) - Sets the current locale of the program
/// locale: string specifying locale, "" for native locale, or nil to query
/// category: "all" (default), "collate", "ctype", "monetary", "numeric", "time"
/// Returns: string with current locale for the category, or nil on failure
///
/// NOTE: This is a minimal implementation that only supports the "C" locale.
/// POSIX guarantees "C" and "" (native) are always available. Since we don't
/// link libc, we always operate in "C" locale. When C API integration is added,
/// this can be replaced with proper setlocale() calls.
pub fn nativeOsSetlocale(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    // Validate category if provided
    if (nargs >= 2) {
        const cat_arg = vm.stack[vm.base + func_reg + 2];
        if (cat_arg.asString()) |cat_obj| {
            const cat = cat_obj.asSlice();
            const valid = std.mem.eql(u8, cat, "all") or
                std.mem.eql(u8, cat, "collate") or
                std.mem.eql(u8, cat, "ctype") or
                std.mem.eql(u8, cat, "monetary") or
                std.mem.eql(u8, cat, "numeric") or
                std.mem.eql(u8, cat, "time");
            if (!valid) {
                vm.stack[vm.base + func_reg] = .nil;
                return;
            }
        }
    }

    // Check locale argument
    if (nargs >= 1) {
        const locale_arg = vm.stack[vm.base + func_reg + 1];
        if (locale_arg != .nil) {
            if (locale_arg.asString()) |locale_obj| {
                const locale = locale_obj.asSlice();
                // Only "C", "POSIX", and "" (native) are supported
                if (locale.len == 0 or
                    std.mem.eql(u8, locale, "C") or
                    std.mem.eql(u8, locale, "POSIX"))
                {
                    // Setting to C locale - always succeeds
                    const result_str = try vm.gc().allocString("C");
                    vm.stack[vm.base + func_reg] = TValue.fromString(result_str);
                    return;
                }
                // Unsupported locale
                vm.stack[vm.base + func_reg] = .nil;
                return;
            } else {
                // Bad argument type
                vm.stack[vm.base + func_reg] = .nil;
                return;
            }
        }
    }

    // Query current locale (nil or no argument) - always "C"
    const result_str = try vm.gc().allocString("C");
    vm.stack[vm.base + func_reg] = TValue.fromString(result_str);
}

/// os.time([table]) - Returns the current time when called without arguments
pub fn nativeOsTime(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs >= 1 and vm.stack[vm.base + func_reg + 1] != .nil) {
        const table = vm.stack[vm.base + func_reg + 1].asTable() orelse return vm.raiseString("table expected");

        var year = try readDateFieldInt(table, vm, "year", true, 1970);
        var month = try readDateFieldInt(table, vm, "month", true, 1);
        const day = try readDateFieldInt(table, vm, "day", true, 1);
        const hour = try readDateFieldInt(table, vm, "hour", false, 12);
        const min = try readDateFieldInt(table, vm, "min", false, 0);
        const sec = try readDateFieldInt(table, vm, "sec", false, 0);

        try checkFieldIntBound(vm, "month", month);
        try checkFieldIntBound(vm, "day", day);
        try checkFieldIntBound(vm, "hour", hour);
        try checkFieldIntBound(vm, "min", min);
        try checkFieldIntBound(vm, "sec", sec);

        const tm_year = year - 1900;
        if (tm_year < std.math.minInt(i32) or tm_year > std.math.maxInt(i32)) {
            return vm.raiseString("field 'year' is out-of-bound");
        }

        normalizeYearMonth(&year, &month);

        const days = daysFromCivil(year, month, 1) + (day - 1);
        const ts128: i128 = @as(i128, days) * 86400 +
            @as(i128, hour) * 3600 +
            @as(i128, min) * 60 +
            @as(i128, sec);
        if (ts128 < std.math.minInt(i64) or ts128 > std.math.maxInt(i64)) {
            return vm.raiseString("time result is out-of-bound");
        }
        const timestamp: i64 = @intCast(ts128);
        const normalized = epochToDateTime(timestamp, false);
        const normalized_tm_year = normalized.year - 1900;
        if (normalized_tm_year < std.math.minInt(i32) or normalized_tm_year > std.math.maxInt(i32)) {
            return vm.raiseString("time cannot be represented in this installation");
        }

        // Lua 5.4 updates the date table with normalized fields.
        try writeDateField(table, vm, "year", .{ .integer = normalized.year });
        try writeDateField(table, vm, "month", .{ .integer = normalized.month });
        try writeDateField(table, vm, "day", .{ .integer = normalized.day });
        try writeDateField(table, vm, "hour", .{ .integer = normalized.hour });
        try writeDateField(table, vm, "min", .{ .integer = normalized.min });
        try writeDateField(table, vm, "sec", .{ .integer = normalized.sec });
        try writeDateField(table, vm, "wday", .{ .integer = normalized.wday });
        try writeDateField(table, vm, "yday", .{ .integer = normalized.yday });
        try writeDateField(table, vm, "isdst", .{ .boolean = false });

        vm.stack[vm.base + func_reg] = .{ .integer = timestamp };
        return;
    }

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

    const result = try vm.gc().allocString(name);
    vm.stack[vm.base + func_reg] = TValue.fromString(result);
}
