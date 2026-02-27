const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");
const TableObject = object.TableObject;
const GC = @import("../runtime/gc/gc.zig").GC;

/// Lua 5.4 Input and Output Library
/// Corresponds to Lua manual chapter "Input and Output Facilities"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.8
/// Keys for file handle table fields
const FILE_OUTPUT_KEY = "_output";
const FILE_EXITCODE_KEY = "_exitcode";
const FILE_CLOSED_KEY = "_closed";
const FILE_FILENAME_KEY = "_filename";
const FILE_MODE_KEY = "_mode";
const FILE_POS_KEY = "_pos";
const FILE_TMPFILE_KEY = "_tmpfile";
const FILE_STDIO_KEY = "_stdio"; // "stdin", "stdout", or "stderr"

// Keys for io table default handles
const IO_DEFAULT_INPUT_KEY = "_defaultInput";
const IO_DEFAULT_OUTPUT_KEY = "_defaultOutput";

pub fn initStdioHandles(io_table: *TableObject, gc: *GC) !void {
    const stdin_handle = try createStdioHandleInit(gc, "stdin");
    const stdout_handle = try createStdioHandleInit(gc, "stdout");
    const stderr_handle = try createStdioHandleInit(gc, "stderr");

    const stdin_key = try gc.allocString("stdin");
    const stdout_key = try gc.allocString("stdout");
    const stderr_key = try gc.allocString("stderr");
    const default_input_key = try gc.allocString(IO_DEFAULT_INPUT_KEY);
    const default_output_key = try gc.allocString(IO_DEFAULT_OUTPUT_KEY);

    try io_table.set(TValue.fromString(stdin_key), TValue.fromTable(stdin_handle));
    try io_table.set(TValue.fromString(stdout_key), TValue.fromTable(stdout_handle));
    try io_table.set(TValue.fromString(stderr_key), TValue.fromTable(stderr_handle));
    try io_table.set(TValue.fromString(default_input_key), TValue.fromTable(stdin_handle));
    try io_table.set(TValue.fromString(default_output_key), TValue.fromTable(stdout_handle));
}

fn createFileMetatableInit(gc: *GC) !*TableObject {
    const mt = try gc.allocTable();
    const index_table = try gc.allocTable();

    try mt.set(TValue.fromString(gc.mm_keys.get(.index)), TValue.fromTable(index_table));
    try mt.set(TValue.fromString(gc.mm_keys.get(.name)), TValue.fromString(try gc.allocString("FILE*")));

    const read_nc = try gc.allocNativeClosure(.{ .id = .file_read });
    const read_key = try gc.allocString("read");
    try index_table.set(TValue.fromString(read_key), TValue.fromNativeClosure(read_nc));

    const close_nc = try gc.allocNativeClosure(.{ .id = .file_close });
    const close_key = try gc.allocString("close");
    try index_table.set(TValue.fromString(close_key), TValue.fromNativeClosure(close_nc));
    try mt.set(TValue.fromString(gc.mm_keys.get(.close)), TValue.fromNativeClosure(close_nc));

    const write_nc = try gc.allocNativeClosure(.{ .id = .file_write });
    const write_key = try gc.allocString("write");
    try index_table.set(TValue.fromString(write_key), TValue.fromNativeClosure(write_nc));

    const lines_nc = try gc.allocNativeClosure(.{ .id = .file_lines });
    const lines_key = try gc.allocString("lines");
    try index_table.set(TValue.fromString(lines_key), TValue.fromNativeClosure(lines_nc));

    const flush_nc = try gc.allocNativeClosure(.{ .id = .file_flush });
    const flush_key = try gc.allocString("flush");
    try index_table.set(TValue.fromString(flush_key), TValue.fromNativeClosure(flush_nc));

    const seek_nc = try gc.allocNativeClosure(.{ .id = .file_seek });
    const seek_key = try gc.allocString("seek");
    try index_table.set(TValue.fromString(seek_key), TValue.fromNativeClosure(seek_nc));

    const setvbuf_nc = try gc.allocNativeClosure(.{ .id = .file_setvbuf });
    const setvbuf_key = try gc.allocString("setvbuf");
    try index_table.set(TValue.fromString(setvbuf_key), TValue.fromNativeClosure(setvbuf_nc));

    return mt;
}

fn createStdioHandleInit(gc: *GC, stdio_type: []const u8) !*TableObject {
    const file_table = try gc.allocTable();

    const stdio_key = try gc.allocString(FILE_STDIO_KEY);
    const stdio_str = try gc.allocString(stdio_type);
    try file_table.set(TValue.fromString(stdio_key), TValue.fromString(stdio_str));

    const output_key = try gc.allocString(FILE_OUTPUT_KEY);
    const empty_str = try gc.allocString("");
    try file_table.set(TValue.fromString(output_key), TValue.fromString(empty_str));

    const closed_key = try gc.allocString(FILE_CLOSED_KEY);
    try file_table.set(TValue.fromString(closed_key), .{ .boolean = false });

    const mode_key = try gc.allocString(FILE_MODE_KEY);
    const mode_str = try gc.allocString(if (std.mem.eql(u8, stdio_type, "stdin")) "r" else "w");
    try file_table.set(TValue.fromString(mode_key), TValue.fromString(mode_str));

    const pos_key = try gc.allocString(FILE_POS_KEY);
    try file_table.set(TValue.fromString(pos_key), .{ .integer = 0 });

    file_table.metatable = try createFileMetatableInit(gc);
    return file_table;
}

fn isValidOpenMode(mode: []const u8) bool {
    if (mode.len == 0) return false;
    if (mode[0] != 'r' and mode[0] != 'w' and mode[0] != 'a') return false;
    if (mode.len == 1) return true;
    if (std.mem.eql(u8, mode[1..], "b")) return true;
    if (std.mem.eql(u8, mode[1..], "+")) return true;
    if (std.mem.eql(u8, mode[1..], "+b")) return true;
    return false;
}

fn parseHexIntegerWrapLocal(str: []const u8) ?i64 {
    if (str.len < 3) return null;
    var idx: usize = 0;
    var neg = false;
    if (str[idx] == '+' or str[idx] == '-') {
        neg = str[idx] == '-';
        idx += 1;
        if (idx >= str.len) return null;
    }
    if (idx + 1 >= str.len) return null;
    if (str[idx] != '0' or (str[idx + 1] != 'x' and str[idx + 1] != 'X')) return null;
    idx += 2;
    if (idx >= str.len) return null;

    var value: u64 = 0;
    while (idx < str.len) : (idx += 1) {
        const c = str[idx];
        const digit: u64 = switch (c) {
            '0'...'9' => @intCast(c - '0'),
            'a'...'f' => @intCast(c - 'a' + 10),
            'A'...'F' => @intCast(c - 'A' + 10),
            else => return null,
        };
        value = (value << 4) | digit;
    }
    if (neg) value = 0 -% value;
    return @bitCast(value);
}

fn parseHexFloatLocal(str: []const u8) ?f64 {
    if (str.len < 3) return null;
    if (std.mem.indexOfAny(u8, str, "pP") == null and std.mem.indexOfScalar(u8, str, '.') == null) return null;
    // Reuse Zig parser for hex-floats if supported by toolchain.
    return std.fmt.parseFloat(f64, str) catch null;
}

fn parseLuaNumberToken(str: []const u8) ?TValue {
    if (str.len == 0) return null;
    if (parseHexIntegerWrapLocal(str)) |i| return TValue{ .integer = i };
    if (parseHexFloatLocal(str)) |n| return TValue{ .number = n };
    if (std.fmt.parseInt(i64, str, 10)) |i| return TValue{ .integer = i } else |_| {}
    if (std.fmt.parseFloat(f64, str)) |n| return TValue{ .number = n } else |_| {}
    return null;
}

const ReadNumberResult = struct {
    value: ?TValue,
    new_pos: usize,
};

