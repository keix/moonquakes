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

    // Convert to broken-down time
    const dt = epochToDateTime(timestamp, use_utc);

    // Check for "*t" format - return table
    if (std.mem.eql(u8, format, "*t")) {
        vm.reserveSlots(func_reg, 3);
        const table = try vm.gc.allocTable();

        // year
        const year_key = try vm.gc.allocString("year");
        try table.set(TValue.fromString(year_key), .{ .integer = dt.year });

        // month (1-12)
        const month_key = try vm.gc.allocString("month");
        try table.set(TValue.fromString(month_key), .{ .integer = dt.month });

        // day (1-31)
        const day_key = try vm.gc.allocString("day");
        try table.set(TValue.fromString(day_key), .{ .integer = dt.day });

        // hour (0-23)
        const hour_key = try vm.gc.allocString("hour");
        try table.set(TValue.fromString(hour_key), .{ .integer = dt.hour });

        // min (0-59)
        const min_key = try vm.gc.allocString("min");
        try table.set(TValue.fromString(min_key), .{ .integer = dt.min });

        // sec (0-59)
        const sec_key = try vm.gc.allocString("sec");
        try table.set(TValue.fromString(sec_key), .{ .integer = dt.sec });

        // wday (1-7, Sunday is 1)
        const wday_key = try vm.gc.allocString("wday");
        try table.set(TValue.fromString(wday_key), .{ .integer = dt.wday });

        // yday (1-366)
        const yday_key = try vm.gc.allocString("yday");
        try table.set(TValue.fromString(yday_key), .{ .integer = dt.yday });

        // isdst (daylight saving, always false for now)
        const isdst_key = try vm.gc.allocString("isdst");
        try table.set(TValue.fromString(isdst_key), .{ .boolean = false });

        vm.stack[vm.base + func_reg] = TValue.fromTable(table);
        return;
    }

    // Format string output
    var buf: [256]u8 = undefined;
    const result = formatDateTime(&buf, format, &dt) catch {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    const result_str = try vm.gc.allocString(result);
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

    // Calculate year, month, day from days since epoch
    var year: i64 = 1970;
    var yday: i64 = 1;

    // Fast forward years
    while (true) {
        const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }

    yday = days + 1;

    // Calculate month and day
    const leap = isLeapYear(year);
    const month_days = if (leap)
        [_]i64{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: i64 = 1;
    var day = days;
    for (month_days) |mdays| {
        if (day < mdays) break;
        day -= mdays;
        month += 1;
    }
    day += 1;

    return .{
        .year = year,
        .month = month,
        .day = day,
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

/// Format datetime using strftime-like format
fn formatDateTime(buf: []u8, format: []const u8, dt: *const DateTime) ![]u8 {
    var pos: usize = 0;
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
        if (format[i] == '%' and i + 1 < format.len) {
            const spec = format[i + 1];
            const written = switch (spec) {
                'a' => try appendStr(buf[pos..], weekday_abbrev[@intCast(dt.wday - 1)]),
                'A' => try appendStr(buf[pos..], weekday_full[@intCast(dt.wday - 1)]),
                'b', 'h' => try appendStr(buf[pos..], month_abbrev[@intCast(dt.month - 1)]),
                'B' => try appendStr(buf[pos..], month_full[@intCast(dt.month - 1)]),
                'c' => try appendFmt(buf[pos..], "{s} {s} {d:0>2} {d:0>2}:{d:0>2}:{d:0>2} {d}", .{
                    weekday_abbrev[@intCast(dt.wday - 1)],
                    month_abbrev[@intCast(dt.month - 1)],
                    day,
                    hour,
                    min,
                    sec,
                    dt.year,
                }),
                'd' => try appendFmt(buf[pos..], "{d:0>2}", .{day}),
                'e' => try appendFmt(buf[pos..], "{d:>2}", .{day}),
                'H' => try appendFmt(buf[pos..], "{d:0>2}", .{hour}),
                'I' => try appendFmt(buf[pos..], "{d:0>2}", .{hour12u(hour)}),
                'j' => try appendFmt(buf[pos..], "{d:0>3}", .{yday}),
                'm' => try appendFmt(buf[pos..], "{d:0>2}", .{month}),
                'M' => try appendFmt(buf[pos..], "{d:0>2}", .{min}),
                'p' => try appendStr(buf[pos..], if (dt.hour < 12) "AM" else "PM"),
                'S' => try appendFmt(buf[pos..], "{d:0>2}", .{sec}),
                'w' => try appendFmt(buf[pos..], "{d}", .{@as(u64, @intCast(dt.wday - 1))}),
                'x' => try appendFmt(buf[pos..], "{d:0>2}/{d:0>2}/{d:0>2}", .{ month, day, year_short }),
                'X' => try appendFmt(buf[pos..], "{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, min, sec }),
                'y' => try appendFmt(buf[pos..], "{d:0>2}", .{year_short}),
                'Y' => try appendFmt(buf[pos..], "{d}", .{dt.year}),
                '%' => try appendStr(buf[pos..], "%"),
                else => try appendStr(buf[pos..], ""),
            };
            pos += written;
            i += 2;
        } else {
            if (pos >= buf.len) return error.BufferTooSmall;
            buf[pos] = format[i];
            pos += 1;
            i += 1;
        }
    }

    return buf[0..pos];
}

fn hour12(hour: i64) i64 {
    const h = @mod(hour, 12);
    return if (h == 0) 12 else h;
}

fn hour12u(hour: u64) u64 {
    const h = @mod(hour, 12);
    return if (h == 0) 12 else h;
}

fn appendStr(buf: []u8, str: []const u8) !usize {
    if (str.len > buf.len) return error.BufferTooSmall;
    @memcpy(buf[0..str.len], str);
    return str.len;
}

fn appendFmt(buf: []u8, comptime fmt: []const u8, args: anytype) !usize {
    var stream = std.io.fixedBufferStream(buf);
    stream.writer().print(fmt, args) catch return error.BufferTooSmall;
    return stream.pos;
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
            const err_msg = try vm.gc.allocString("bad argument #1 to 'execute' (string expected)");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_msg);
        }
        return;
    };
    const cmd = cmd_obj.asSlice();

    // Execute command using /bin/sh -c
    const result = std.process.Child.run(.{
        .allocator = vm.gc.allocator,
        .argv = &[_][]const u8{ "/bin/sh", "-c", cmd },
    }) catch {
        // Command failed to execute
        vm.stack[vm.base + func_reg] = .nil;
        if (nresults >= 2) {
            const exit_key = try vm.gc.allocString("exit");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(exit_key);
        }
        if (nresults >= 3) {
            vm.stack[vm.base + func_reg + 2] = .{ .integer = 127 };
        }
        return;
    };
    defer vm.gc.allocator.free(result.stdout);
    defer vm.gc.allocator.free(result.stderr);

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
                const exit_key = try vm.gc.allocString("exit");
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
                const sig_key = try vm.gc.allocString("signal");
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
                    const result_str = try vm.gc.allocString("C");
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
    const result_str = try vm.gc.allocString("C");
    vm.stack[vm.base + func_reg] = TValue.fromString(result_str);
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