fn isDecDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigitLocal(c: u8) bool {
    return isDecDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn readLuaNumberFromContent(content: []const u8, start_pos: usize) ReadNumberResult {
    // Lua reads a bounded numeral prefix from streams; this keeps "too long number"
    // behavior compatible enough for files.lua (leave unread tail in the stream).
    const max_scan_len: usize = 400;

    var pos = start_pos;
    while (pos < content.len and std.ascii.isWhitespace(content[pos])) : (pos += 1) {}
    if (pos >= content.len) return .{ .value = null, .new_pos = pos };

    const begin = pos;
    var i = pos;

    if (content[i] == '+' or content[i] == '-') {
        i += 1;
        if (i >= content.len) return .{ .value = null, .new_pos = i };
        if (i - begin >= max_scan_len) return .{ .value = null, .new_pos = i };
    }

    var consumed_any = false;

    if (i + 1 < content.len and content[i] == '0' and (content[i + 1] == 'x' or content[i + 1] == 'X')) {
        i += 2; // consume 0x prefix even if malformed after it
        if (i - begin >= max_scan_len) i = begin + max_scan_len;

        while (i < content.len and i - begin < max_scan_len and isHexDigitLocal(content[i])) : (i += 1) {
            consumed_any = true;
        }
        if (i < content.len and i - begin < max_scan_len and content[i] == '.') {
            i += 1;
            while (i < content.len and i - begin < max_scan_len and isHexDigitLocal(content[i])) : (i += 1) {
                consumed_any = true;
            }
        }
        if (consumed_any and i < content.len and i - begin < max_scan_len and (content[i] == 'p' or content[i] == 'P')) {
            i += 1;
            if (i < content.len and i - begin < max_scan_len and (content[i] == '+' or content[i] == '-')) i += 1;
            while (i < content.len and i - begin < max_scan_len and isDecDigit(content[i])) : (i += 1) {
                consumed_any = true; // exponent digits don't matter for this flag; token parse decides validity
            }
        }
    } else {
        while (i < content.len and i - begin < max_scan_len and isDecDigit(content[i])) : (i += 1) {
            consumed_any = true;
        }
        if (i < content.len and i - begin < max_scan_len and content[i] == '.') {
            i += 1;
            while (i < content.len and i - begin < max_scan_len and isDecDigit(content[i])) : (i += 1) {
                consumed_any = true;
            }
        }
        if (consumed_any and i < content.len and i - begin < max_scan_len and (content[i] == 'e' or content[i] == 'E')) {
            i += 1;
            if (i < content.len and i - begin < max_scan_len and (content[i] == '+' or content[i] == '-')) i += 1;
            while (i < content.len and i - begin < max_scan_len and isDecDigit(content[i])) : (i += 1) {}
        }
    }

    if (i == begin) return .{ .value = null, .new_pos = begin };
    if (!consumed_any) {
        // Cases like "+", "-", ".", ".e+", "0x" consume their scanned prefix on failure.
        return .{ .value = null, .new_pos = i };
    }

    const token = content[begin..i];
    if (parseLuaNumberToken(token)) |num| {
        // read("n") should not accept inf/nan from overflowed decimal parsing.
        if (num == .number and !std.math.isFinite(num.number)) {
            return .{ .value = null, .new_pos = i };
        }
        return .{ .value = num, .new_pos = i };
    }

    // Invalid numeral after consuming a valid-looking prefix: discard the prefix.
    return .{ .value = null, .new_pos = i };
}

fn tryHandleMultiRead(
    vm: anytype,
    file_table: *TableObject,
    func_reg: u32,
    fmt_arg_count: u32,
    nresults: u32,
    fmt_arg_start: u32,
    fmt_count: u32,
    content: []const u8,
) !bool {
    const pos_key = try vm.gc().allocString(FILE_POS_KEY);
    const pos_val = file_table.get(TValue.fromString(pos_key)) orelse TValue{ .integer = 0 };
    const pos_i64 = pos_val.toInteger() orelse 0;
    const pos: usize = if (pos_i64 < 0) 0 else @intCast(@min(pos_i64, @as(i64, @intCast(content.len))));

    const use_multi_read = blk: {
        if (fmt_count != 1) break :blk true;
        if (fmt_arg_count == 0 or fmt_arg_start >= vm.top) break :blk true;
        const fmt0 = vm.stack[fmt_arg_start].asString() orelse break :blk true;
        const f = fmt0.asSlice();
        break :blk std.mem.eql(u8, f, "n") or std.mem.eql(u8, f, "*n");
    };
    if (!use_multi_read) return false;

    var cur_pos: usize = pos;
    var out_idx: u32 = 0;
    while (out_idx < fmt_count) : (out_idx += 1) {
        const fmt_val: TValue = if (fmt_arg_count > 0 and out_idx < fmt_arg_count and fmt_arg_start + out_idx < vm.top)
            vm.stack[fmt_arg_start + out_idx]
        else
            TValue.fromString(try vm.gc().allocString("*l"));

        if (fmt_val.toInteger()) |count_i| {
            if (count_i < 0) {
                vm.stack[vm.base + func_reg + out_idx] = .nil;
                break;
            }
            const count: usize = @intCast(count_i);
            if (count == 0) {
                if (cur_pos >= content.len) {
                    vm.stack[vm.base + func_reg + out_idx] = .nil;
                } else {
                    vm.stack[vm.base + func_reg + out_idx] = TValue.fromString(try vm.gc().allocString(""));
                }
                continue;
            }
            if (cur_pos >= content.len) {
                vm.stack[vm.base + func_reg + out_idx] = .nil;
                break;
            }
            const end = @min(content.len, cur_pos + count);
            vm.stack[vm.base + func_reg + out_idx] = TValue.fromString(try vm.gc().allocString(content[cur_pos..end]));
            cur_pos = end;
            continue;
        }

        const fmt_obj = fmt_val.asString() orelse return vm.raiseString("invalid format");
        const fmt = fmt_obj.asSlice();

        if (std.mem.eql(u8, fmt, "*a") or std.mem.eql(u8, fmt, "a")) {
            vm.stack[vm.base + func_reg + out_idx] = TValue.fromString(try vm.gc().allocString(content[cur_pos..]));
            cur_pos = content.len;
            continue;
        }

        if (std.mem.eql(u8, fmt, "*l") or std.mem.eql(u8, fmt, "l") or
            std.mem.eql(u8, fmt, "*L") or std.mem.eql(u8, fmt, "L"))
        {
            const keep_nl = std.mem.eql(u8, fmt, "*L") or std.mem.eql(u8, fmt, "L");
            if (cur_pos >= content.len) {
                vm.stack[vm.base + func_reg + out_idx] = .nil;
                break;
            }
            var end = cur_pos;
            while (end < content.len and content[end] != '\n') : (end += 1) {}
            const line_end = if (keep_nl and end < content.len) end + 1 else end;
            vm.stack[vm.base + func_reg + out_idx] = TValue.fromString(try vm.gc().allocString(content[cur_pos..line_end]));
            cur_pos = if (end < content.len) end + 1 else end;
            continue;
        }

        if (std.mem.eql(u8, fmt, "*n") or std.mem.eql(u8, fmt, "n")) {
            const res = readLuaNumberFromContent(content, cur_pos);
            cur_pos = res.new_pos;
            if (res.value) |num| {
                vm.stack[vm.base + func_reg + out_idx] = num;
                continue;
            }
            vm.stack[vm.base + func_reg + out_idx] = .nil;
            break;
        }

        return vm.raiseString("invalid format");
    }

    const clear_upto: u32 = @max(nresults, fmt_count + 1);
    if (clear_upto > fmt_count) {
        var fill = fmt_count;
        while (fill < clear_upto) : (fill += 1) {
            vm.stack[vm.base + func_reg + fill] = .nil;
        }
    }

    try file_table.set(TValue.fromString(pos_key), .{ .integer = @intCast(cur_pos) });
    return true;
}

fn flushBufferedFileTable(vm: anytype, file_table: *TableObject) !void {
    const stdio_key = try vm.gc().allocString(FILE_STDIO_KEY);
    if (file_table.get(TValue.fromString(stdio_key)) != null) return;

    const closed_key = try vm.gc().allocString(FILE_CLOSED_KEY);
    if (file_table.get(TValue.fromString(closed_key))) |closed_val| {
        if (closed_val.toBoolean()) return;
    }

    const mode_key = try vm.gc().allocString(FILE_MODE_KEY);
    const mode_val = file_table.get(TValue.fromString(mode_key)) orelse return;
    const mode_str = mode_val.asString() orelse return;
    const mode = mode_str.asSlice();
    if (mode.len == 0 or (mode[0] != 'w' and mode[0] != 'a')) return;

    const filename_key = try vm.gc().allocString(FILE_FILENAME_KEY);
    const fn_val = file_table.get(TValue.fromString(filename_key)) orelse return;
    const fn_str = fn_val.asString() orelse return;
    const filename = fn_str.asSlice();

    const output_key = try vm.gc().allocString(FILE_OUTPUT_KEY);
    const out_val = file_table.get(TValue.fromString(output_key)) orelse return;
    const out_str = out_val.asString() orelse return;

    const file = std.fs.cwd().createFile(filename, .{}) catch return;
    defer file.close();
    file.writeAll(out_str.asSlice()) catch {};
}

fn createLinesIteratorWrapper(vm: anytype, temp_slot: u32, state_table: *TableObject) !*TableObject {
    const wrapper = try vm.gc().allocTable();
    vm.stack[vm.base + temp_slot] = TValue.fromTable(wrapper);

    const state_key = try vm.gc().allocString("_lines_state");
    try wrapper.set(TValue.fromString(state_key), TValue.fromTable(state_table));
    const done_key = try vm.gc().allocString("_lines_done");
    try wrapper.set(TValue.fromString(done_key), .{ .boolean = false });

    const mt = try vm.gc().allocTable();
    vm.stack[vm.base + temp_slot + 1] = TValue.fromTable(mt);
    const call_key = try vm.gc().allocString("__call");
    const iter_nc = try vm.gc().allocNativeClosure(.{ .id = .io_lines_iterator });
    try mt.set(TValue.fromString(call_key), TValue.fromNativeClosure(iter_nc));
    wrapper.metatable = mt;
    return wrapper;
}
pub fn nativeIoWrite(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    // If a default output file handle exists, delegate to file:write(self, ...)
    const io_key = try vm.gc().allocString("io");
    if (vm.globals().get(TValue.fromString(io_key))) |io_val| {
        if (io_val.asTable()) |io_table| {
            const default_output_key = try vm.gc().allocString(IO_DEFAULT_OUTPUT_KEY);
            if (io_table.get(TValue.fromString(default_output_key))) |out_val| {
                if (out_val.asTable() != null) {
                    vm.reserveSlots(func_reg, nargs + 3);
                    var i: i64 = @intCast(nargs);
                    while (i > 0) : (i -= 1) {
                        const src = func_reg + @as(u32, @intCast(i));
                        const dst = func_reg + @as(u32, @intCast(i)) + 1;
                        vm.stack[vm.base + dst] = vm.stack[vm.base + src];
                    }
                    vm.stack[vm.base + func_reg + 1] = out_val;
                    return nativeFileWrite(vm, func_reg, nargs + 1, nresults);
                }
            }
        }
    }

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

    // io.write returns the current default output file
    if (nresults > 0) {
        if (vm.globals().get(TValue.fromString(io_key))) |io_val| {
            if (io_val.asTable()) |io_table| {
                const default_output_key = try vm.gc().allocString(IO_DEFAULT_OUTPUT_KEY);
                if (io_table.get(TValue.fromString(default_output_key))) |out_val| {
                    vm.stack[vm.base + func_reg] = out_val;
                    return;
                }
            }
        }
        vm.stack[vm.base + func_reg] = .nil;
    }
}

/// io.close([file]) - Closes file or default output file
/// io.close([file]) - Closes a file
/// With file argument: closes the given file
/// Without argument: closes the default output file
/// Returns: true on success, or nil + error message on failure
pub fn nativeIoClose(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    var file_table: *TableObject = undefined;

    if (nargs >= 1) {
        // Close the given file
        const arg = vm.stack[vm.base + func_reg + 1];
        file_table = arg.asTable() orelse {
            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
            return;
        };
    } else {
        // Close default output file
        const io_key = try vm.gc().allocString("io");
        const io_val = vm.globals().get(TValue.fromString(io_key)) orelse {
            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
            return;
        };
        const io_table = io_val.asTable() orelse {
            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
            return;
        };

        const default_output_key = try vm.gc().allocString(IO_DEFAULT_OUTPUT_KEY);
        const output_val = io_table.get(TValue.fromString(default_output_key)) orelse {
            // No default output set, nothing to close
            if (nresults > 0) vm.stack[vm.base + func_reg] = .{ .boolean = true };
            return;
        };
        file_table = output_val.asTable() orelse {
            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
            return;
        };
    }

    // Standard files cannot be closed in Lua
    const stdio_key = try vm.gc().allocString(FILE_STDIO_KEY);
    if (file_table.get(TValue.fromString(stdio_key)) != null) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Check if already closed
    const closed_key = try vm.gc().allocString(FILE_CLOSED_KEY);
    if (file_table.get(TValue.fromString(closed_key))) |closed_val| {
        if (closed_val.toBoolean()) {
            // Already closed
            if (nargs >= 1) {
                return vm.raiseString("closed file");
            }
            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
            if (nresults > 1) {
                const err_str = try vm.gc().allocString("file already closed");
                vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
            }
            return;
        }
    }

    // Check if this is a write/append mode file that needs flushing
    const mode_key = try vm.gc().allocString(FILE_MODE_KEY);
    const filename_key = try vm.gc().allocString(FILE_FILENAME_KEY);
    var write_error: bool = false;

    if (file_table.get(TValue.fromString(mode_key))) |mode_val| {
        if (mode_val.asString()) |mode_str| {
            const mode = mode_str.asSlice();
            if (mode.len > 0 and (mode[0] == 'w' or mode[0] == 'a')) {
                // This is a write/append mode file - flush to disk
                if (file_table.get(TValue.fromString(filename_key))) |fn_val| {
                    if (fn_val.asString()) |fn_str| {
                        const filename = fn_str.asSlice();

                        // Get the output buffer
                        const output_key = try vm.gc().allocString(FILE_OUTPUT_KEY);
                        const content = if (file_table.get(TValue.fromString(output_key))) |v|
                            if (v.asString()) |s| s.asSlice() else ""
                        else
                            "";

                        // Write to file
                        const file = std.fs.cwd().createFile(filename, .{}) catch {
                            write_error = true;
                            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
                            if (nresults > 1) {
                                const err_str = try vm.gc().allocString("cannot write file");
                                vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
                            }
                            try file_table.set(TValue.fromString(closed_key), .{ .boolean = true });
                            return;
                        };
                        defer file.close();

                        file.writeAll(content) catch {
                            write_error = true;
                        };
                    }
                }
            }
        }
    }

    // Mark as closed
    try file_table.set(TValue.fromString(closed_key), .{ .boolean = true });

    // If this is a temp file, delete it
    const tmpfile_key = try vm.gc().allocString(FILE_TMPFILE_KEY);
    if (file_table.get(TValue.fromString(tmpfile_key))) |tmpfile_val| {
        if (tmpfile_val.toBoolean()) {
            if (file_table.get(TValue.fromString(filename_key))) |fn_val| {
                if (fn_val.asString()) |fn_str| {
                    const tmp_filename = fn_str.asSlice();
                    std.fs.cwd().deleteFile(tmp_filename) catch {};
                }
            }
        }
    }

    if (write_error) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        if (nresults > 1) {
            const err_str = try vm.gc().allocString("write error");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
        }
        return;
    }

    // Return true on success
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = .{ .boolean = true };
    }
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

/// io.input([file]) - Sets or gets the default input file
/// With no arguments: returns current default input file
/// With filename string: opens file and sets as default input
/// With file handle: sets as default input
/// Returns: the current default input file
pub fn nativeIoInput(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    // Reserve stack slots for GC safety
    vm.reserveSlots(func_reg, 6);

    // Get the io table from globals to access/store default input
    const io_key = try vm.gc().allocString("io");
    const io_val = vm.globals().get(TValue.fromString(io_key)) orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const io_table = io_val.asTable() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    const default_input_key = try vm.gc().allocString(IO_DEFAULT_INPUT_KEY);

    if (nargs == 0) {
        // Return current default input (or create stdin if not set)
        if (io_table.get(TValue.fromString(default_input_key))) |input_val| {
            if (nresults > 0) vm.stack[vm.base + func_reg] = input_val;
            return;
        }

        // Create stdin handle
        const stdin_handle = try createStdioHandle(vm, func_reg + 1, "stdin");
        try io_table.set(TValue.fromString(default_input_key), TValue.fromTable(stdin_handle));

        // Also set io.stdin
        const stdin_key = try vm.gc().allocString("stdin");
        try io_table.set(TValue.fromString(stdin_key), TValue.fromTable(stdin_handle));

        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.fromTable(stdin_handle);
        return;
    }

    // With argument - set default input
    const arg = vm.stack[vm.base + func_reg + 1];

    // If it's a string, open as filename
    if (arg.asString()) |filename_str| {
        const filename = filename_str.asSlice();

        // Open the file for reading
        const file = std.fs.cwd().openFile(filename, .{}) catch {
            return vm.raiseString("cannot open file");
        };
        defer file.close();

        const content = file.readToEndAlloc(vm.gc().allocator, 10 * 1024 * 1024) catch {
            return vm.raiseString("cannot read file");
        };
        defer vm.gc().allocator.free(content);

        // Create file handle
        const file_table = try vm.gc().allocTable();
        vm.stack[vm.base + func_reg] = TValue.fromTable(file_table);

        const output_key = try vm.gc().allocString(FILE_OUTPUT_KEY);
        const content_str = try vm.gc().allocString(content);
        try file_table.set(TValue.fromString(output_key), TValue.fromString(content_str));

        const closed_key = try vm.gc().allocString(FILE_CLOSED_KEY);
        try file_table.set(TValue.fromString(closed_key), .{ .boolean = false });

        const mode_key = try vm.gc().allocString(FILE_MODE_KEY);
        const mode_str = try vm.gc().allocString("r");
        try file_table.set(TValue.fromString(mode_key), TValue.fromString(mode_str));

        const pos_key = try vm.gc().allocString(FILE_POS_KEY);
        try file_table.set(TValue.fromString(pos_key), .{ .integer = 0 });

        const mt = try createFileMetatable(vm, func_reg + 2);
        file_table.metatable = mt;

        // Set as default input
        try io_table.set(TValue.fromString(default_input_key), TValue.fromTable(file_table));

        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.fromTable(file_table);
        return;
    }

    // If it's a file handle (table), set as default input
    if (arg.asTable()) |file_table| {
        try io_table.set(TValue.fromString(default_input_key), TValue.fromTable(file_table));
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.fromTable(file_table);
        return;
    }

    if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
}

/// Create a stdio handle (stdin, stdout, or stderr)
fn createStdioHandle(vm: anytype, temp_slot: u32, stdio_type: []const u8) !*TableObject {
    const file_table = try vm.gc().allocTable();
    vm.stack[vm.base + temp_slot] = TValue.fromTable(file_table);

    // Mark as stdio
    const stdio_key = try vm.gc().allocString(FILE_STDIO_KEY);
    const stdio_str = try vm.gc().allocString(stdio_type);
    try file_table.set(TValue.fromString(stdio_key), TValue.fromString(stdio_str));

    // Empty content buffer (stdin reads dynamically)
    const output_key = try vm.gc().allocString(FILE_OUTPUT_KEY);
    const empty_str = try vm.gc().allocString("");
    try file_table.set(TValue.fromString(output_key), TValue.fromString(empty_str));

    // Not closed
    const closed_key = try vm.gc().allocString(FILE_CLOSED_KEY);
    try file_table.set(TValue.fromString(closed_key), .{ .boolean = false });

    // Mode
    const mode_key = try vm.gc().allocString(FILE_MODE_KEY);
    const mode_str = try vm.gc().allocString(if (std.mem.eql(u8, stdio_type, "stdin")) "r" else "w");
    try file_table.set(TValue.fromString(mode_key), TValue.fromString(mode_str));

    // Position
    const pos_key = try vm.gc().allocString(FILE_POS_KEY);
    try file_table.set(TValue.fromString(pos_key), .{ .integer = 0 });

    // Create metatable
    const mt = try createFileMetatable(vm, temp_slot + 1);
    file_table.metatable = mt;

    return file_table;
}

/// io.lines([filename, ...]) - Returns an iterator function for reading files line by line
/// Returns iterator function, state table, nil (for generic for)
pub fn nativeIoLines(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    // Reserve stack slots for GC safety
    vm.reserveSlots(func_reg, 5);
    const state_table = try vm.gc().allocTable();
    const content_key = try vm.gc().allocString("_content");
    const pos_key = try vm.gc().allocString("_pos");

    // io.lines() / io.lines(nil, ...) -> iterate current default input
    const use_default_input = nargs == 0 or vm.stack[vm.base + func_reg + 1].isNil();
    const fmt_count: u32 = if (nargs > 0) nargs - 1 else 0;
    const fmt_start: u32 = func_reg + 2;
    if (fmt_count > 250) {
        return vm.raiseString("too many arguments");
    }
    if (use_default_input) {
        const io_key = try vm.gc().allocString("io");
        const io_val = vm.globals().get(TValue.fromString(io_key)) orelse {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        };
        const io_table = io_val.asTable() orelse {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        };

        const default_input_key = try vm.gc().allocString(IO_DEFAULT_INPUT_KEY);
        var file_table: *TableObject = undefined;
        if (io_table.get(TValue.fromString(default_input_key))) |in_val| {
            if (in_val.asTable()) |t| {
                file_table = t;
            } else {
                file_table = try createStdioHandle(vm, func_reg + 3, "stdin");
                try io_table.set(TValue.fromString(default_input_key), TValue.fromTable(file_table));
                const stdin_key = try vm.gc().allocString("stdin");
                try io_table.set(TValue.fromString(stdin_key), TValue.fromTable(file_table));
            }
        } else {
            file_table = try createStdioHandle(vm, func_reg + 3, "stdin");
            try io_table.set(TValue.fromString(default_input_key), TValue.fromTable(file_table));
            const stdin_key = try vm.gc().allocString("stdin");
            try io_table.set(TValue.fromString(stdin_key), TValue.fromTable(file_table));
        }

        const output_key = try vm.gc().allocString(FILE_OUTPUT_KEY);
        const content_val = file_table.get(TValue.fromString(output_key)) orelse TValue.fromString(try vm.gc().allocString(""));
        const content_obj = content_val.asString() orelse try vm.gc().allocString("");
        try state_table.set(TValue.fromString(content_key), TValue.fromString(content_obj));

        const file_pos_key = try vm.gc().allocString(FILE_POS_KEY);
        const file_pos_val = file_table.get(TValue.fromString(file_pos_key)) orelse TValue{ .integer = 0 };
        try state_table.set(TValue.fromString(pos_key), file_pos_val);

        const file_ref_key = try vm.gc().allocString("_file_ref");
        try state_table.set(TValue.fromString(file_ref_key), TValue.fromTable(file_table));
    } else {
        // io.lines(filename, ...)
        const filename_arg = vm.stack[vm.base + func_reg + 1];
        const filename_obj = filename_arg.asString() orelse {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        };
        const filename = filename_obj.asSlice();

        const file = std.fs.cwd().openFile(filename, .{}) catch {
            return vm.raiseString("cannot open file");
        };
        defer file.close();

        const content = file.readToEndAlloc(vm.gc().allocator, 10 * 1024 * 1024) catch {
            return vm.raiseString("cannot read file");
        };
        defer vm.gc().allocator.free(content);

        const content_str = try vm.gc().allocString(content);
        try state_table.set(TValue.fromString(content_key), TValue.fromString(content_str));
        try state_table.set(TValue.fromString(pos_key), .{ .integer = 0 });
    }

    if (fmt_count > 0) {
        const fmts_key = try vm.gc().allocString("_fmts");
        const fmt_count_key = try vm.gc().allocString("_fmt_count");
        const fmts_table = try vm.gc().allocTable();
        try state_table.set(TValue.fromString(fmts_key), TValue.fromTable(fmts_table));
        try state_table.set(TValue.fromString(fmt_count_key), .{ .integer = @intCast(fmt_count) });

        var i: u32 = 0;
        while (i < fmt_count) : (i += 1) {
            const fmt_val = vm.stack[vm.base + fmt_start + i];
            try fmts_table.set(.{ .integer = @as(i64, @intCast(i)) + 1 }, fmt_val);
        }
    }

    const wrapper = try createLinesIteratorWrapper(vm, func_reg + 3, state_table);
    vm.stack[vm.base + func_reg] = TValue.fromTable(wrapper);

    // Compatibility: still return generic-for extras; wrapper ignores them.
    if (nresults > 1) {
        vm.stack[vm.base + func_reg + 1] = TValue.fromTable(state_table);
    }

    // Return nil as initial control variable
    if (nresults > 2) {
        vm.stack[vm.base + func_reg + 2] = .nil;
    }
}

/// Iterator function for io.lines
/// Takes (state_table, _) where state_table has {_content=string, _pos=position}
/// Returns next line (without newline), updates _pos
/// Returns nil when no more lines
pub fn nativeIoLinesIterator(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    var state_table: *TableObject = undefined;
    var wrapper_opt: ?*TableObject = null;
    if (vm.stack[vm.base + func_reg].asTable()) |wrapper| {
        const state_key = try vm.gc().allocString("_lines_state");
        if (wrapper.get(TValue.fromString(state_key))) |wrapped_state| {
            if (wrapped_state.asTable()) |st| {
                const done_key = try vm.gc().allocString("_lines_done");
                if (wrapper.get(TValue.fromString(done_key))) |done_val| {
                    if (done_val.toBoolean()) {
                        return vm.raiseString("file is already closed");
                    }
                }
                wrapper_opt = wrapper;
                state_table = st;
            } else {
                vm.stack[vm.base + func_reg] = .nil;
                return;
            }
        } else {
            // Fall back to generic-for style iterator(state, control).
            if (nargs < 1) {
                vm.stack[vm.base + func_reg] = .nil;
                return;
            }
            const state_arg = vm.stack[vm.base + func_reg + 1];
            state_table = state_arg.asTable() orelse {
                vm.stack[vm.base + func_reg] = .nil;
                return;
            };
        }
    } else {
        if (nargs < 1) {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        }
        const state_arg = vm.stack[vm.base + func_reg + 1];
        state_table = state_arg.asTable() orelse {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        };
    }

    // Get content from state table
    const content_key = try vm.gc().allocString("_content");
    const content_val = state_table.get(TValue.fromString(content_key)) orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const content_obj = content_val.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const content = content_obj.asSlice();

    // Get current position from state table
    const pos_key = try vm.gc().allocString("_pos");
    const pos_val = state_table.get(TValue.fromString(pos_key)) orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const pos_i64 = pos_val.toInteger() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    if (pos_i64 < 0) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }
    const start_pos: usize = @intCast(pos_i64);

    const fmt_count_key = try vm.gc().allocString("_fmt_count");
    const fmts_key = try vm.gc().allocString("_fmts");
    const fmt_count: u32 = if (state_table.get(TValue.fromString(fmt_count_key))) |v|
        @intCast(@max(@as(i64, 0), v.toInteger() orelse 0))
    else
        0;

    if (fmt_count > 0) {
        const fmts_val = state_table.get(TValue.fromString(fmts_key)) orelse {
            vm.stack[vm.base + func_reg] = .nil;
            vm.top = vm.base + func_reg + 1;
            return;
        };
        const fmts_table = fmts_val.asTable() orelse {
            vm.stack[vm.base + func_reg] = .nil;
            vm.top = vm.base + func_reg + 1;
            return;
        };

        var cur_pos = start_pos;
        var out_idx: u32 = 0;
        var written_count: u32 = 0;
        while (out_idx < fmt_count) : (out_idx += 1) {
            const fmt_val = fmts_table.get(.{ .integer = @as(i64, @intCast(out_idx)) + 1 }) orelse .nil;

            if (fmt_val.toInteger()) |count_i| {
                if (count_i < 0) {
                    vm.stack[vm.base + func_reg + out_idx] = .nil;
                    written_count = out_idx + 1;
                    break;
                }
                const count: usize = @intCast(count_i);
                if (count == 0) {
                    if (cur_pos >= content.len) {
                        vm.stack[vm.base + func_reg + out_idx] = .nil;
                    } else {
                        vm.stack[vm.base + func_reg + out_idx] = TValue.fromString(try vm.gc().allocString(""));
                    }
                    written_count = out_idx + 1;
                    continue;
                }
                if (cur_pos >= content.len) {
                    vm.stack[vm.base + func_reg + out_idx] = .nil;
                    written_count = out_idx + 1;
                    break;
                }
                const end = @min(content.len, cur_pos + count);
                vm.stack[vm.base + func_reg + out_idx] = TValue.fromString(try vm.gc().allocString(content[cur_pos..end]));
                cur_pos = end;
                written_count = out_idx + 1;
                continue;
            }

            const fmt_obj = fmt_val.asString() orelse {
                vm.stack[vm.base + func_reg + out_idx] = .nil;
                written_count = out_idx + 1;
                break;
            };
            const fmt = fmt_obj.asSlice();

            if (std.mem.eql(u8, fmt, "*a") or std.mem.eql(u8, fmt, "a")) {
                vm.stack[vm.base + func_reg + out_idx] = TValue.fromString(try vm.gc().allocString(content[cur_pos..]));
                cur_pos = content.len;
                written_count = out_idx + 1;
                continue;
            }

            if (std.mem.eql(u8, fmt, "*l") or std.mem.eql(u8, fmt, "l") or
                std.mem.eql(u8, fmt, "*L") or std.mem.eql(u8, fmt, "L"))
            {
                const keep_nl = std.mem.eql(u8, fmt, "*L") or std.mem.eql(u8, fmt, "L");
                if (cur_pos >= content.len) {
                    vm.stack[vm.base + func_reg + out_idx] = .nil;
                    written_count = out_idx + 1;
                    break;
                }
                var end = cur_pos;
                while (end < content.len and content[end] != '\n') : (end += 1) {}
                const line_end = if (keep_nl and end < content.len) end + 1 else end;
                vm.stack[vm.base + func_reg + out_idx] = TValue.fromString(try vm.gc().allocString(content[cur_pos..line_end]));
                cur_pos = if (end < content.len) end + 1 else end;
                written_count = out_idx + 1;
                continue;
            }

            if (std.mem.eql(u8, fmt, "*n") or std.mem.eql(u8, fmt, "n")) {
                const res = readLuaNumberFromContent(content, cur_pos);
                cur_pos = res.new_pos;
                if (res.value) |num| {
                    vm.stack[vm.base + func_reg + out_idx] = num;
                    written_count = out_idx + 1;
                    continue;
                }
                vm.stack[vm.base + func_reg + out_idx] = .nil;
                written_count = out_idx + 1;
                break;
            }

            vm.stack[vm.base + func_reg + out_idx] = .nil;
            written_count = out_idx + 1;
            break;
        }

        if (written_count < fmt_count) {
            var fill_mid = written_count;
            while (fill_mid < fmt_count) : (fill_mid += 1) {
                vm.stack[vm.base + func_reg + fill_mid] = .nil;
            }
        }

        const clear_upto: u32 = @max(nresults, fmt_count + 1);
        if (clear_upto > fmt_count) {
            var fill = fmt_count;
            while (fill < clear_upto) : (fill += 1) {
                vm.stack[vm.base + func_reg + fill] = .nil;
            }
        }

        try state_table.set(TValue.fromString(pos_key), .{ .integer = @intCast(cur_pos) });
        if (vm.stack[vm.base + func_reg].isNil()) {
            if (wrapper_opt) |wrapper| {
                const done_key = try vm.gc().allocString("_lines_done");
                try wrapper.set(TValue.fromString(done_key), .{ .boolean = true });
            }
        }
        vm.top = vm.base + func_reg + written_count;
        return;
    }

    // Check if we're at or past the end
    if (start_pos >= content.len) {
        if (wrapper_opt) |wrapper| {
            const done_key = try vm.gc().allocString("_lines_done");
            try wrapper.set(TValue.fromString(done_key), .{ .boolean = true });
        }
        vm.stack[vm.base + func_reg] = .nil;
        vm.top = vm.base + func_reg + 1;
        return;
    }

    // Find next newline
    var end_pos: usize = start_pos;
    while (end_pos < content.len and content[end_pos] != '\n') : (end_pos += 1) {}

    // Extract the line (without newline)
    const line = content[start_pos..end_pos];
    const line_str = try vm.gc().allocString(line);
    vm.stack[vm.base + func_reg] = TValue.fromString(line_str);

    // Update position (skip past the newline if present)
    const new_pos: i64 = @intCast(if (end_pos < content.len) end_pos + 1 else end_pos);
    try state_table.set(TValue.fromString(pos_key), .{ .integer = new_pos });
    vm.top = vm.base + func_reg + 1;
}

/// io.open(filename [, mode]) - Opens a file in specified mode
/// Returns file handle or nil, errmsg on error
/// Supports: "r" (read), "w" (write), "a" (append), and variants with "+" and "b"
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

    // Parse mode - first char determines primary mode
    if (!isValidOpenMode(mode)) {
        return vm.raiseString("invalid mode");
    }

    const primary_mode = mode[0];

    // Handle read mode
    if (primary_mode == 'r') {
        // Open and read the file
        const file = std.fs.cwd().openFile(filename, .{}) catch {
            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
            if (nresults > 1) {
                const err_str = try vm.gc().allocString("cannot open file");
                vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
            }
            if (nresults > 2) vm.stack[vm.base + func_reg + 2] = .{ .integer = 1 };
            return;
        };
        defer file.close();

        // Read entire file content
        const content = file.readToEndAlloc(vm.gc().allocator, 10 * 1024 * 1024) catch {
            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
            if (nresults > 1) {
                const err_str = try vm.gc().allocString("cannot read file");
                vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
            }
            if (nresults > 2) vm.stack[vm.base + func_reg + 2] = .{ .integer = 1 };
            return;
        };
        defer vm.gc().allocator.free(content);

        // Create file handle table
        const file_table = try vm.gc().allocTable();
        vm.stack[vm.base + func_reg] = TValue.fromTable(file_table);

        // Store file content
        const output_key = try vm.gc().allocString(FILE_OUTPUT_KEY);
        vm.stack[vm.base + func_reg + 1] = TValue.fromString(output_key);
        const output_str = try vm.gc().allocString(content);
        try file_table.set(TValue.fromString(output_key), TValue.fromString(output_str));

        // Store closed flag
        const closed_key = try vm.gc().allocString(FILE_CLOSED_KEY);
        try file_table.set(TValue.fromString(closed_key), .{ .boolean = false });

        // Store exit code (0 for regular files)
        const exitcode_key = try vm.gc().allocString(FILE_EXITCODE_KEY);
        try file_table.set(TValue.fromString(exitcode_key), .{ .integer = 0 });

        // Store mode
        const mode_key = try vm.gc().allocString(FILE_MODE_KEY);
        const mode_str = try vm.gc().allocString(mode);
        try file_table.set(TValue.fromString(mode_key), TValue.fromString(mode_str));

        // Store read position (0 for beginning)
        const pos_key = try vm.gc().allocString(FILE_POS_KEY);
        try file_table.set(TValue.fromString(pos_key), .{ .integer = 0 });

        // Create metatable with file methods
        const mt = try createFileMetatable(vm, func_reg + 2);
        file_table.metatable = mt;

        if (nresults == 0) {
            vm.stack[vm.base + func_reg] = .nil;
        }
        return;
    }

    // Handle write mode ("w" - truncate or create)
    if (primary_mode == 'w') {
        // Validate path and apply truncation semantics at open time
        const probe_file = std.fs.cwd().createFile(filename, .{}) catch {
            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
            if (nresults > 1) {
                const err_str = try vm.gc().allocString("cannot open file");
                vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
            }
            if (nresults > 2) vm.stack[vm.base + func_reg + 2] = .{ .integer = 1 };
            return;
        };
        probe_file.close();

        // Create file handle table with empty buffer
        const file_table = try vm.gc().allocTable();
        vm.stack[vm.base + func_reg] = TValue.fromTable(file_table);

        // Store empty output buffer
        const output_key = try vm.gc().allocString(FILE_OUTPUT_KEY);
        const empty_str = try vm.gc().allocString("");
        try file_table.set(TValue.fromString(output_key), TValue.fromString(empty_str));

        // Store filename for writing on close
        const filename_key = try vm.gc().allocString(FILE_FILENAME_KEY);
        const filename_str = try vm.gc().allocString(filename);
        try file_table.set(TValue.fromString(filename_key), TValue.fromString(filename_str));

        // Store mode
        const mode_key = try vm.gc().allocString(FILE_MODE_KEY);
        const mode_str = try vm.gc().allocString(mode);
        try file_table.set(TValue.fromString(mode_key), TValue.fromString(mode_str));

        // Store closed flag
        const closed_key = try vm.gc().allocString(FILE_CLOSED_KEY);
        try file_table.set(TValue.fromString(closed_key), .{ .boolean = false });

        // Store exit code (0 for regular files)
        const exitcode_key = try vm.gc().allocString(FILE_EXITCODE_KEY);
        try file_table.set(TValue.fromString(exitcode_key), .{ .integer = 0 });

        // Store position (0 for write mode)
        const pos_key = try vm.gc().allocString(FILE_POS_KEY);
        try file_table.set(TValue.fromString(pos_key), .{ .integer = 0 });

        // Create metatable with file methods
        const mt = try createFileMetatable(vm, func_reg + 2);
        file_table.metatable = mt;

        if (nresults == 0) {
            vm.stack[vm.base + func_reg] = .nil;
        }
        return;
    }

    // Handle append mode ("a" - append or create)
    if (primary_mode == 'a') {
        // Try to read existing content
        var initial_content: []const u8 = "";
        var owned_content: ?[]u8 = null;
        defer if (owned_content) |c| vm.gc().allocator.free(c);

        if (std.fs.cwd().openFile(filename, .{})) |file| {
            defer file.close();
            if (file.readToEndAlloc(vm.gc().allocator, 10 * 1024 * 1024)) |content| {
                owned_content = content;
                initial_content = content;
            } else |_| {}
        } else |_| {}

        // Create file handle table
        const file_table = try vm.gc().allocTable();
        vm.stack[vm.base + func_reg] = TValue.fromTable(file_table);

        // Store initial content (existing file content or empty)
        const output_key = try vm.gc().allocString(FILE_OUTPUT_KEY);
        const content_str = try vm.gc().allocString(initial_content);
        try file_table.set(TValue.fromString(output_key), TValue.fromString(content_str));

        // Store filename for writing on close
        const filename_key = try vm.gc().allocString(FILE_FILENAME_KEY);
        const filename_str = try vm.gc().allocString(filename);
        try file_table.set(TValue.fromString(filename_key), TValue.fromString(filename_str));

        // Store mode
        const mode_key = try vm.gc().allocString(FILE_MODE_KEY);
        const mode_str = try vm.gc().allocString(mode);
        try file_table.set(TValue.fromString(mode_key), TValue.fromString(mode_str));

        // Store closed flag
        const closed_key = try vm.gc().allocString(FILE_CLOSED_KEY);
        try file_table.set(TValue.fromString(closed_key), .{ .boolean = false });

        // Store exit code (0 for regular files)
        const exitcode_key = try vm.gc().allocString(FILE_EXITCODE_KEY);
        try file_table.set(TValue.fromString(exitcode_key), .{ .integer = 0 });

        // Store position (0 for append mode)
        const pos_key = try vm.gc().allocString(FILE_POS_KEY);
        try file_table.set(TValue.fromString(pos_key), .{ .integer = 0 });

        // Create metatable with file methods
        const mt = try createFileMetatable(vm, func_reg + 2);
        file_table.metatable = mt;

        if (nresults == 0) {
            vm.stack[vm.base + func_reg] = .nil;
        }
        return;
    }

    // Unknown mode
    return vm.raiseString("invalid mode");
}

/// io.output([file]) - Sets default output file when called with a file name or handle
/// io.output([file]) - Sets or gets the default output file
/// With no arguments: returns current default output file
/// With filename string: opens file for writing and sets as default output
/// With file handle: sets as default output
/// Returns: the current default output file
pub fn nativeIoOutput(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    // Reserve stack slots for GC safety
    vm.reserveSlots(func_reg, 6);

    // Get the io table from globals to access/store default output
    const io_key = try vm.gc().allocString("io");
    const io_val = vm.globals().get(TValue.fromString(io_key)) orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const io_table = io_val.asTable() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    const default_output_key = try vm.gc().allocString(IO_DEFAULT_OUTPUT_KEY);

    if (nargs == 0) {
        // Return current default output (or create stdout if not set)
        if (io_table.get(TValue.fromString(default_output_key))) |output_val| {
            if (nresults > 0) vm.stack[vm.base + func_reg] = output_val;
            return;
        }

        // Create stdout handle
        const stdout_handle = try createStdioHandle(vm, func_reg + 1, "stdout");
        try io_table.set(TValue.fromString(default_output_key), TValue.fromTable(stdout_handle));

        // Also set io.stdout
        const stdout_key = try vm.gc().allocString("stdout");
        try io_table.set(TValue.fromString(stdout_key), TValue.fromTable(stdout_handle));

        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.fromTable(stdout_handle);
        return;
    }

    // With argument - set default output
    const arg = vm.stack[vm.base + func_reg + 1];

    // If it's a string, open as filename for writing
    if (arg.asString()) |filename_str| {
        const filename = filename_str.asSlice();
        if (io_table.get(TValue.fromString(default_output_key))) |old_val| {
            if (old_val.asTable()) |old_file| {
                try flushBufferedFileTable(vm, old_file);
            }
        }

        // Create file handle for writing (similar to io.open with "w" mode)
        const file_table = try vm.gc().allocTable();
        vm.stack[vm.base + func_reg] = TValue.fromTable(file_table);

        // Store empty output buffer
        const output_key = try vm.gc().allocString(FILE_OUTPUT_KEY);
        const empty_str = try vm.gc().allocString("");
        try file_table.set(TValue.fromString(output_key), TValue.fromString(empty_str));

        // Store filename for writing on close
        const filename_key = try vm.gc().allocString(FILE_FILENAME_KEY);
        const filename_str_alloc = try vm.gc().allocString(filename);
        try file_table.set(TValue.fromString(filename_key), TValue.fromString(filename_str_alloc));

        // Store mode
        const mode_key = try vm.gc().allocString(FILE_MODE_KEY);
        const mode_str = try vm.gc().allocString("w");
        try file_table.set(TValue.fromString(mode_key), TValue.fromString(mode_str));

        // Store closed flag
        const closed_key = try vm.gc().allocString(FILE_CLOSED_KEY);
        try file_table.set(TValue.fromString(closed_key), .{ .boolean = false });

        // Store position
        const pos_key = try vm.gc().allocString(FILE_POS_KEY);
        try file_table.set(TValue.fromString(pos_key), .{ .integer = 0 });

        // Create metatable with file methods
        const mt = try createFileMetatable(vm, func_reg + 2);
        file_table.metatable = mt;

        // Set as default output
        try io_table.set(TValue.fromString(default_output_key), TValue.fromTable(file_table));

        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.fromTable(file_table);
        return;
    }

    // If it's a file handle (table), set as default output
    if (arg.asTable()) |file_table| {
        if (io_table.get(TValue.fromString(default_output_key))) |old_val| {
            if (old_val.asTable()) |old_file| {
                if (old_file != file_table) {
                    try flushBufferedFileTable(vm, old_file);
                }
            }
        }
        try io_table.set(TValue.fromString(default_output_key), TValue.fromTable(file_table));
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.fromTable(file_table);
        return;
    }

    if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
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
    const result = runCommand(vm.gc().allocator, cmd) catch {
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

    const file_table = try vm.gc().allocTable();
    vm.stack[vm.base + func_reg] = TValue.fromTable(file_table);

    // output_key must be protected before allocating output_str
    const output_key = try vm.gc().allocString(FILE_OUTPUT_KEY);
    vm.stack[vm.base + func_reg + 1] = TValue.fromString(output_key);
    const output_str = try vm.gc().allocString(result.output);
    try file_table.set(TValue.fromString(output_key), TValue.fromString(output_str));
    vm.gc().allocator.free(result.output);

    // Store exit code
    const exitcode_key = try vm.gc().allocString(FILE_EXITCODE_KEY);
    try file_table.set(TValue.fromString(exitcode_key), .{ .integer = result.exit_code });

    // Store closed flag
    const closed_key = try vm.gc().allocString(FILE_CLOSED_KEY);
    try file_table.set(TValue.fromString(closed_key), .{ .boolean = false });

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

    const mt = try vm.gc().allocTable();
    vm.stack[vm.base + temp_slot] = TValue.fromTable(mt);

    const index_table = try vm.gc().allocTable();
    vm.stack[vm.base + temp_slot + 1] = TValue.fromTable(index_table);

    // Both tables protected, safe to set __index
    try mt.set(TValue.fromString(vm.gc().mm_keys.get(.index)), TValue.fromTable(index_table));
    try mt.set(TValue.fromString(vm.gc().mm_keys.get(.name)), TValue.fromString(try vm.gc().allocString("FILE*")));

    // Native closure must be protected before allocating its key string
    const read_nc = try vm.gc().allocNativeClosure(.{ .id = .file_read });
    vm.stack[vm.base + temp_slot + 2] = TValue.fromNativeClosure(read_nc);
    const read_key = try vm.gc().allocString("read");
    try index_table.set(TValue.fromString(read_key), TValue.fromNativeClosure(read_nc));

    // Reuse scratch slot for close method
    const close_nc = try vm.gc().allocNativeClosure(.{ .id = .file_close });
    vm.stack[vm.base + temp_slot + 2] = TValue.fromNativeClosure(close_nc);
    const close_key = try vm.gc().allocString("close");
    try index_table.set(TValue.fromString(close_key), TValue.fromNativeClosure(close_nc));
    try mt.set(TValue.fromString(vm.gc().mm_keys.get(.close)), TValue.fromNativeClosure(close_nc));

    // Reuse scratch slot for write method
    const write_nc = try vm.gc().allocNativeClosure(.{ .id = .file_write });
    vm.stack[vm.base + temp_slot + 2] = TValue.fromNativeClosure(write_nc);
    const write_key = try vm.gc().allocString("write");
    try index_table.set(TValue.fromString(write_key), TValue.fromNativeClosure(write_nc));

    // Reuse scratch slot for lines method
    const lines_nc = try vm.gc().allocNativeClosure(.{ .id = .file_lines });
    vm.stack[vm.base + temp_slot + 2] = TValue.fromNativeClosure(lines_nc);
    const lines_key = try vm.gc().allocString("lines");
    try index_table.set(TValue.fromString(lines_key), TValue.fromNativeClosure(lines_nc));

    // Reuse scratch slot for flush method
    const flush_nc = try vm.gc().allocNativeClosure(.{ .id = .file_flush });
    vm.stack[vm.base + temp_slot + 2] = TValue.fromNativeClosure(flush_nc);
    const flush_key = try vm.gc().allocString("flush");
    try index_table.set(TValue.fromString(flush_key), TValue.fromNativeClosure(flush_nc));

    // Reuse scratch slot for seek method
    const seek_nc = try vm.gc().allocNativeClosure(.{ .id = .file_seek });
    vm.stack[vm.base + temp_slot + 2] = TValue.fromNativeClosure(seek_nc);
    const seek_key = try vm.gc().allocString("seek");
    try index_table.set(TValue.fromString(seek_key), TValue.fromNativeClosure(seek_nc));

    // Reuse scratch slot for setvbuf method
    const setvbuf_nc = try vm.gc().allocNativeClosure(.{ .id = .file_setvbuf });
    vm.stack[vm.base + temp_slot + 2] = TValue.fromNativeClosure(setvbuf_nc);
    const setvbuf_key = try vm.gc().allocString("setvbuf");
    try index_table.set(TValue.fromString(setvbuf_key), TValue.fromNativeClosure(setvbuf_nc));

    return mt;
}

/// io.read(...) - Reads from default input file according to given formats
/// io.read(...) - Reads from default input file according to given formats
/// Supports: "*a" (read all), "*l" (read line), "*L" (line with newline), "*n" (read number)
/// Default format is "*l" (read line without newline)
pub fn nativeIoRead(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    // Get default input file
    const io_key = try vm.gc().allocString("io");
    const io_val = vm.globals().get(TValue.fromString(io_key)) orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const io_table = io_val.asTable() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    const default_input_key = try vm.gc().allocString(IO_DEFAULT_INPUT_KEY);
    var file_table: *TableObject = undefined;

    if (io_table.get(TValue.fromString(default_input_key))) |input_val| {
        file_table = input_val.asTable() orelse {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        };
    } else {
        // Create stdin handle if not set
        file_table = try createStdioHandle(vm, func_reg + 1, "stdin");
        try io_table.set(TValue.fromString(default_input_key), TValue.fromTable(file_table));

        const stdin_key = try vm.gc().allocString("stdin");
        try io_table.set(TValue.fromString(stdin_key), TValue.fromTable(file_table));
    }

    // Check if closed
    const closed_key = try vm.gc().allocString(FILE_CLOSED_KEY);
    if (file_table.get(TValue.fromString(closed_key))) |closed_val| {
        if (closed_val.toBoolean()) {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        }
    }

    // Get format argument (default to "*l")
    var format: []const u8 = "*l";
    if (nargs >= 1) {
        const fmt_arg = vm.stack[vm.base + func_reg + 1];
        if (fmt_arg.asString()) |s| {
            format = s.asSlice();
        }
    }

    // Get stored content
    const output_key = try vm.gc().allocString(FILE_OUTPUT_KEY);
    const content_val = file_table.get(TValue.fromString(output_key)) orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const content_str = content_val.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const content = content_str.asSlice();

    // Get current position
    const pos_key = try vm.gc().allocString(FILE_POS_KEY);
    const pos_val = file_table.get(TValue.fromString(pos_key)) orelse TValue{ .integer = 0 };
    const pos_i64 = pos_val.toInteger() orelse 0;
    const pos: usize = if (pos_i64 < 0) 0 else @intCast(@min(pos_i64, @as(i64, @intCast(content.len))));

    if (try tryHandleMultiRead(
        vm,
        file_table,
        func_reg,
        nargs,
        nresults,
        vm.base + func_reg + 1,
        if (nargs > 0) nargs else 1,
        content,
    )) {
        return;
    }

    // Handle different formats
    if (std.mem.eql(u8, format, "*a") or std.mem.eql(u8, format, "a")) {
        // Read all from current position
        const remaining = content[pos..];
        if (remaining.len == 0) {
            const empty_str = try vm.gc().allocString("");
            vm.stack[vm.base + func_reg] = TValue.fromString(empty_str);
        } else {
            const result_str = try vm.gc().allocString(remaining);
            vm.stack[vm.base + func_reg] = TValue.fromString(result_str);
        }
        try file_table.set(TValue.fromString(pos_key), .{ .integer = @intCast(content.len) });
    } else if (std.mem.eql(u8, format, "*l") or std.mem.eql(u8, format, "l")) {
        // Read line (without newline)
        if (pos >= content.len) {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        }

        var end: usize = pos;
        while (end < content.len and content[end] != '\n') : (end += 1) {}

        const line = content[pos..end];
        const line_str = try vm.gc().allocString(line);
        vm.stack[vm.base + func_reg] = TValue.fromString(line_str);

        const new_pos: i64 = @intCast(if (end < content.len) end + 1 else end);
        try file_table.set(TValue.fromString(pos_key), .{ .integer = new_pos });
    } else if (std.mem.eql(u8, format, "*L") or std.mem.eql(u8, format, "L")) {
        // Read line (with newline)
        if (pos >= content.len) {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        }

        var end: usize = pos;
        while (end < content.len and content[end] != '\n') : (end += 1) {}
        if (end < content.len) end += 1;

        const line = content[pos..end];
        const line_str = try vm.gc().allocString(line);
        vm.stack[vm.base + func_reg] = TValue.fromString(line_str);

        try file_table.set(TValue.fromString(pos_key), .{ .integer = @intCast(end) });
    } else {
        return vm.raiseString("invalid format");
    }
}

/// io.tmpfile() - Returns a handle for a temporary file
/// io.tmpfile() - Returns a handle for a temporary file
/// File is opened in update mode ("w+b") and automatically removed when closed
/// Returns: file handle, or nil + error message on failure
///
/// NOTE: Current implementation uses in-memory buffering with a temp filename.
/// When C API integration is implemented, consider using libc's tmpfile()
/// for proper anonymous temp file handling.
pub fn nativeIoTmpfile(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;
    if (nresults == 0) return;

    // Reserve stack slots for GC safety
    vm.reserveSlots(func_reg, 5);

    // Generate unique temp filename
    const timestamp: u64 = @intCast(std.time.nanoTimestamp());
    var prng = std.Random.DefaultPrng.init(timestamp);
    const random = prng.random();
    const rand_val = random.int(u32);

    var name_buf: [64]u8 = undefined;
    const filename = std.fmt.bufPrint(&name_buf, "/tmp/lua_tmp_{x}_{x}", .{ timestamp, rand_val }) catch {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    // Create file handle table (similar to io.open with "w+" mode)
    const file_table = try vm.gc().allocTable();
    vm.stack[vm.base + func_reg] = TValue.fromTable(file_table);

    // Store empty output buffer
    const output_key = try vm.gc().allocString(FILE_OUTPUT_KEY);
    const empty_str = try vm.gc().allocString("");
    try file_table.set(TValue.fromString(output_key), TValue.fromString(empty_str));

    // Store filename
    const filename_key = try vm.gc().allocString(FILE_FILENAME_KEY);
    const filename_str = try vm.gc().allocString(filename);
    try file_table.set(TValue.fromString(filename_key), TValue.fromString(filename_str));

    // Store mode ("w+b" for update binary mode)
    const mode_key = try vm.gc().allocString(FILE_MODE_KEY);
    const mode_str = try vm.gc().allocString("w+b");
    try file_table.set(TValue.fromString(mode_key), TValue.fromString(mode_str));

    // Store closed flag
    const closed_key = try vm.gc().allocString(FILE_CLOSED_KEY);
    try file_table.set(TValue.fromString(closed_key), .{ .boolean = false });

    // Store exit code (0 for regular files)
    const exitcode_key = try vm.gc().allocString(FILE_EXITCODE_KEY);
    try file_table.set(TValue.fromString(exitcode_key), .{ .integer = 0 });

    // Store position
    const pos_key = try vm.gc().allocString(FILE_POS_KEY);
    try file_table.set(TValue.fromString(pos_key), .{ .integer = 0 });

    // Mark as temp file (will be deleted on close)
    const tmpfile_key = try vm.gc().allocString(FILE_TMPFILE_KEY);
    try file_table.set(TValue.fromString(tmpfile_key), .{ .boolean = true });

    // Create metatable with file methods
    const mt = try createFileMetatable(vm, func_reg + 2);
    file_table.metatable = mt;
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
    const closed_key = try vm.gc().allocString(FILE_CLOSED_KEY);
    if (file_table.get(TValue.fromString(closed_key))) |closed_val| {
        if (closed_val.toBoolean()) {
            const result = try vm.gc().allocString("closed file");
            vm.stack[vm.base + func_reg] = TValue.fromString(result);
        } else {
            const result = try vm.gc().allocString("file");
            vm.stack[vm.base + func_reg] = TValue.fromString(result);
        }
    } else {
        vm.stack[vm.base + func_reg] = .nil;
    }
}

// File handle methods (these would be implemented when userdata/file handles are added)

/// file:close() - Closes file handle
/// For write/append modes, flushes buffer to disk
/// For popen handles, returns: true/nil, "exit", exit_code
pub fn nativeFileClose(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 1) {
        return vm.raiseString("got no value");
    }

    // Get the file handle table (self)
    const self_arg = vm.stack[vm.base + func_reg + 1];
    const file_table = self_arg.asTable() orelse {
        return vm.raiseString("got no value");
    };

    // Standard files cannot be closed in Lua
    const stdio_key = try vm.gc().allocString(FILE_STDIO_KEY);
    if (file_table.get(TValue.fromString(stdio_key)) != null) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Check if already closed
    const closed_key = try vm.gc().allocString(FILE_CLOSED_KEY);
    if (file_table.get(TValue.fromString(closed_key))) |closed_val| {
        if (closed_val.toBoolean()) {
            // Already closed
            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
            return;
        }
    }

    // Check if this is a write/append mode file
    const mode_key = try vm.gc().allocString(FILE_MODE_KEY);
    const filename_key = try vm.gc().allocString(FILE_FILENAME_KEY);

    var write_error: bool = false;

    if (file_table.get(TValue.fromString(mode_key))) |mode_val| {
        if (mode_val.asString()) |mode_str| {
            const mode = mode_str.asSlice();
            if (mode.len > 0 and (mode[0] == 'w' or mode[0] == 'a')) {
                // This is a write/append mode file - flush to disk
                if (file_table.get(TValue.fromString(filename_key))) |fn_val| {
                    if (fn_val.asString()) |fn_str| {
                        const filename = fn_str.asSlice();

                        // Get the output buffer
                        const output_key = try vm.gc().allocString(FILE_OUTPUT_KEY);
                        const content = if (file_table.get(TValue.fromString(output_key))) |v|
                            if (v.asString()) |s| s.asSlice() else ""
                        else
                            "";

                        // Write to file
                        const file = std.fs.cwd().createFile(filename, .{}) catch {
                            write_error = true;
                            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
                            if (nresults > 1) {
                                const err_str = try vm.gc().allocString("cannot write file");
                                vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
                            }
                            // Still mark as closed
                            try file_table.set(TValue.fromString(closed_key), .{ .boolean = true });
                            return;
                        };
                        defer file.close();

                        file.writeAll(content) catch {
                            write_error = true;
                        };
                    }
                }
            }
        }
    }

    // Mark as closed
    try file_table.set(TValue.fromString(closed_key), .{ .boolean = true });

    // If this is a temp file, delete it
    const tmpfile_key = try vm.gc().allocString(FILE_TMPFILE_KEY);
    if (file_table.get(TValue.fromString(tmpfile_key))) |tmpfile_val| {
        if (tmpfile_val.toBoolean()) {
            if (file_table.get(TValue.fromString(filename_key))) |fn_val| {
                if (fn_val.asString()) |fn_str| {
                    const tmp_filename = fn_str.asSlice();
                    std.fs.cwd().deleteFile(tmp_filename) catch {};
                }
            }
        }
    }

    if (write_error) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        if (nresults > 1) {
            const err_str = try vm.gc().allocString("write error");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
        }
        return;
    }

    // Get exit code
    const exitcode_key = try vm.gc().allocString(FILE_EXITCODE_KEY);
    const exit_code = if (file_table.get(TValue.fromString(exitcode_key))) |v| v.toInteger() orelse 0 else 0;

    // Return: ok, "exit", code
    // ok is true if exit_code == 0, nil otherwise
    const ok: TValue = if (exit_code == 0) .{ .boolean = true } else .nil;

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = ok;
    }
    if (nresults > 1) {
        const exit_str = try vm.gc().allocString("exit");
        vm.stack[vm.base + func_reg + 1] = TValue.fromString(exit_str);
    }
    if (nresults > 2) {
        vm.stack[vm.base + func_reg + 2] = .{ .integer = exit_code };
    }
}

/// file:flush() - Saves any written data to file
/// file:flush() - Saves any written data to file
/// For write/append mode files, writes buffer to disk
/// Returns true on success, nil + error message on failure
pub fn nativeFileFlush(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
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
    const closed_key = try vm.gc().allocString(FILE_CLOSED_KEY);
    if (file_table.get(TValue.fromString(closed_key))) |closed_val| {
        if (closed_val.toBoolean()) {
            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
            if (nresults > 1) {
                const err_str = try vm.gc().allocString("file is closed");
                vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
            }
            return;
        }
    }

    // Check if this is a write/append mode file
    const mode_key = try vm.gc().allocString(FILE_MODE_KEY);
    const filename_key = try vm.gc().allocString(FILE_FILENAME_KEY);

    if (file_table.get(TValue.fromString(mode_key))) |mode_val| {
        if (mode_val.asString()) |mode_str| {
            const mode = mode_str.asSlice();
            if (mode.len > 0 and (mode[0] == 'w' or mode[0] == 'a')) {
                // This is a write/append mode file - flush to disk
                if (file_table.get(TValue.fromString(filename_key))) |fn_val| {
                    if (fn_val.asString()) |fn_str| {
                        const filename = fn_str.asSlice();

                        // Get the output buffer
                        const output_key = try vm.gc().allocString(FILE_OUTPUT_KEY);
                        const content = if (file_table.get(TValue.fromString(output_key))) |v|
                            if (v.asString()) |s| s.asSlice() else ""
                        else
                            "";

                        // Write to file
                        const file = std.fs.cwd().createFile(filename, .{}) catch {
                            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
                            if (nresults > 1) {
                                const err_str = try vm.gc().allocString("cannot write file");
                                vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
                            }
                            return;
                        };
                        defer file.close();

                        file.writeAll(content) catch {
                            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
                            if (nresults > 1) {
                                const err_str = try vm.gc().allocString("write error");
                                vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
                            }
                            return;
                        };

                        // Success
                        if (nresults > 0) {
                            vm.stack[vm.base + func_reg] = .{ .boolean = true };
                        }
                        return;
                    }
                }
            }
        }
    }

    // For read mode or files without filename, flush is a no-op but returns true
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = .{ .boolean = true };
    }
}

/// file:lines(...) - Returns iterator for reading file line by line
/// Returns iterator function, state table, nil (for generic for)
pub fn nativeFileLines(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    if (nargs < 1) {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Get the file handle table (self)
    const self_arg = vm.stack[vm.base + func_reg + 1];
    const file_table = self_arg.asTable() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    // Check if closed
    const closed_key = try vm.gc().allocString(FILE_CLOSED_KEY);
    if (file_table.get(TValue.fromString(closed_key))) |closed_val| {
        if (closed_val.toBoolean()) {
            vm.stack[vm.base + func_reg] = .nil;
            return;
        }
    }

    // Get content from file handle's _output field
    const output_key = try vm.gc().allocString(FILE_OUTPUT_KEY);
    const content_val = file_table.get(TValue.fromString(output_key)) orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const content_obj = content_val.asString() orelse {
        vm.stack[vm.base + func_reg] = .nil;
        return;
    };

    // Reserve stack slots for GC safety
    vm.reserveSlots(func_reg, 5);

    // Create state table with content and position
    // Reuse the same format as io.lines so we can use the same iterator
    const state_table = try vm.gc().allocTable();
    vm.stack[vm.base + func_reg + 1] = TValue.fromTable(state_table);

    const content_key = try vm.gc().allocString("_content");
    try state_table.set(TValue.fromString(content_key), TValue.fromString(content_obj));

    const pos_key = try vm.gc().allocString("_pos");
    try state_table.set(TValue.fromString(pos_key), .{ .integer = 0 });

    const wrapper = try createLinesIteratorWrapper(vm, func_reg + 3, state_table);
    vm.stack[vm.base + func_reg] = TValue.fromTable(wrapper);

    // Compatibility: still return generic-for extras; wrapper ignores them.
    if (nresults > 1) {
        vm.stack[vm.base + func_reg + 1] = TValue.fromTable(state_table);
    }

    // Return nil as initial control variable
    if (nresults > 2) {
        vm.stack[vm.base + func_reg + 2] = .nil;
    }
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
    const closed_key = try vm.gc().allocString(FILE_CLOSED_KEY);
    if (file_table.get(TValue.fromString(closed_key))) |closed_val| {
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

    // Get stored output (full content)
    const output_key = try vm.gc().allocString(FILE_OUTPUT_KEY);
    const output_val = file_table.get(TValue.fromString(output_key)) orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const output_str = output_val.asString() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    const content = output_str.asSlice();

    // Get current position
    const pos_key = try vm.gc().allocString(FILE_POS_KEY);
    const pos_val = file_table.get(TValue.fromString(pos_key)) orelse TValue{ .integer = 0 };
    const pos_i64 = pos_val.toInteger() orelse 0;
    const pos: usize = if (pos_i64 < 0) 0 else @intCast(@min(pos_i64, @as(i64, @intCast(content.len))));

    if (try tryHandleMultiRead(
        vm,
        file_table,
        func_reg,
        if (nargs > 1) nargs - 1 else 0,
        nresults,
        vm.base + func_reg + 2,
        if (nargs > 1) nargs - 1 else 1,
        content,
    )) {
        return;
    }

    // Handle different formats
    if (std.mem.eql(u8, format, "*a") or std.mem.eql(u8, format, "a")) {
        // Read all from current position
        const remaining = content[pos..];
        if (remaining.len == 0) {
            // Return empty string at EOF (Lua behavior)
            const empty_str = try vm.gc().allocString("");
            if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.fromString(empty_str);
        } else {
            const result_str = try vm.gc().allocString(remaining);
            if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.fromString(result_str);
        }
        // Update position to end
        try file_table.set(TValue.fromString(pos_key), .{ .integer = @intCast(content.len) });
    } else if (std.mem.eql(u8, format, "*l") or std.mem.eql(u8, format, "l")) {
        // Read line (without newline)
        if (pos >= content.len) {
            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
            return;
        }

        // Find newline from current position
        var end: usize = pos;
        while (end < content.len and content[end] != '\n') : (end += 1) {}

        const line = content[pos..end];
        const line_str = try vm.gc().allocString(line);
        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = TValue.fromString(line_str);
        }

        // Update position (skip past newline if present)
        const new_pos: i64 = @intCast(if (end < content.len) end + 1 else end);
        try file_table.set(TValue.fromString(pos_key), .{ .integer = new_pos });
    } else if (std.mem.eql(u8, format, "*L") or std.mem.eql(u8, format, "L")) {
        // Read line (with newline)
        if (pos >= content.len) {
            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
            return;
        }

        // Find newline from current position
        var end: usize = pos;
        while (end < content.len and content[end] != '\n') : (end += 1) {}
        if (end < content.len) end += 1; // Include newline

        const line = content[pos..end];
        const line_str = try vm.gc().allocString(line);
        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = TValue.fromString(line_str);
        }

        // Update position
        try file_table.set(TValue.fromString(pos_key), .{ .integer = @intCast(end) });
    } else if (std.mem.eql(u8, format, "*n") or std.mem.eql(u8, format, "n")) {
        const res = readLuaNumberFromContent(content, pos);
        if (nresults > 0) vm.stack[vm.base + func_reg] = res.value orelse .nil;
        try file_table.set(TValue.fromString(pos_key), .{ .integer = @intCast(res.new_pos) });
    } else {
        return vm.raiseString("invalid format");
    }
}

/// file:seek([whence [, offset]]) - Sets and gets file position
/// whence: "set" (from beginning), "cur" (from current), "end" (from end)
/// offset: number (default 0)
/// Returns: new position from beginning of file
pub fn nativeFileSeek(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
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

    // Standard input is not seekable
    const stdio_key = try vm.gc().allocString(FILE_STDIO_KEY);
    if (file_table.get(TValue.fromString(stdio_key))) |stdio_val| {
        if (stdio_val.asString()) |stdio_str| {
            if (std.mem.eql(u8, stdio_str.asSlice(), "stdin")) {
                if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
                if (nresults > 1) {
                    const err_str = try vm.gc().allocString("not seekable");
                    vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
                }
                if (nresults > 2) vm.stack[vm.base + func_reg + 2] = .{ .integer = 1 };
                return;
            }
        }
    }

    // Check if closed
    const closed_key = try vm.gc().allocString(FILE_CLOSED_KEY);
    if (file_table.get(TValue.fromString(closed_key))) |closed_val| {
        if (closed_val.toBoolean()) {
            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
            return;
        }
    }

    // Get content length
    const output_key = try vm.gc().allocString(FILE_OUTPUT_KEY);
    const content_len: i64 = if (file_table.get(TValue.fromString(output_key))) |v|
        if (v.asString()) |s| @intCast(s.asSlice().len) else 0
    else
        0;

    // Get current position
    const pos_key = try vm.gc().allocString(FILE_POS_KEY);
    const current_pos: i64 = if (file_table.get(TValue.fromString(pos_key))) |v| v.toInteger() orelse 0 else 0;

    // Get whence argument (default "cur")
    var whence: []const u8 = "cur";
    if (nargs > 1) {
        const whence_arg = vm.stack[vm.base + func_reg + 2];
        if (whence_arg.asString()) |s| {
            whence = s.asSlice();
        }
    }

    // Get offset argument (default 0)
    var offset: i64 = 0;
    if (nargs > 2) {
        const offset_arg = vm.stack[vm.base + func_reg + 3];
        offset = offset_arg.toInteger() orelse 0;
    }

    // Calculate new position based on whence
    var new_pos: i64 = undefined;
    if (std.mem.eql(u8, whence, "set")) {
        new_pos = offset;
    } else if (std.mem.eql(u8, whence, "cur")) {
        new_pos = current_pos + offset;
    } else if (std.mem.eql(u8, whence, "end")) {
        new_pos = content_len + offset;
    } else {
        // Invalid whence
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    }

    // Clamp to valid range
    if (new_pos < 0) new_pos = 0;
    if (new_pos > content_len) new_pos = content_len;

    // Update position
    try file_table.set(TValue.fromString(pos_key), .{ .integer = new_pos });

    // Return new position
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = .{ .integer = new_pos };
    }
}

/// file:setvbuf(mode [, size]) - Sets buffering mode for file
/// file:setvbuf(mode [, size]) - Sets buffering mode for file
/// mode: "no" (no buffering), "full" (full buffering), "line" (line buffering)
/// size: buffer size (optional, ignored in this implementation)
/// Returns: true on success, nil + error on failure
///
/// NOTE: Current implementation uses in-memory buffering, so this is a no-op
/// that only validates arguments. When C API integration is implemented,
/// consider using libc's setvbuf() for real buffering control.
pub fn nativeFileSetvbuf(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nargs < 2) {
        // Need at least self and mode
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
    const closed_key = try vm.gc().allocString(FILE_CLOSED_KEY);
    if (file_table.get(TValue.fromString(closed_key))) |closed_val| {
        if (closed_val.toBoolean()) {
            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
            if (nresults > 1) {
                const err_str = try vm.gc().allocString("file is closed");
                vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
            }
            return;
        }
    }

    // Get mode argument
    const mode_arg = vm.stack[vm.base + func_reg + 2];
    const mode_str = mode_arg.asString() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        if (nresults > 1) {
            const err_str = try vm.gc().allocString("bad argument #1 (string expected)");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
        }
        return;
    };
    const mode = mode_str.asSlice();

    // Validate mode
    if (!std.mem.eql(u8, mode, "no") and
        !std.mem.eql(u8, mode, "full") and
        !std.mem.eql(u8, mode, "line"))
    {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        if (nresults > 1) {
            const err_str = try vm.gc().allocString("bad argument #1 (invalid mode)");
            vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
        }
        return;
    }

    // In our memory-buffered implementation, buffering mode doesn't affect behavior
    // but we accept it for compatibility and return success
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = .{ .boolean = true };
    }
}

/// file:write(...) - Writes values to file
/// Appends string representations to the file's output buffer
pub fn nativeFileWrite(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
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
    const closed_key = try vm.gc().allocString(FILE_CLOSED_KEY);
    if (file_table.get(TValue.fromString(closed_key))) |closed_val| {
        if (closed_val.toBoolean()) {
            if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
            return;
        }
    }

    // Check write permission from file mode. Read-only handles must return
    // (nil, errmsg, errcode) instead of succeeding.
    const mode_key = try vm.gc().allocString(FILE_MODE_KEY);
    if (file_table.get(TValue.fromString(mode_key))) |mode_val| {
        if (mode_val.asString()) |mode_str| {
            const mode = mode_str.asSlice();
            const can_write = mode.len > 0 and
                (mode[0] == 'w' or mode[0] == 'a' or std.mem.indexOfScalar(u8, mode, '+') != null);
            if (!can_write) {
                if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
                if (nresults > 1) {
                    const err_str = try vm.gc().allocString("file is not writable");
                    vm.stack[vm.base + func_reg + 1] = TValue.fromString(err_str);
                }
                if (nresults > 2) vm.stack[vm.base + func_reg + 2] = .{ .integer = 1 };
                return;
            }
        }
    }

    // Get current output buffer
    const output_key = try vm.gc().allocString(FILE_OUTPUT_KEY);
    const current_output = if (file_table.get(TValue.fromString(output_key))) |v|
        if (v.asString()) |s| s.asSlice() else ""
    else
        "";

    // Get current position (writes happen at current position, not always append)
    const pos_key = try vm.gc().allocString(FILE_POS_KEY);
    var current_pos: usize = 0;
    if (file_table.get(TValue.fromString(pos_key))) |v| {
        const pos_i = v.toInteger() orelse 0;
        if (pos_i > 0) current_pos = @intCast(@min(@as(i64, @intCast(current_output.len)), pos_i));
    }

    // Build write payload (concatenated arguments excluding self)
    var write_buf = std.ArrayList(u8).initCapacity(vm.gc().allocator, 256) catch {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    defer write_buf.deinit(vm.gc().allocator);
    // Build resulting file content after overwrite at current_pos
    defer vm.top = vm.top;

    const string = @import("string.zig");
    const saved_top = vm.top;

    var i: u32 = 1; // Start from 1 (skip self)
    while (i < nargs) : (i += 1) {
        const tmp_reg = vm.top;
        vm.top += 2;

        const arg_reg = func_reg + 1 + i;
        vm.stack[vm.base + tmp_reg + 1] = vm.stack[vm.base + arg_reg];
        try string.nativeToString(vm, tmp_reg, 1, 1);

        const result = vm.stack[vm.base + tmp_reg];
        if (result.asString()) |str_val| {
            try write_buf.appendSlice(vm.gc().allocator, str_val.asSlice());
        }

        vm.top -= 2;
    }

    vm.top = saved_top;

    const end_pos = current_pos + write_buf.items.len;
    const final_len = @max(current_output.len, end_pos);
    var new_content = std.ArrayList(u8).initCapacity(vm.gc().allocator, final_len) catch {
        if (nresults > 0) vm.stack[vm.base + func_reg] = .nil;
        return;
    };
    defer new_content.deinit(vm.gc().allocator);
    try new_content.appendSlice(vm.gc().allocator, current_output[0..current_pos]);
    try new_content.appendSlice(vm.gc().allocator, write_buf.items);
    if (end_pos < current_output.len) {
        try new_content.appendSlice(vm.gc().allocator, current_output[end_pos..]);
    }

    // Store new content
    const new_str = try vm.gc().allocString(new_content.items);
    try file_table.set(TValue.fromString(output_key), TValue.fromString(new_str));
    try file_table.set(TValue.fromString(pos_key), .{ .integer = @intCast(end_pos) });

    // Return the file handle for chaining
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = self_arg;
    }
}
