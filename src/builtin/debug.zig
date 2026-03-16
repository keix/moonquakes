const std = @import("std");
const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");
const ClosureObject = object.ClosureObject;
const NativeClosureObject = object.NativeClosureObject;
const metamethod = @import("../vm/metamethod.zig");
const pipeline = @import("../compiler/pipeline.zig");
const call = @import("../vm/call.zig");
const VM = @import("../vm/vm.zig").VM;
const CallInfo = @import("../vm/execution.zig").CallInfo;

fn inferEnvUpvalueIndex(closure: *ClosureObject) ?usize {
    for (closure.proto.upvalues, 0..) |upv, i| {
        if (upv.name) |name| {
            if (std.mem.eql(u8, name, "_ENV")) return i;
        }
    }
    for (closure.proto.code) |inst| {
        const op = inst.getOpCode();
        if (op == .GETTABUP or op == .SETTABUP) {
            const idx = inst.getB();
            if (idx < closure.proto.upvalues.len) return idx;
        }
    }
    return null;
}

fn isUpvalueReferenced(closure: *ClosureObject, idx: usize) bool {
    for (closure.proto.code) |inst| {
        const op = inst.getOpCode();
        switch (op) {
            .GETUPVAL, .SETUPVAL => if (inst.getB() == idx) return true,
            .GETTABUP => if (inst.getB() == idx) return true,
            .SETTABUP => if (inst.getA() == idx) return true,
            else => {},
        }
    }
    return false;
}

fn isHiddenSyntheticUpvalue(closure: *ClosureObject, idx: usize) bool {
    // Closure slots beyond proto descriptors are internal artifacts.
    if (idx >= closure.proto.upvalues.len) return true;

    if (closure.proto.upvalues[idx].name) |name| {
        // Hide implicit _ENV when bytecode does not reference it.
        if (std.mem.eql(u8, name, "_ENV") and !isUpvalueReferenced(closure, idx)) return true;
        return false;
    }

    return !isUpvalueReferenced(closure, idx);
}

const UpvalueKey = struct {
    instack: bool,
    idx: u8,
    is_env: bool,
};

fn keyFor(closure: *ClosureObject, idx: usize, env_idx: ?usize) UpvalueKey {
    if (env_idx != null and env_idx.? == idx) {
        return .{ .instack = false, .idx = 0, .is_env = true };
    }
    const d = if (idx < closure.proto.upvalues.len) closure.proto.upvalues[idx] else closure.proto.upvalues[0];
    return .{ .instack = d.instack, .idx = d.idx, .is_env = false };
}

fn sameKey(a: UpvalueKey, b: UpvalueKey) bool {
    return a.instack == b.instack and a.idx == b.idx and a.is_env == b.is_env;
}

fn upvalueFirstRefPos(closure: *ClosureObject, idx: usize) usize {
    for (closure.proto.code, 0..) |inst, pc| {
        const op = inst.getOpCode();
        switch (op) {
            .GETUPVAL, .SETUPVAL => if (inst.getB() == idx) return pc,
            .GETTABUP => if (inst.getB() == idx) return pc,
            .SETTABUP => if (inst.getA() == idx) return pc,
            else => {},
        }
    }
    return std.math.maxInt(usize);
}

fn collectVisibleUpvalueReps(closure: *ClosureObject, reps: *[256]usize) usize {
    const env_idx = inferEnvUpvalueIndex(closure);

    var count: usize = 0;
    var env_rep: ?usize = null;
    var i: usize = 0;
    while (i < closure.upvalues.len and count < reps.len) : (i += 1) {
        if (isHiddenSyntheticUpvalue(closure, i)) continue;

        const k = keyFor(closure, i, env_idx);
        var exists = false;
        var j: usize = 0;
        while (j < count) : (j += 1) {
            if (sameKey(k, keyFor(closure, reps[j], env_idx))) {
                exists = true;
                break;
            }
        }
        if (exists) continue;

        if (k.is_env) {
            env_rep = i;
            continue;
        }

        const has_name = i < closure.proto.upvalues.len and closure.proto.upvalues[i].name != null;
        if (has_name) {
            // For named upvalues, follow first reference order in bytecode.
            const pos_i = upvalueFirstRefPos(closure, i);
            var insert_at = count;
            var p: usize = 0;
            while (p < count) : (p += 1) {
                const rp = reps[p];
                if (rp < closure.proto.upvalues.len and closure.proto.upvalues[rp].name != null) {
                    const pos_p = upvalueFirstRefPos(closure, rp);
                    if (pos_i < pos_p or (pos_i == pos_p and i < rp)) {
                        insert_at = p;
                        break;
                    }
                }
            }
            if (insert_at < count) {
                var s = count;
                while (s > insert_at) : (s -= 1) {
                    reps[s] = reps[s - 1];
                }
            }
            reps[insert_at] = i;
            count += 1;
        } else {
            // For unnamed/synthetic descriptors (common after dump/undump),
            // keep a stable lexical-like order by descriptor idx.
            var insert_at = count;
            var p: usize = 0;
            while (p < count) : (p += 1) {
                const kp = keyFor(closure, reps[p], env_idx);
                if (k.idx < kp.idx) {
                    insert_at = p;
                    break;
                }
            }
            if (insert_at < count) {
                var s = count;
                while (s > insert_at) : (s -= 1) {
                    reps[s] = reps[s - 1];
                }
            }
            reps[insert_at] = i;
            count += 1;
        }
    }

    if (env_rep) |e| {
        if (count < reps.len) {
            reps[count] = e;
            count += 1;
        }
    }

    return count;
}

fn debugMapUpvalueIndex(closure: *ClosureObject, lua_index: i64) ?usize {
    if (lua_index < 1) return null;
    var visible: [256]usize = undefined;
    const visible_len = collectVisibleUpvalueReps(closure, &visible);
    if (visible_len == 0) return null;

    const visible_idx: usize = @intCast(lua_index - 1);
    if (visible_idx >= visible_len) return null;
    return visible[visible_idx];
}

fn collectReferencedUpvaluesInCodeOrder(closure: *ClosureObject, refs: *[256]usize) usize {
    var count: usize = 0;
    for (closure.proto.code) |inst| {
        const op = inst.getOpCode();
        const idx_opt: ?usize = switch (op) {
            .GETUPVAL, .SETUPVAL => inst.getB(),
            .GETTABUP => inst.getB(),
            .SETTABUP => inst.getA(),
            else => null,
        };
        if (idx_opt) |idx| {
            if (idx >= closure.upvalues.len) continue;
            if (isHiddenSyntheticUpvalue(closure, idx)) continue;
            var exists = false;
            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (refs[i] == idx) {
                    exists = true;
                    break;
                }
            }
            if (!exists and count < refs.len) {
                refs[count] = idx;
                count += 1;
            }
        }
    }
    return count;
}

fn debugMapUpvalueIndexByRefOrder(closure: *ClosureObject, lua_index: i64) ?usize {
    if (lua_index < 1) return null;
    var refs: [256]usize = undefined;
    const n = collectReferencedUpvaluesInCodeOrder(closure, &refs);
    const i: usize = @intCast(lua_index - 1);
    if (i >= n) return null;
    return refs[i];
}

fn syntheticUpvalueName(idx: usize, buf: *[32]u8) []const u8 {
    if (idx < 26) {
        buf[0] = @as(u8, 'a') + @as(u8, @intCast(idx));
        return buf[0..1];
    }
    return std.fmt.bufPrint(buf, "up{d}", .{idx + 1}) catch "(no name)";
}

fn getCallInfoAtLevel(vm: *VM, level: i64) ?*const CallInfo {
    if (level < 1) return null;
    var ci_opt = vm.ci;
    var remaining: i64 = level - 1;
    while (remaining > 0) : (remaining -= 1) {
        ci_opt = if (ci_opt) |ci| ci.previous else null;
    }
    return ci_opt;
}

fn inferFieldNameInTable(tbl: *object.TableObject, target: *ClosureObject) ?[]const u8 {
    var it = tbl.hash_part.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        const clo = value.asClosure() orelse continue;
        if (clo != target) continue;
        const key_str = key.asString() orelse continue;
        return key_str.asSlice();
    }
    return null;
}

fn inferFieldNameAtLevel(vm: *VM, level: i64, target: *ClosureObject) ?[]const u8 {
    const caller = getCallInfoAtLevel(vm, level + 1) orelse return null;

    var r: usize = 0;
    while (r < caller.func.maxstacksize) : (r += 1) {
        const stack_pos = caller.base + @as(u32, @intCast(r));
        if (stack_pos >= vm.stack.len) break;
        const tbl = vm.stack[stack_pos].asTable() orelse continue;
        if (inferFieldNameInTable(tbl, target)) |name| return name;
    }

    if (caller.closure) |caller_closure| {
        for (caller_closure.upvalues, 0..) |upv, i| {
            if (i < caller_closure.proto.upvalues.len) {
                if (caller_closure.proto.upvalues[i].name) |upname| {
                    if (std.mem.eql(u8, upname, "_ENV")) continue;
                }
            }
            const tbl = upv.location.*.asTable() orelse continue;
            if (inferFieldNameInTable(tbl, target)) |name| return name;
        }
    }

    return null;
}

fn isKeyword(ident: []const u8) bool {
    return std.mem.eql(u8, ident, "and") or
        std.mem.eql(u8, ident, "break") or
        std.mem.eql(u8, ident, "do") or
        std.mem.eql(u8, ident, "else") or
        std.mem.eql(u8, ident, "elseif") or
        std.mem.eql(u8, ident, "end") or
        std.mem.eql(u8, ident, "false") or
        std.mem.eql(u8, ident, "for") or
        std.mem.eql(u8, ident, "function") or
        std.mem.eql(u8, ident, "goto") or
        std.mem.eql(u8, ident, "if") or
        std.mem.eql(u8, ident, "in") or
        std.mem.eql(u8, ident, "local") or
        std.mem.eql(u8, ident, "nil") or
        std.mem.eql(u8, ident, "not") or
        std.mem.eql(u8, ident, "or") or
        std.mem.eql(u8, ident, "repeat") or
        std.mem.eql(u8, ident, "return") or
        std.mem.eql(u8, ident, "then") or
        std.mem.eql(u8, ident, "true") or
        std.mem.eql(u8, ident, "until") or
        std.mem.eql(u8, ident, "while");
}

fn currentLineForCallInfo(ci: *const CallInfo) i64 {
    const proto = ci.func;
    if (proto.code.len == 0 or proto.lineinfo.len == 0) return -1;

    const pc_ptr = @intFromPtr(ci.pc);
    const code_ptr = @intFromPtr(proto.code.ptr);
    if (pc_ptr < code_ptr) return -1;

    const pc_off_bytes = pc_ptr - code_ptr;
    const pc_off_instr: usize = @intCast(pc_off_bytes / @sizeOf(@TypeOf(proto.code[0])));
    const idx = if (pc_off_instr > 0) pc_off_instr - 1 else pc_off_instr;
    const safe_idx = @min(idx, proto.lineinfo.len - 1);
    return @intCast(proto.lineinfo[safe_idx]);
}

fn currentPcIndexForCallInfo(ci: *const CallInfo) i32 {
    const proto = ci.func;
    if (proto.code.len == 0) return -1;

    const pc_ptr = @intFromPtr(ci.pc);
    const code_ptr = @intFromPtr(proto.code.ptr);
    if (pc_ptr < code_ptr) return -1;

    const pc_off_bytes = pc_ptr - code_ptr;
    const pc_off_instr: usize = @intCast(pc_off_bytes / @sizeOf(@TypeOf(proto.code[0])));
    const idx: usize = if (pc_off_instr > 0) pc_off_instr - 1 else pc_off_instr;
    return @intCast(idx);
}

const InferredCallName = struct {
    name: []const u8,
    namewhat: []const u8,
};

fn inferNameFromCallLine(call_line: []const u8) ?InferredCallName {
    var last_field: ?[]const u8 = null;
    var last_field_kind: []const u8 = "field";
    var i: usize = 0;
    while (i < call_line.len) : (i += 1) {
        const sep = call_line[i];
        if (sep != '.' and sep != ':') continue;
        var j = i + 1;
        while (j < call_line.len and (call_line[j] == ' ' or call_line[j] == '\t')) : (j += 1) {}
        if (j >= call_line.len or !isIdentStart(call_line[j])) continue;
        var k = j + 1;
        while (k < call_line.len and isIdentPart(call_line[k])) : (k += 1) {}
        var h = k;
        while (h < call_line.len and (call_line[h] == ' ' or call_line[h] == '\t')) : (h += 1) {}
        if (h < call_line.len and call_line[h] == '(') {
            last_field = call_line[j..k];
            last_field_kind = if (sep == ':') "method" else "field";
        }
        i = k;
    }

    if (last_field) |name| {
        return .{ .name = name, .namewhat = last_field_kind };
    }

    var last_plain: ?[]const u8 = null;
    i = 0;
    while (i < call_line.len) {
        if (!isIdentStart(call_line[i])) {
            i += 1;
            continue;
        }
        const start = i;
        i += 1;
        while (i < call_line.len and isIdentPart(call_line[i])) : (i += 1) {}
        const ident = call_line[start..i];
        if (isKeyword(ident)) continue;

        var h = i;
        while (h < call_line.len and (call_line[h] == ' ' or call_line[h] == '\t')) : (h += 1) {}
        if (h >= call_line.len or call_line[h] != '(') continue;

        var p = start;
        while (p > 0) {
            const c = call_line[p - 1];
            if (c == ' ' or c == '\t') {
                p -= 1;
                continue;
            }
            if (c == '.' or c == ':') break;
            last_plain = ident;
            break;
        } else {
            last_plain = ident;
        }
    }

    if (last_plain) |name| {
        return .{ .name = name, .namewhat = "local" };
    }

    return null;
}

fn inferNameFromCallerSource(vm: *VM, level: i64, storage: *[96]u8) ?InferredCallName {
    const caller = getCallInfoAtLevel(vm, level + 1) orelse return null;
    const source = caller.func.source;
    if (!(source.len > 1 and source[0] == '@')) return null;

    const line_no = currentLineForCallInfo(caller);
    if (line_no <= 0) return null;

    const path = source[1..];
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    const content = file.readToEndAlloc(vm.gc().allocator, 256 * 1024) catch return null;
    defer vm.gc().allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var n: i64 = 1;
    var recent: [6][]const u8 = [_][]const u8{""} ** 6;
    var recent_len: usize = 0;
    while (lines.next()) |ln| : (n += 1) {
        recent[recent_len % recent.len] = ln;
        recent_len += 1;
        if (n >= line_no) break;
    }

    const lookback = @min(recent_len, recent.len);
    var back: usize = 0;
    while (back < lookback) : (back += 1) {
        const idx = (recent_len - 1 - back) % recent.len;
        const ln = recent[idx];
        if (inferNameFromCallLine(ln)) |info| {
            if (info.name.len > 0 and info.name.len <= storage.len) {
                @memcpy(storage[0..info.name.len], info.name);
                return .{ .name = storage[0..info.name.len], .namewhat = info.namewhat };
            }
        }
    }

    return null;
}

fn callerBindsNameToClosure(vm: *VM, level: i64, target: *ClosureObject, name: []const u8) bool {
    const caller = getCallInfoAtLevel(vm, level + 1) orelse return false;

    var r: usize = 0;
    while (r < caller.func.local_reg_names.len) : (r += 1) {
        const local_name = caller.func.local_reg_names[r] orelse continue;
        if (!std.mem.eql(u8, local_name, name)) continue;
        const stack_pos = caller.base + @as(u32, @intCast(r));
        if (stack_pos >= vm.stack.len) continue;
        const clo = vm.stack[stack_pos].asClosure() orelse continue;
        if (clo == target) return true;
    }
    return false;
}

fn isConsistentLevelName(vm: *VM, level: i64, target: *ClosureObject, name: []const u8, namewhat: []const u8) bool {
    if (std.mem.eql(u8, namewhat, "local")) {
        return callerBindsNameToClosure(vm, level, target, name);
    }
    if (std.mem.eql(u8, namewhat, "global")) {
        const key_obj = vm.gc().allocString(name) catch return false;
        if (vm.globals().get(TValue.fromString(key_obj))) |val| {
            if (val.asClosure()) |clo| return clo == target;
        }
        return false;
    }
    if (std.mem.eql(u8, namewhat, "field") or std.mem.eql(u8, namewhat, "method")) {
        return if (inferFieldNameAtLevel(vm, level, target)) |n|
            std.mem.eql(u8, n, name)
        else
            false;
    }
    return true;
}

/// Lua 5.4 Debug Library
/// Corresponds to Lua manual chapter "The Debug Library"
/// Reference: https://www.lua.org/manual/5.4/manual.html#6.10
///
/// ## v0.1.0 Limitations
///
/// ProtoObject lacks debug metadata, limiting several functions:
///
/// | Feature                | Status      | Workaround                    |
/// |------------------------|-------------|-------------------------------|
/// | Variable names         | Placeholder | Returns "(local N)"           |
/// | Source filename        | Unavailable | Returns "?"                   |
/// | Line numbers           | Unavailable | Returns 0 or -1               |
/// | PC-to-line mapping     | Unavailable | traceback shows [Lua function]|
/// | Hook invocation        | Stored only | sethook saves but VM ignores  |
///
/// ## Required for Full Support (v0.2.0)
///
/// ProtoObject needs these fields:
/// ```
/// source: ?[]const u8,      // "@filename" or "=stdin"
/// linedefined: u32,         // function definition start line
/// lastlinedefined: u32,     // function definition end line
/// lineinfo: []const u8,     // PC to line number mapping
/// locvars: []const LocVar,  // local variable debug info
/// ```
///
/// VM execution loop needs hook dispatch at:
/// - Function call (mask & 0x01)
/// - Function return (mask & 0x02)
/// - Line change (mask & 0x04)
/// - Instruction count (hook_count)
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
    const stderr_file = std.fs.File.stderr();
    var stderr_writer = stderr_file.writer(&.{});
    const stderr = &stderr_writer.interface;

    var buf: [32768]u8 = undefined;

    while (true) {
        // Print prompt
        stderr_file.writeAll("lua_debug> ") catch return;

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
        const compile_result = vm.rt.compile_ctx.compile(trimmed, .{});
        switch (compile_result) {
            .err => |e| {
                defer e.deinit(vm.gc().allocator);
                stderr.print("syntax error: {s}\n", .{e.message}) catch {};
                continue;
            },
            .ok => {},
        }
        const raw_proto = compile_result.ok;
        defer pipeline.freeRawProto(vm.gc().allocator, raw_proto);

        // Materialize and execute
        vm.gc().inhibitGC();
        const proto = pipeline.materialize(&raw_proto, vm.gc(), vm.gc().allocator) catch {
            vm.gc().allowGC();
            stderr.writeAll("error: failed to materialize chunk\n") catch {};
            continue;
        };

        const closure = vm.gc().allocClosure(proto) catch {
            vm.gc().allowGC();
            stderr.writeAll("error: failed to create closure\n") catch {};
            continue;
        };
        vm.gc().allowGC();

        // Execute the chunk using call.callValue (same pattern as dofile)
        const func_val = TValue.fromClosure(closure);
        const result = call.callValue(vm, func_val, &[_]TValue{}) catch {
            stderr.writeAll("error: runtime error\n") catch {};
            continue;
        };

        // Print non-nil result
        if (!result.isNil()) {
            printValue(stderr, result) catch {};
            stderr.writeAll("\n") catch {};
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
                .thread => try writer.print("thread: 0x{x}", .{@intFromPtr(obj)}),
                .file => {
                    const file_obj: *object.FileObject = @fieldParentPtr("header", obj);
                    if (file_obj.closed) {
                        try writer.writeAll("file (closed)");
                    } else {
                        try writer.print("file (0x{x})", .{@intFromPtr(obj)});
                    }
                },
            }
        },
    }
}

/// debug.gethook([thread]) - Returns current hook settings
/// Returns: hook function, mask string, count
pub fn nativeDebugGethook(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    var target_vm: *VM = vm;
    if (nargs >= 1) {
        if (vm.stack[vm.base + func_reg + 1].asThread()) |thread| {
            target_vm = @as(*VM, @ptrCast(@alignCast(thread.vm)));
        }
    }
    const want_all = (nresults == 0);

    // Return hook function (or nil)
    if (nresults > 0 or want_all) {
        vm.stack[vm.base + func_reg] = target_vm.hook_func_value;
    }

    // Return mask string
    if (nresults > 1 or want_all) {
        var mask_buf: [4]u8 = undefined;
        var pos: usize = 0;
        if (target_vm.hook_mask & 1 != 0) {
            mask_buf[pos] = 'c';
            pos += 1;
        }
        if (target_vm.hook_mask & 2 != 0) {
            mask_buf[pos] = 'r';
            pos += 1;
        }
        if (target_vm.hook_mask & 4 != 0) {
            mask_buf[pos] = 'l';
            pos += 1;
        }
        vm.stack[vm.base + func_reg + 1] = TValue.fromString(try vm.gc().allocString(mask_buf[0..pos]));
    }

    // Return count
    if (nresults > 2 or want_all) {
        vm.stack[vm.base + func_reg + 2] = .{ .integer = @intCast(target_vm.hook_count) };
    }
    if (want_all) {
        vm.top = vm.base + func_reg + 3;
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
///
/// v0.1.0 limitations:
/// - name/namewhat: not available (requires bytecode analysis)
/// - source/short_src: returns "?" (ProtoObject lacks source field)
/// - linedefined/lastlinedefined: returns 0
/// - currentline: returns -1 (no PC-to-line mapping)
pub fn nativeDebugGetinfo(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    if (nresults == 0) return;

    var target_vm: *VM = vm;
    var arg_off: u32 = 0;
    if (nargs >= 1) {
        if (vm.stack[vm.base + func_reg + 1].asThread()) |thread| {
            target_vm = @as(*VM, @ptrCast(@alignCast(thread.vm)));
            arg_off = 1;
        }
    }

    // Parse first argument (f)
    if (nargs < 1 + arg_off) {
        vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }

    const f_arg = vm.stack[vm.base + func_reg + 1 + arg_off];

    // Parse what argument (optional, default to "flnStu")
    var want_name = true;
    var want_source = true;
    var want_line = true;
    var want_tailcall = true;
    var want_upvalue = true;
    var want_func = true;
    var want_activelines = false;
    var want_transfer = false;

    if (nargs >= 2 + arg_off) {
        const what_arg = vm.stack[vm.base + func_reg + 2 + arg_off];
        if (what_arg.asString()) |what_str| {
            want_name = false;
            want_source = false;
            want_line = false;
            want_tailcall = false;
            want_upvalue = false;
            want_func = false;
            want_activelines = false;
            want_transfer = false;
            for (what_str.asSlice()) |c| {
                switch (c) {
                    'n' => want_name = true,
                    'S' => want_source = true,
                    'l' => want_line = true,
                    't' => want_tailcall = true,
                    'u' => want_upvalue = true,
                    'f' => want_func = true,
                    'L' => want_activelines = true,
                    'r' => want_transfer = true,
                    else => {},
                }
            }
            for (what_str.asSlice()) |c| {
                switch (c) {
                    'n', 'S', 'l', 't', 'u', 'f', 'L', 'r' => {},
                    else => return vm.raiseString("invalid option"),
                }
            }
        }
    }

    // Determine target closure
    var target_closure: ?*ClosureObject = null;
    var target_native: ?*NativeClosureObject = null;
    var current_line: i64 = -1;
    var func_name: ?[]const u8 = null;
    var func_namewhat: ?[]const u8 = null;
    var inferred_name_storage: [96]u8 = undefined;
    var level_arg: ?i64 = null;
    var is_tailcall: bool = false;
    var is_main_chunk: bool = false;

    if (f_arg.toInteger()) |level| {
        level_arg = level;
        // f is a stack level
        // Level 0 = getinfo itself (current native call frame)
        // Level 1 = caller of getinfo
        // etc.

        if (level < 0) {
            vm.stack[vm.base + func_reg] = TValue.nil;
            return;
        }

        // Level 0 is getinfo itself - which is native, so we return C info
        if (level == 0) {
            const result_table = try vm.gc().allocTable();
            if (want_source) {
                const what_key = try vm.gc().allocString("what");
                try result_table.set(TValue.fromString(what_key), TValue.fromString(try vm.gc().allocString("C")));
            }
            vm.stack[vm.base + func_reg] = TValue.fromTable(result_table);
            return;
        }

        const frame_info = target_vm.debugGetFrameInfoAtLevel(level) orelse {
            vm.stack[vm.base + func_reg] = TValue.nil;
            return;
        };
        target_closure = frame_info.closure;
        current_line = frame_info.current_line;
        is_tailcall = frame_info.istailcall;
        is_main_chunk = frame_info.is_main;
        if (frame_info.debug_name) |n| func_name = n;
        if (frame_info.debug_namewhat) |nw| func_namewhat = nw;
        if (func_name != null and func_namewhat != null and target_closure != null and level_arg != null and !(vm.in_hook and vm.hook_name_override != null)) {
            if (!isConsistentLevelName(vm, level_arg.?, target_closure.?, func_name.?, func_namewhat.?)) {
                func_name = null;
                func_namewhat = null;
            }
        }

        // Try to get function name from the caller's call site
        // This is complex - would require analyzing the calling code's bytecode
        // to find the name from GETFIELD/GETTABUP instructions.
        // For now, we leave func_name as null.
    } else if (f_arg.asClosure()) |closure| {
        // f is a function
        target_closure = closure;
    } else if (f_arg.asNativeClosure()) |nc| {
        target_native = nc;
    } else {
        vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }

    if (want_name and level_arg != null and level_arg.? == 1 and target_closure != null and vm.hook_func != null and target_closure.? == vm.hook_func.? and vm.in_hook) {
        func_namewhat = "hook";
    }

    if (want_name and level_arg != null and level_arg.? >= 2) {
        if (vm.hook_name_override) |override| {
            func_name = override;
            func_namewhat = "global";
        }
    }

    // Best-effort name inference: find a global binding that points to the
    // target closure (e.g. "function F() ... end" -> name "F").
    if (want_name and func_name == null and target_closure != null and level_arg != null and level_arg.? >= 1) {
        if (vm.debugInferFunctionNameAtLevel(level_arg.?, target_closure.?)) |n| {
            func_name = n;
            func_namewhat = "local";
        } else if (inferFieldNameAtLevel(vm, level_arg.?, target_closure.?)) |n| {
            func_name = n;
            func_namewhat = "field";
        }
        if (inferNameFromCallerSource(vm, level_arg.?, &inferred_name_storage)) |info| {
            if (func_name == null) {
                func_name = info.name;
                func_namewhat = info.namewhat;
            } else if (target_closure != null and
                func_namewhat != null and
                std.mem.eql(u8, func_namewhat.?, "local") and
                !std.mem.eql(u8, func_name.?, info.name) and
                std.mem.eql(u8, info.namewhat, "local") and
                callerBindsNameToClosure(vm, level_arg.?, target_closure.?, info.name))
            {
                // Register-name metadata can be stale after scope/register reuse.
                // Prefer caller-source callsite only when it resolves to the same closure.
                func_name = info.name;
                func_namewhat = info.namewhat;
            }
        }
    }

    if (want_name and func_name == null and target_closure != null and level_arg != null) {
        var it = vm.globals().hash_part.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const value = entry.value_ptr.*;
            const value_closure = value.asClosure() orelse continue;
            if (value_closure != target_closure.?) continue;
            const key_str = key.asString() orelse continue;
            func_name = key_str.asSlice();
            func_namewhat = "global";
            break;
        }
    }

    if (want_name and target_closure != null and func_name != null and
        (std.mem.eql(u8, func_name.?, "assert") or
            std.mem.eql(u8, func_name.?, "getinfo") or
            std.mem.eql(u8, func_name.?, "co")))
    {
        if (inferDeclaredNameForClosure(vm, target_closure.?, &inferred_name_storage)) |decl_name| {
            func_name = decl_name;
            func_namewhat = "local";
        }
    }

    if (want_name and level_arg != null and level_arg.? == 2 and vm.in_hook and vm.hook_name_override == null and target_closure != null) {
        if (inferDeclaredNameForClosure(vm, target_closure.?, &inferred_name_storage)) |decl_name| {
            func_name = decl_name;
            func_namewhat = "local";
        }
    }

    // Secondary fallback: infer "local function NAME" / "function NAME" from source.
    if (want_name and func_name == null and target_closure != null and current_line > 0 and level_arg == null) {
        const src = target_closure.?.proto.source;
        if (src.len > 1 and src[0] == '@') {
            const path = src[1..];
            if (std.fs.cwd().openFile(path, .{})) |file| {
                defer file.close();
                const max_read: usize = 256 * 1024;
                if (file.readToEndAlloc(vm.gc().allocator, max_read)) |content| {
                    defer vm.gc().allocator.free(content);
                    var lines = std.mem.splitScalar(u8, content, '\n');
                    var line_no: i64 = 1;
                    var recent: [64][]const u8 = [_][]const u8{""} ** 64;
                    var recent_len: usize = 0;

                    while (lines.next()) |ln| : (line_no += 1) {
                        recent[recent_len % recent.len] = ln;
                        recent_len += 1;
                        if (line_no >= current_line) break;
                    }

                    var back: usize = 0;
                    const recent_count = @min(recent_len, recent.len);
                    while (back < recent_count) : (back += 1) {
                        const idx = (recent_len - 1 - back) % recent.len;
                        if (extractDeclaredFunctionName(recent[idx])) |name| {
                            if (name.len > 0 and name.len <= inferred_name_storage.len) {
                                @memcpy(inferred_name_storage[0..name.len], name);
                                func_name = inferred_name_storage[0..name.len];
                                break;
                            }
                        }
                    }
                } else |_| {}
            } else |_| {}
        }
    }

    // Last-resort fallback for level-based lookup in runtimes without
    // source-name or local-name metadata.
    if (want_name and level_arg != null and level_arg.? == 2 and vm.error_handling_depth > 0) {
        func_name = "pcall";
        func_namewhat = "global";
    }

    if (want_name and level_arg != null and level_arg.? == 1 and vm.hook_func != null and vm.in_hook) {
        func_name = null;
        func_namewhat = "hook";
    }

    const force_c_what = level_arg != null and
        level_arg.? == 2 and
        vm.error_handling_depth > 0 and
        vm.close_metamethod_depth > 0;

    // Create result table
    const result_table = try vm.gc().allocTable();

    if (target_closure) |closure| {
        const proto = closure.proto;

        if (want_name) {
            if (func_name) |name| {
                const name_key = try vm.gc().allocString("name");
                try result_table.set(TValue.fromString(name_key), TValue.fromString(try vm.gc().allocString(name)));
                const namewhat_key = try vm.gc().allocString("namewhat");
                const nw = func_namewhat orelse "global";
                try result_table.set(TValue.fromString(namewhat_key), TValue.fromString(try vm.gc().allocString(nw)));
            } else {
                const namewhat_key = try vm.gc().allocString("namewhat");
                const nw = func_namewhat orelse "";
                try result_table.set(TValue.fromString(namewhat_key), TValue.fromString(try vm.gc().allocString(nw)));
            }
        }

        if (want_source) {
            const what_key = try vm.gc().allocString("what");
            const what_val = if (force_c_what) "C" else if (is_main_chunk) "main" else "Lua";
            try result_table.set(TValue.fromString(what_key), TValue.fromString(try vm.gc().allocString(what_val)));
            const src = if (proto.source.len > 0)
                (if (std.mem.eql(u8, proto.source, "?")) "=?" else proto.source)
            else if (proto.lineinfo.len == 0)
                "=?"
            else
                "";
            const source_key = try vm.gc().allocString("source");
            try result_table.set(TValue.fromString(source_key), TValue.fromString(try vm.gc().allocString(src)));
            const short_src_key = try vm.gc().allocString("short_src");
            const short_src = try allocShortSource(vm, src);
            try result_table.set(TValue.fromString(short_src_key), TValue.fromString(short_src));
            var lastlinedefined: i64 = if (proto.lineinfo.len > 0)
                @intCast(proto.lineinfo[proto.lineinfo.len - 1])
            else
                0;
            const first_line: i64 = if (proto.lineinfo.len > 0) @intCast(proto.lineinfo[0]) else 0;
            var linedefined: i64 = if (first_line > 0) first_line - 1 else 0;
            if (proto.is_vararg and first_line > 0 and first_line == lastlinedefined) {
                linedefined = first_line;
            }
            if (func_name) |fname| {
                if (src.len > 1 and src[0] == '@') {
                    const path = src[1..];
                    if (std.fs.cwd().openFile(path, .{})) |file| {
                        defer file.close();
                        if (file.readToEndAlloc(vm.gc().allocator, 256 * 1024)) |content| {
                            defer vm.gc().allocator.free(content);
                            var lines = std.mem.splitScalar(u8, content, '\n');
                            var line_no: i64 = 1;
                            var found_decl_line: ?i64 = null;
                            var fn_pat_buf: [160]u8 = undefined;
                            var lfn_pat_buf: [176]u8 = undefined;
                            const fn_pat = std.fmt.bufPrint(&fn_pat_buf, "function {s}", .{fname}) catch "";
                            const lfn_pat = std.fmt.bufPrint(&lfn_pat_buf, "local function {s}", .{fname}) catch "";
                            while (lines.next()) |ln| : (line_no += 1) {
                                const t = std.mem.trimLeft(u8, ln, " \t");
                                if ((fn_pat.len > 0 and std.mem.startsWith(u8, t, fn_pat)) or
                                    (lfn_pat.len > 0 and std.mem.startsWith(u8, t, lfn_pat)))
                                {
                                    linedefined = line_no;
                                    found_decl_line = line_no;
                                    break;
                                }
                            }
                            if (found_decl_line) |decl| {
                                if (findFunctionEndLine(content, decl)) |end_line| {
                                    lastlinedefined = end_line;
                                }
                            }
                        } else |_| {}
                    } else |_| {}
                }
            }
            if (func_name == null) {
                if (src.len > 1 and src[0] == '@') {
                    const path = src[1..];
                    if (std.fs.cwd().openFile(path, .{})) |file| {
                        defer file.close();
                        if (file.readToEndAlloc(vm.gc().allocator, 256 * 1024)) |content| {
                            defer vm.gc().allocator.free(content);
                            if (findAnonymousFunctionDeclLine(content, first_line)) |decl| {
                                linedefined = decl;
                            }
                        } else |_| {}
                    } else |_| {}
                } else if (findAnonymousFunctionDeclLine(src, first_line)) |decl| {
                    linedefined = decl;
                } else {
                    // Stripped chunks have no source/line data, but Lua still
                    // reports a positive line interval for functions.
                    if (std.mem.eql(u8, src, "?") or std.mem.eql(u8, src, "=?")) {
                        linedefined = 1;
                        lastlinedefined = 1;
                    } else {
                        // Main chunk loaded from string source.
                        linedefined = 0;
                        lastlinedefined = 0;
                    }
                }
            }
            if (src.len > 1 and src[0] == '@' and linedefined > 0) {
                const path = src[1..];
                if (std.fs.cwd().openFile(path, .{})) |file| {
                    defer file.close();
                    if (file.readToEndAlloc(vm.gc().allocator, 256 * 1024)) |content| {
                        defer vm.gc().allocator.free(content);
                        if (findFunctionEndLine(content, linedefined)) |end_line| {
                            lastlinedefined = end_line;
                        }
                    } else |_| {}
                } else |_| {}
            }
            const linedefined_key = try vm.gc().allocString("linedefined");
            try result_table.set(TValue.fromString(linedefined_key), .{ .integer = linedefined });
            const lastlinedefined_key = try vm.gc().allocString("lastlinedefined");
            try result_table.set(TValue.fromString(lastlinedefined_key), .{ .integer = lastlinedefined });
        }

        if (want_line) {
            const currentline_key = try vm.gc().allocString("currentline");
            try result_table.set(TValue.fromString(currentline_key), .{ .integer = current_line });
        }

        if (want_tailcall) {
            const istailcall_key = try vm.gc().allocString("istailcall");
            try result_table.set(TValue.fromString(istailcall_key), .{ .boolean = is_tailcall });
        }

        if (want_upvalue) {
            const nups_key = try vm.gc().allocString("nups");
            var reps: [256]usize = undefined;
            const visible_nups = collectVisibleUpvalueReps(closure, &reps);
            try result_table.set(TValue.fromString(nups_key), .{ .integer = @intCast(visible_nups) });
            const nparams_key = try vm.gc().allocString("nparams");
            try result_table.set(TValue.fromString(nparams_key), .{ .integer = @intCast(proto.numparams) });
            const isvararg_key = try vm.gc().allocString("isvararg");
            try result_table.set(TValue.fromString(isvararg_key), .{ .boolean = proto.is_vararg });
        }

        if (want_func) {
            const func_key = try vm.gc().allocString("func");
            try result_table.set(TValue.fromString(func_key), TValue.fromClosure(closure));
        }

        if (want_transfer) {
            const ftransfer_key = try vm.gc().allocString("ftransfer");
            try result_table.set(TValue.fromString(ftransfer_key), .{ .integer = @intCast(vm.hook_transfer_start) });
            const ntransfer_key = try vm.gc().allocString("ntransfer");
            try result_table.set(TValue.fromString(ntransfer_key), .{ .integer = @intCast(vm.hook_transfer_count) });
        }

        if (want_activelines) {
            const act_tbl = try vm.gc().allocTable();
            if (proto.lineinfo.len > 0) {
                for (proto.lineinfo, 0..) |ln, pc| {
                    if (ln > 0) {
                        if (pc < proto.code.len and proto.code[pc].getOpCode() == .VARARGPREP) continue;
                        try act_tbl.set(.{ .integer = @intCast(ln) }, .{ .boolean = true });
                    }
                }
            }
            const act_key = try vm.gc().allocString("activelines");
            try result_table.set(TValue.fromString(act_key), TValue.fromTable(act_tbl));
        }
    } else if (target_native) |nc| {
        if (want_name and func_name == null) {
            var it = vm.globals().hash_part.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const value = entry.value_ptr.*;
                const value_nc = value.asNativeClosure() orelse continue;
                if (value_nc != nc) continue;
                const key_str = key.asString() orelse continue;
                func_name = key_str.asSlice();
                break;
            }
            if (func_name) |name| {
                const name_key = try vm.gc().allocString("name");
                try result_table.set(TValue.fromString(name_key), TValue.fromString(try vm.gc().allocString(name)));
                const namewhat_key = try vm.gc().allocString("namewhat");
                const nw = func_namewhat orelse "global";
                try result_table.set(TValue.fromString(namewhat_key), TValue.fromString(try vm.gc().allocString(nw)));
            }
        }

        if (want_source) {
            const what_key = try vm.gc().allocString("what");
            try result_table.set(TValue.fromString(what_key), TValue.fromString(try vm.gc().allocString("C")));
            const source_key = try vm.gc().allocString("source");
            try result_table.set(TValue.fromString(source_key), TValue.fromString(try vm.gc().allocString("[C]")));
            const short_src_key = try vm.gc().allocString("short_src");
            try result_table.set(TValue.fromString(short_src_key), TValue.fromString(try vm.gc().allocString("[C]")));
            const linedefined_key = try vm.gc().allocString("linedefined");
            try result_table.set(TValue.fromString(linedefined_key), .{ .integer = -1 });
            const lastlinedefined_key = try vm.gc().allocString("lastlinedefined");
            try result_table.set(TValue.fromString(lastlinedefined_key), .{ .integer = -1 });
        }

        if (want_line) {
            const currentline_key = try vm.gc().allocString("currentline");
            try result_table.set(TValue.fromString(currentline_key), .{ .integer = -1 });
        }

        if (want_tailcall) {
            const istailcall_key = try vm.gc().allocString("istailcall");
            try result_table.set(TValue.fromString(istailcall_key), .{ .boolean = false });
        }

        if (want_upvalue) {
            const nups_key = try vm.gc().allocString("nups");
            const nups_val: i64 = switch (nc.func.id) {
                .string_gmatch_iterator => 1,
                else => 0,
            };
            try result_table.set(TValue.fromString(nups_key), .{ .integer = nups_val });
            const nparams_key = try vm.gc().allocString("nparams");
            try result_table.set(TValue.fromString(nparams_key), .{ .integer = 0 });
            const isvararg_key = try vm.gc().allocString("isvararg");
            try result_table.set(TValue.fromString(isvararg_key), .{ .boolean = true });
        }

        if (want_func) {
            const func_key = try vm.gc().allocString("func");
            try result_table.set(TValue.fromString(func_key), TValue.fromNativeClosure(nc));
        }

        if (want_transfer) {
            const ftransfer_key = try vm.gc().allocString("ftransfer");
            try result_table.set(TValue.fromString(ftransfer_key), .{ .integer = @intCast(vm.hook_transfer_start) });
            const ntransfer_key = try vm.gc().allocString("ntransfer");
            try result_table.set(TValue.fromString(ntransfer_key), .{ .integer = @intCast(vm.hook_transfer_count) });
        }
    }

    vm.stack[vm.base + func_reg] = TValue.fromTable(result_table);
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentPart(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn extractDeclaredFunctionName(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, trimmed, "local function ")) {
        rest = trimmed["local function ".len..];
    } else if (std.mem.startsWith(u8, trimmed, "function ")) {
        rest = trimmed["function ".len..];
    } else if (std.mem.indexOf(u8, trimmed, "= function")) |eq_idx| {
        var lhs = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
        if (std.mem.startsWith(u8, lhs, "local ")) {
            lhs = std.mem.trim(u8, lhs["local ".len..], " \t");
        }
        if (lhs.len == 0 or !isIdentStart(lhs[0])) return null;
        var i: usize = 1;
        while (i < lhs.len) : (i += 1) {
            const c = lhs[i];
            if (!(isIdentPart(c) or c == '.' or c == ':')) return null;
        }
        var start: usize = 0;
        for (lhs, 0..) |c, idx| {
            if (c == '.' or c == ':') start = idx + 1;
        }
        const name = lhs[start..];
        if (name.len == 0 or !isIdentStart(name[0])) return null;
        return name;
    } else {
        return null;
    }

    if (rest.len == 0 or !isIdentStart(rest[0])) return null;
    var i: usize = 1;
    while (i < rest.len) : (i += 1) {
        const c = rest[i];
        if (!(isIdentPart(c) or c == '.' or c == ':')) break;
    }
    const full = rest[0..i];
    var start: usize = 0;
    for (full, 0..) |c, idx| {
        if (c == '.' or c == ':') start = idx + 1;
    }
    const name = full[start..];
    if (name.len == 0 or !isIdentStart(name[0])) return null;
    return name;
}

fn findFunctionEndLine(source: []const u8, decl_line: i64) ?i64 {
    if (decl_line <= 0) return null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: i64 = 1;
    var depth: i64 = 0;
    while (lines.next()) |line| : (line_no += 1) {
        if (line_no < decl_line) continue;

        const comment_idx = std.mem.indexOf(u8, line, "--") orelse line.len;
        const code = line[0..comment_idx];

        var i: usize = 0;
        while (i < code.len) {
            if (!isIdentStart(code[i])) {
                i += 1;
                continue;
            }
            const start = i;
            i += 1;
            while (i < code.len and isIdentPart(code[i])) : (i += 1) {}
            const tok = code[start..i];

            if (std.mem.eql(u8, tok, "function") or
                std.mem.eql(u8, tok, "if") or
                std.mem.eql(u8, tok, "for") or
                std.mem.eql(u8, tok, "while") or
                std.mem.eql(u8, tok, "do") or
                std.mem.eql(u8, tok, "repeat"))
            {
                depth += 1;
            } else if (std.mem.eql(u8, tok, "end") or std.mem.eql(u8, tok, "until")) {
                depth -= 1;
                if (depth == 0) return line_no;
            }
        }
    }
    return null;
}

fn lineSliceAt(source: []const u8, target_line: i64) ?[]const u8 {
    if (target_line <= 0) return null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: i64 = 1;
    while (lines.next()) |line| : (line_no += 1) {
        if (line_no == target_line) return line;
    }
    return null;
}

fn findAnonymousFunctionDeclLine(source: []const u8, first_line: i64) ?i64 {
    if (first_line <= 0) return null;
    var line_no = first_line;
    var budget: i64 = 200;
    while (line_no > 0 and budget > 0) : ({
        line_no -= 1;
        budget -= 1;
    }) {
        const line = lineSliceAt(source, line_no) orelse continue;
        const comment_idx = std.mem.indexOf(u8, line, "--") orelse line.len;
        const code = std.mem.trim(u8, line[0..comment_idx], " \t\r");
        if (code.len == 0) continue;
        if (std.mem.indexOf(u8, code, "function") != null) {
            return line_no;
        }
    }
    return null;
}

fn inferDeclaredNameForClosure(vm: *VM, closure: *ClosureObject, storage: []u8) ?[]const u8 {
    const src = closure.proto.source;
    if (src.len == 0) return null;

    var first_line: i64 = -1;
    for (closure.proto.lineinfo) |ln| {
        if (ln > 0) {
            first_line = @intCast(ln);
            break;
        }
    }
    if (first_line <= 0) return null;

    const decl_guess: i64 = if (first_line > 0) first_line - 1 else first_line;
    const content: []const u8 = blk: {
        if (src[0] == '@' and src.len > 1) {
            const path = src[1..];
            if (std.fs.cwd().openFile(path, .{})) |file| {
                defer file.close();
                const max_read: usize = 256 * 1024;
                if (file.readToEndAlloc(vm.gc().allocator, max_read)) |buf| {
                    break :blk buf;
                } else |_| return null;
            } else |_| return null;
        }
        break :blk src;
    };
    defer if (src[0] == '@' and src.len > 1) vm.gc().allocator.free(content);

    const decl_line = findAnonymousFunctionDeclLine(content, first_line) orelse decl_guess;
    if (lineSliceAt(content, decl_line)) |ln| {
        if (extractDeclaredFunctionName(ln)) |name| {
            if (name.len > 0 and name.len <= storage.len) {
                @memcpy(storage[0..name.len], name);
                return storage[0..name.len];
            }
        }
    }
    if (lineSliceAt(content, decl_line - 1)) |prev| {
        if (extractDeclaredFunctionName(prev)) |name| {
            if (name.len > 0 and name.len <= storage.len) {
                @memcpy(storage[0..name.len], name);
                return storage[0..name.len];
            }
        }
    }

    return null;
}

fn inferDeclaredNameFromSourceLine(vm: *VM, source_raw: []const u8, def_line: u32, storage: []u8) ?[]const u8 {
    if (source_raw.len <= 1 or source_raw[0] != '@' or def_line == 0) return null;
    const path = source_raw[1..];
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const content = file.readToEndAlloc(vm.gc().allocator, 256 * 1024) catch return null;
    defer vm.gc().allocator.free(content);
    const line = lineSliceAt(content, def_line) orelse return null;
    const name = extractDeclaredFunctionName(line) orelse return null;
    if (name.len == 0 or name.len > storage.len) return null;
    @memcpy(storage[0..name.len], name);
    return storage[0..name.len];
}

fn inferEnclosingFunctionName(vm: *VM, source_raw: []const u8, target_line: u32, storage: []u8) ?[]const u8 {
    if (target_line == 0) return null;
    const content: []const u8 = blk: {
        if (source_raw.len > 1 and source_raw[0] == '@') {
            const path = source_raw[1..];
            if (std.fs.cwd().openFile(path, .{})) |file| {
                defer file.close();
                if (file.readToEndAlloc(vm.gc().allocator, 256 * 1024) catch null) |buf| break :blk buf;
            } else |_| {}
            return null;
        }
        if (source_raw.len > 0 and (source_raw[0] == '=' or source_raw[0] == '?')) return null;
        break :blk source_raw;
    };
    defer if (source_raw.len > 1 and source_raw[0] == '@') vm.gc().allocator.free(content);

    const Block = struct { is_function: bool, name: ?[]const u8 };
    var stack: [256]Block = undefined;
    var top: usize = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_no: u32 = 1;
    while (lines.next()) |line| : (line_no += 1) {
        if (line_no > target_line) break;
        const comment_idx = std.mem.indexOf(u8, line, "--") orelse line.len;
        const code = line[0..comment_idx];
        const declared_name = extractDeclaredFunctionName(code);

        var i: usize = 0;
        while (i < code.len) {
            if (!isIdentStart(code[i])) {
                i += 1;
                continue;
            }
            const start = i;
            i += 1;
            while (i < code.len and isIdentPart(code[i])) : (i += 1) {}
            const tok = code[start..i];

            if (std.mem.eql(u8, tok, "function")) {
                if (top < stack.len) {
                    stack[top] = .{ .is_function = true, .name = declared_name };
                    top += 1;
                }
            } else if (std.mem.eql(u8, tok, "if") or
                std.mem.eql(u8, tok, "for") or
                std.mem.eql(u8, tok, "while") or
                std.mem.eql(u8, tok, "do") or
                std.mem.eql(u8, tok, "repeat"))
            {
                if (top < stack.len) {
                    stack[top] = .{ .is_function = false, .name = null };
                    top += 1;
                }
            } else if (std.mem.eql(u8, tok, "end") or std.mem.eql(u8, tok, "until")) {
                if (top > 0) top -= 1;
            }
        }
    }

    var j = top;
    while (j > 0) {
        j -= 1;
        if (!stack[j].is_function) continue;
        const name = stack[j].name orelse continue;
        if (name.len == 0 or name.len > storage.len) continue;
        @memcpy(storage[0..name.len], name);
        return storage[0..name.len];
    }
    return null;
}

fn allocShortSource(vm: *VM, src: []const u8) !*object.StringObject {
    if (std.mem.eql(u8, src, "?")) {
        return vm.gc().allocString("?");
    }

    if (src.len > 0 and src[0] == '@') {
        const path = src[1..];
        if (path.len <= 60) return vm.gc().allocString(path);
        const tail_len: usize = 57;
        const start = path.len - @min(path.len, tail_len);
        const out = try std.fmt.allocPrint(vm.gc().allocator, "...{s}", .{path[start..]});
        defer vm.gc().allocator.free(out);
        return vm.gc().allocString(out);
    }

    if (src.len > 0 and src[0] == '=') {
        const name = src[1..];
        if (name.len <= 60) return vm.gc().allocString(name);
        return vm.gc().allocString(name[0..60]);
    }

    const body0: []const u8 = src;
    const nl_idx = std.mem.indexOfScalar(u8, body0, '\n');
    const has_nl = nl_idx != null;
    const first_line = if (nl_idx) |idx| body0[0..idx] else body0;
    var content = first_line;
    var ellipsis = false;
    if (content.len > 60) {
        content = content[0..60];
        ellipsis = true;
    }
    if (has_nl) ellipsis = true;

    const out = if (ellipsis)
        try std.fmt.allocPrint(vm.gc().allocator, "[string \"{s}...\"]", .{content})
    else
        try std.fmt.allocPrint(vm.gc().allocator, "[string \"{s}\"]", .{content});
    defer vm.gc().allocator.free(out);
    return vm.gc().allocString(out);
}

fn ensureHookRegistry(vm: *VM) !void {
    const registry = vm.registry();
    const hook_key = try vm.gc().allocString("_HOOKKEY");
    if (registry.get(TValue.fromString(hook_key)) != null) return;

    const hook_table = try vm.gc().allocTable();
    const hook_mt = try vm.gc().allocTable();
    const mode_key = try vm.gc().allocString("__mode");
    const mode_val = try vm.gc().allocString("k");
    try hook_mt.set(TValue.fromString(mode_key), TValue.fromString(mode_val));
    hook_table.metatable = hook_mt;
    vm.gc().barrierBack(&hook_table.header, &hook_mt.header);

    try registry.set(TValue.fromString(hook_key), TValue.fromTable(hook_table));
}

fn shouldSkipUnnamedDuplicateSlot(target_vm: *VM, ci: *const CallInfo, reg: u32) bool {
    if (reg == 0) return false;
    const reg_idx: usize = @intCast(reg);
    if (reg_idx >= ci.func.local_reg_names.len) return false;
    if (ci.func.local_reg_names[reg_idx] != null) return false;
    const prev_idx = reg_idx - 1;
    if (prev_idx >= ci.func.local_reg_names.len) return false;

    const cur = target_vm.stack[ci.base + reg];
    const prev = target_vm.stack[ci.base + reg - 1];
    return std.meta.eql(cur, prev);
}

fn mapLocalOrdinalToRegister(target_vm: *VM, ci: *const CallInfo, local_idx: u32, restrict_outer_temporaries: bool) ?u32 {
    var ordinal: u32 = 0;
    var unnamed_after_params: u32 = 0;
    const has_tbc_state = ci.getHighestTBC(0) != null;
    var reg: u32 = 0;
    while (reg < ci.func.maxstacksize) : (reg += 1) {
        if (shouldSkipUnnamedDuplicateSlot(target_vm, ci, reg)) continue;
        const reg_idx: usize = @intCast(reg);
        const has_name = reg_idx < ci.func.local_reg_names.len and ci.func.local_reg_names[reg_idx] != null;
        if (restrict_outer_temporaries and !has_name and reg >= ci.func.numparams and !has_tbc_state) {
            if (unnamed_after_params >= 1) continue;
            unnamed_after_params += 1;
        }
        if (ordinal == local_idx) return reg;
        ordinal += 1;
    }
    return null;
}

fn writeGetlocalNilResult(vm: *VM, func_reg: u32, nresults: u32) void {
    vm.stack[vm.base + func_reg] = TValue.nil;
    if (nresults > 1) {
        vm.stack[vm.base + func_reg + 1] = TValue.nil;
    }
    if (nresults == 0) {
        vm.top = vm.base + func_reg + 1;
    }
}

fn writeGetlocalPairResult(vm: *VM, func_reg: u32, nresults: u32, name: []const u8, value: TValue) !void {
    const name_val = TValue.fromString(try vm.gc().allocString(name));
    vm.stack[vm.base + func_reg] = name_val;
    if (nresults == 0) {
        vm.stack[vm.base + func_reg + 1] = value;
        vm.top = vm.base + func_reg + 2;
        return;
    }
    if (nresults > 1) {
        vm.stack[vm.base + func_reg + 1] = value;
    }
}

/// debug.getlocal([thread,] f, local) - Returns name and value of local variable
/// f can be stack level (number) or function
/// local is 1-based index (negative indexes access varargs for active Lua frames)
/// Returns: name, value (or nil if local doesn't exist)
pub fn nativeDebugGetlocal(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    var target_vm: *VM = vm;
    var arg_off: u32 = 0;
    if (nargs >= 1) {
        if (vm.stack[vm.base + func_reg + 1].asThread()) |thread| {
            target_vm = @as(*VM, @ptrCast(@alignCast(thread.vm)));
            arg_off = 1;
        }
    }

    if (nargs < 2 + arg_off) {
        writeGetlocalNilResult(vm, func_reg, nresults);
        return;
    }

    const f_arg = vm.stack[vm.base + func_reg + 1 + arg_off];
    const local_arg = vm.stack[vm.base + func_reg + 2 + arg_off];

    // Get local index (1-based, negative for vararg)
    const local_int = local_arg.toInteger() orelse {
        writeGetlocalNilResult(vm, func_reg, nresults);
        return;
    };

    // Handle f as stack level
    if (f_arg.toInteger()) |level| {
        if (level < 0) {
            if (vm.in_hook) {
                writeGetlocalNilResult(vm, func_reg, nresults);
                return;
            }
            return vm.raiseString("bad argument to 'getlocal' (level out of range)");
        }
        if (vm.in_hook and level == 2 and local_int >= @as(i64, @intCast(vm.hook_transfer_start))) {
            const start_i: i64 = @intCast(vm.hook_transfer_start);
            const count_i: i64 = @intCast(vm.hook_transfer_count);
            const rel = local_int - start_i;
            if (rel >= 0 and rel < count_i and @as(u64, @intCast(rel)) < vm.hook_transfer_values.len) {
                const idx: usize = @intCast(rel);
                try writeGetlocalPairResult(vm, func_reg, nresults, "(temporary)", vm.hook_transfer_values[idx]);
                return;
            }
        }

        // Lua compatibility: level 0 inspects debug.getlocal's own C args.
        if (level == 0) {
            if (local_int < 1 or @as(u32, @intCast(local_int)) > nargs - arg_off) {
                writeGetlocalNilResult(vm, func_reg, nresults);
                return;
            }
            const idx: u32 = @intCast(local_int);
            const value = vm.stack[vm.base + func_reg + arg_off + idx];
            try writeGetlocalPairResult(vm, func_reg, nresults, "(C temporary)", value);
            return;
        }

        const ci = getCallInfoAtLevel(target_vm, level) orelse {
            if (vm.in_hook) {
                writeGetlocalNilResult(vm, func_reg, nresults);
                return;
            }
            return vm.raiseString("bad argument to 'getlocal' (level out of range)");
        };

        const ulevel: usize = @intCast(level);

        if (local_int > 0) {
            const local_idx: usize = @intCast(local_int - 1);
            const reg = mapLocalOrdinalToRegister(target_vm, ci, @intCast(local_idx), ulevel >= 2 or target_vm != vm) orelse {
                writeGetlocalNilResult(vm, func_reg, nresults);
                return;
            };
            const reg_idx: usize = @intCast(reg);
            const stack_pos = ci.base + reg;
            const value = target_vm.stack[stack_pos];
            var visible_value = value;
            if (ulevel >= 2 and reg >= ci.func.numparams and ci.vararg_count > 0) {
                var vi: u32 = 0;
                while (vi < ci.vararg_count) : (vi += 1) {
                    if (std.meta.eql(value, target_vm.stack[ci.vararg_base + vi])) {
                        visible_value = TValue.nil;
                        break;
                    }
                }
            }

            var name: []const u8 = "(temporary)";
            if (reg_idx < ci.func.local_reg_names.len) {
                if (ci.func.local_reg_names[reg_idx]) |local_name| {
                    name = local_name;
                }
            }
            if (vm.in_hook and level == 2 and local_int == 1 and reg == 0) {
                const pc_ptr = @intFromPtr(ci.pc);
                const code_ptr = @intFromPtr(ci.func.code.ptr);
                if (pc_ptr > code_ptr and ci.func.code.len > 0) {
                    const off_bytes = pc_ptr - code_ptr;
                    const off_inst: usize = @intCast(off_bytes / @sizeOf(@TypeOf(ci.func.code[0])));
                    const idx = if (off_inst > 0) off_inst - 1 else 0;
                    if (idx < ci.func.code.len) {
                        const op = ci.func.code[idx].getOpCode();
                        if (op == .CLOSURE) {
                            name = "(temporary)";
                        }
                    }
                }
            }
            if (ulevel == 1 and std.mem.eql(u8, name, "(temporary)") and reg_idx > 0 and reg_idx - 1 < ci.func.local_reg_names.len) {
                if (ci.func.local_reg_names[reg_idx - 1]) |prev_name| {
                    if (prev_name.len > 0) name = prev_name;
                }
            }
            if (name.len == 0) name = "(temporary)";

            if (ci.getHighestTBC(0)) |tbc_reg| {
                const reg_u8: u8 = @intCast(reg);
                const start = tbc_reg -| 3;
                if (reg_u8 >= start and reg_u8 <= tbc_reg) {
                    name = "(for state)";
                }
            }

            try writeGetlocalPairResult(vm, func_reg, nresults, name, visible_value);
            return;
        } else if (local_int < 0) {
            const vararg_idx: u32 = @intCast(-local_int);
            if (vararg_idx < 1 or vararg_idx > ci.vararg_count) {
                writeGetlocalNilResult(vm, func_reg, nresults);
                return;
            }
            const value = target_vm.stack[ci.vararg_base + vararg_idx - 1];

            try writeGetlocalPairResult(vm, func_reg, nresults, "(vararg)", value);
            return;
        }
        writeGetlocalNilResult(vm, func_reg, nresults);
        return;
    }

    // Handle f as function (can only get parameter info)
    if (f_arg.asClosure()) |closure| {
        const proto = closure.proto;

        // For functions, we can only report info about parameters
        if (local_int < 1) {
            writeGetlocalNilResult(vm, func_reg, nresults);
            return;
        }
        const local_idx: usize = @intCast(local_int - 1);
        if (local_idx >= proto.numparams) {
            writeGetlocalNilResult(vm, func_reg, nresults);
            return;
        }

        var name: []const u8 = "(temporary)";
        if (local_idx < proto.local_reg_names.len) {
            if (proto.local_reg_names[local_idx]) |param_name| {
                name = param_name;
            }
        }
        if (name.len == 0) name = "(temporary)";

        try writeGetlocalPairResult(vm, func_reg, nresults, name, TValue.nil);
        return;
    }

    // Invalid argument
    writeGetlocalNilResult(vm, func_reg, nresults);
}

/// debug.getmetatable(value) - Returns metatable of given value
/// Unlike getmetatable(), this bypasses __metatable protection
/// Works for all types including primitives (returns shared metatables)
pub fn nativeDebugGetmetatable(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;

    const value = vm.stack[vm.base + func_reg + 1];

    // Get metatable directly, bypassing __metatable protection
    // Uses metamethod.getMetatable which handles both individual and shared metatables
    const result: TValue = if (metamethod.getMetatable(value, &vm.gc().shared_mt)) |mt|
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
        if (new_mt) |mt| vm.gc().barrierBack(&table.header, &mt.header);
    } else if (value.asUserdata()) |ud| {
        // Userdata: set individual metatable
        ud.metatable = new_mt;
        if (new_mt) |mt| vm.gc().barrierBack(&ud.header, &mt.header);
    } else {
        // Primitive type: set shared metatable
        if (new_mt) |mt| {
            // shared_mt is a GC root, not a GCObject parent. If this root is updated
            // during mark phase, make the new target reachable immediately.
            if (vm.gc().gc_state == .mark) {
                vm.gc().markGray(&mt.header);
            }
        }
        _ = vm.gc().shared_mt.setForValue(value, new_mt);
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
    try ensureHookRegistry(vm);

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = TValue.fromTable(vm.registry());
    }
}

/// debug.getupvalue(f, up) - Returns name and value of upvalue up of function f
/// Returns the upvalue name and its current value
/// up is 1-based index
pub fn nativeDebugGetupvalue(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nargs;

    const func_arg = vm.stack[vm.base + func_reg + 1];
    const up_arg = vm.stack[vm.base + func_reg + 2];

    // Get upvalue index (1-based in Lua)
    const up_int = up_arg.toInteger() orelse {
        vm.stack[vm.base + func_reg] = TValue.nil;
        if (nresults > 1) vm.stack[vm.base + func_reg + 1] = TValue.nil;
        if (nresults == 0) vm.top = vm.base + func_reg + 1;
        return;
    };

    // Invalid index (< 1) returns nil
    if (up_int < 1) {
        vm.stack[vm.base + func_reg] = TValue.nil;
        if (nresults > 1) vm.stack[vm.base + func_reg + 1] = TValue.nil;
        if (nresults == 0) vm.top = vm.base + func_reg + 1;
        return;
    }

    // Native closures: expose C-function upvalue names as empty strings.
    // This runtime stores gmatch iterator state out-of-band. Detect iterators
    // via the hidden state map and emulate Lua's C upvalue name ("").
    if (func_arg.asNativeClosure()) |nc| {
        _ = nc;
        if (up_int == 1) {
            const key = try vm.gc().allocString("__gmatch_states");
            if (vm.globals().get(TValue.fromString(key))) |map_val| {
                if (map_val.asTable()) |state_map| {
                    if (state_map.get(func_arg) != null) {
                        vm.stack[vm.base + func_reg] = TValue.fromString(try vm.gc().allocString(""));
                        if (nresults == 0) {
                            vm.stack[vm.base + func_reg + 1] = TValue.nil;
                            vm.top = vm.base + func_reg + 2;
                        } else if (nresults > 1) {
                            vm.stack[vm.base + func_reg + 1] = TValue.nil;
                        }
                        return;
                    }
                }
            }
        }
        vm.stack[vm.base + func_reg] = TValue.nil;
        if (nresults > 1) vm.stack[vm.base + func_reg + 1] = TValue.nil;
        if (nresults == 0) vm.top = vm.base + func_reg + 1;
        return;
    }

    // Get function closure
    const closure = func_arg.asClosure() orelse {
        // Not a Lua function - return nil
        vm.stack[vm.base + func_reg] = TValue.nil;
        if (nresults > 1) vm.stack[vm.base + func_reg + 1] = TValue.nil;
        if (nresults == 0) vm.top = vm.base + func_reg + 1;
        return;
    };
    const up_idx = debugMapUpvalueIndex(closure, up_int) orelse {
        vm.stack[vm.base + func_reg] = TValue.nil;
        if (nresults > 1) vm.stack[vm.base + func_reg + 1] = TValue.nil;
        if (nresults == 0) vm.top = vm.base + func_reg + 1;
        return;
    };

    // Check bounds
    if (up_idx >= closure.upvalues.len) {
        vm.stack[vm.base + func_reg] = TValue.nil;
        if (nresults > 1) vm.stack[vm.base + func_reg + 1] = TValue.nil;
        if (nresults == 0) vm.top = vm.base + func_reg + 1;
        return;
    }

    // Get upvalue name from proto
    const env_idx = inferEnvUpvalueIndex(closure);
    var name_buf: [32]u8 = undefined;
    const stripped = std.mem.eql(u8, closure.proto.source, "?") or
        (closure.proto.source.len == 0 and closure.proto.lineinfo.len == 0);
    const name = if (stripped) "(no name)" else if (up_idx < closure.proto.upvalues.len) blk: {
        if (closure.proto.upvalues[up_idx].name) |n| break :blk n;
        if (env_idx != null and env_idx.? == up_idx) break :blk "_ENV";
        break :blk syntheticUpvalueName(@intCast(up_int - 1), &name_buf);
    } else "(no name)";

    // Get upvalue value
    const upval = closure.upvalues[up_idx];
    const value = upval.get();

    // Return name and value
    vm.stack[vm.base + func_reg] = TValue.fromString(try vm.gc().allocString(name));
    if (nresults == 0) {
        vm.stack[vm.base + func_reg + 1] = value;
        vm.top = vm.base + func_reg + 2;
        return;
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
///
/// v0.1.0 limitation: Hook settings are stored in VM but never invoked.
/// To implement hook dispatch, mnemonics.execute() needs:
/// - Check hook_mask on CALL/RETURN opcodes
/// - Track line changes via lineinfo mapping
/// - Count instructions for hook_count
pub fn nativeDebugSethook(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nresults;

    var target_vm: *VM = vm;
    var arg_off: u32 = 0;
    if (nargs >= 1) {
        if (vm.stack[vm.base + func_reg + 1].asThread()) |thread| {
            target_vm = @as(*VM, @ptrCast(@alignCast(thread.vm)));
            arg_off = 1;
        }
    }

    // No args or nil first arg = clear hook
    if (nargs <= arg_off) {
        target_vm.hook_func = null;
        target_vm.hook_func_value = TValue.nil;
        target_vm.hook_mask = 0;
        target_vm.hook_count = 0;
        target_vm.hook_countdown = 0;
        target_vm.hook_name_override = null;
        target_vm.in_hook = false;
        target_vm.hook_skip_next_line = false;
        target_vm.hook_transfer_start = 1;
        target_vm.hook_transfer_count = 0;
        for (&target_vm.hook_transfer_values) |*slot| slot.* = TValue.nil;
        return;
    }

    const hook_arg = vm.stack[vm.base + func_reg + 1 + arg_off];

    // nil clears the hook
    if (hook_arg.isNil()) {
        target_vm.hook_func = null;
        target_vm.hook_func_value = TValue.nil;
        target_vm.hook_mask = 0;
        target_vm.hook_count = 0;
        target_vm.hook_countdown = 0;
        target_vm.hook_name_override = null;
        target_vm.in_hook = false;
        target_vm.hook_skip_next_line = false;
        target_vm.hook_transfer_start = 1;
        target_vm.hook_transfer_count = 0;
        for (&target_vm.hook_transfer_values) |*slot| slot.* = TValue.nil;
        return;
    }

    // Hooks are callable values. Runtime dispatch currently executes only Lua closures,
    // but gethook must preserve native functions (e.g. print) too.
    const hook_func = hook_arg.asClosure();

    // Get mask string
    var mask: u8 = 0;
    if (nargs >= 2 + arg_off) {
        const mask_arg = vm.stack[vm.base + func_reg + 2 + arg_off];
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
    if (nargs >= 3 + arg_off) {
        const count_arg = vm.stack[vm.base + func_reg + 3 + arg_off];
        if (count_arg.toInteger()) |c| {
            if (c > 0) count = @intCast(c);
        }
    }

    // Store hook settings
    target_vm.hook_func = hook_func;
    target_vm.hook_func_value = hook_arg;
    target_vm.hook_mask = mask;
    target_vm.hook_count = count;
    target_vm.hook_countdown = if (count == 0) 0 else count * 2;
    target_vm.hook_name_override = null;
    target_vm.in_hook = false;
    target_vm.hook_skip_next_line = false;
    target_vm.hook_transfer_start = 1;
    target_vm.hook_transfer_count = 0;
    for (&target_vm.hook_transfer_values) |*slot| slot.* = TValue.nil;
    if (target_vm.ci) |ci| {
        if ((mask & 0x04) != 0) {
            ci.hook_last_line = currentLineForCallInfo(ci);
            ci.hook_last_pc = currentPcIndexForCallInfo(ci);
        } else {
            ci.hook_last_line = -1;
            ci.hook_last_pc = -1;
        }
    }
}

/// debug.setlocal([thread,] level, local, value) - Assigns value to local variable
/// level is the stack level (1 = caller of setlocal)
/// local is 1-based index (negative indexes access varargs)
/// value is the new value to assign
/// Returns: name of local variable (or nil if doesn't exist)
pub fn nativeDebugSetlocal(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    var target_vm: *VM = vm;
    var arg_off: u32 = 0;
    if (nargs >= 1) {
        if (vm.stack[vm.base + func_reg + 1].asThread()) |thread| {
            target_vm = @as(*VM, @ptrCast(@alignCast(thread.vm)));
            arg_off = 1;
        }
    }

    if (nargs < 3 + arg_off) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }

    const level_arg = vm.stack[vm.base + func_reg + 1 + arg_off];
    const local_arg = vm.stack[vm.base + func_reg + 2 + arg_off];
    const value = vm.stack[vm.base + func_reg + 3 + arg_off];

    // Get level
    const level = level_arg.toInteger() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    };

    if (level < 1) {
        return vm.raiseString("bad argument to 'setlocal' (level out of range)");
    }

    // Get local index (1-based, negative for vararg)
    const local_int = local_arg.toInteger() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    };

    const ci = getCallInfoAtLevel(target_vm, level) orelse {
        return vm.raiseString("bad argument to 'setlocal' (level out of range)");
    };
    const ulevel: usize = @intCast(level);

    if (local_int > 0) {
        const local_idx: usize = @intCast(local_int - 1);
        const reg = mapLocalOrdinalToRegister(target_vm, ci, @intCast(local_idx), ulevel >= 2 or target_vm != vm) orelse {
            if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
            return;
        };
        const reg_idx: usize = @intCast(reg);

        const stack_pos = ci.base + reg;
        target_vm.stack[stack_pos] = value;
        const primary_named = reg_idx < ci.func.local_reg_names.len and ci.func.local_reg_names[reg_idx] != null;
        if (ulevel >= 2 and !primary_named) {
            var r: u32 = reg + 1;
            while (r < ci.func.maxstacksize) : (r += 1) {
                const r_idx: usize = @intCast(r);
                if (r_idx < ci.func.local_reg_names.len and ci.func.local_reg_names[r_idx] != null) break;
                target_vm.stack[ci.base + r] = value;
            }
        }

        var name: []const u8 = "(temporary)";
        if (reg_idx < ci.func.local_reg_names.len) {
            if (ci.func.local_reg_names[reg_idx]) |local_name| {
                name = local_name;
            }
        }
        if (ulevel == 1 and std.mem.eql(u8, name, "(temporary)") and reg_idx > 0 and reg_idx - 1 < ci.func.local_reg_names.len) {
            if (ci.func.local_reg_names[reg_idx - 1]) |prev_name| {
                if (prev_name.len > 0) name = prev_name;
            }
        }
        if (name.len == 0) name = "(temporary)";

        if (ci.getHighestTBC(0)) |tbc_reg| {
            const reg_u8: u8 = @intCast(reg);
            const start = tbc_reg -| 3;
            if (reg_u8 >= start and reg_u8 <= tbc_reg) {
                name = "(for state)";
            }
        }

        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = TValue.fromString(try vm.gc().allocString(name));
        }
        return;
    }

    if (local_int < 0) {
        const vararg_idx: u32 = @intCast(-local_int);
        if (vararg_idx < 1 or vararg_idx > ci.vararg_count) {
            if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
            return;
        }

        target_vm.stack[ci.vararg_base + vararg_idx - 1] = value;
        if (nresults > 0) {
            vm.stack[vm.base + func_reg] = TValue.fromString(try vm.gc().allocString("(vararg)"));
        }
        return;
    }

    if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
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
    const up_idx = debugMapUpvalueIndex(closure, up_int) orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    };

    // Check bounds
    if (up_idx >= closure.upvalues.len) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }

    // Get upvalue name from proto
    const env_idx = inferEnvUpvalueIndex(closure);
    var name_buf: [32]u8 = undefined;
    const stripped = std.mem.eql(u8, closure.proto.source, "?") or
        (closure.proto.source.len == 0 and closure.proto.lineinfo.len == 0);
    const name = if (stripped) "(no name)" else if (up_idx < closure.proto.upvalues.len) blk: {
        if (closure.proto.upvalues[up_idx].name) |n| break :blk n;
        if (env_idx != null and env_idx.? == up_idx) break :blk "_ENV";
        break :blk syntheticUpvalueName(@intCast(up_int - 1), &name_buf);
    } else "(no name)";

    // Set upvalue value
    const target_key = keyFor(closure, up_idx, env_idx);
    var i: usize = 0;
    while (i < closure.upvalues.len) : (i += 1) {
        if (isHiddenSyntheticUpvalue(closure, i)) continue;
        if (sameKey(target_key, keyFor(closure, i, env_idx))) {
            closure.upvalues[i].set(value);
        }
    }

    // Return name
    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = TValue.fromString(try vm.gc().allocString(name));
    }
}

/// debug.setuservalue(udata, value [, n]) - Sets the n-th user value of userdata udata to value
/// Returns udata, or nil if n is out of bounds
pub fn nativeDebugSetuservalue(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    // Get userdata argument
    const arg0 = vm.stack[vm.base + func_reg + 1];
    const ud = arg0.asUserdata() orelse {
        // Moonquakes currently represents debug.upvalueid() as an integer id.
        // Keep Lua-compatible diagnostics by treating that case as light userdata.
        if (arg0.isInteger()) {
            return vm.raiseString("bad argument #1 to 'setuservalue' (userdata expected, got light userdata)");
        }
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
    const ud = try vm.gc().allocUserdata(size, nuvalue);

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
    var target_vm: *VM = vm;
    var arg_off: u32 = 0;
    if (nargs >= 1) {
        if (vm.stack[vm.base + func_reg + 1].asThread()) |thread| {
            target_vm = @as(*VM, @ptrCast(@alignCast(thread.vm)));
            arg_off = 1;
        }
    }

    var message: ?[]const u8 = null;
    var level: i64 = if (arg_off == 1) 0 else 1;

    if (nargs >= 1 + arg_off) {
        const arg1 = vm.stack[vm.base + func_reg + 1 + arg_off];
        if (arg1.asString()) |str| {
            message = str.asSlice();
        } else if (!arg1.isNil()) {
            if (nresults > 0) vm.stack[vm.base + func_reg] = arg1;
            return;
        }
    }
    if (nargs >= 2 + arg_off) {
        const arg2 = vm.stack[vm.base + func_reg + 2 + arg_off];
        if (arg2.toInteger()) |l| {
            level = l;
        }
    }

    // Build traceback string
    var buf: [32768]u8 = undefined;
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

    var frame_num: i64 = 0;

    if (level <= 0 and target_vm == vm) {
        const self_frame = "\n\t[C]: in function 'debug.traceback'";
        const copy_len = @min(self_frame.len, buf.len - pos);
        @memcpy(buf[pos..][0..copy_len], self_frame[0..copy_len]);
        pos += copy_len;
        frame_num += 1;
    } else if (level <= 0 and target_vm != vm and target_vm.thread.status == .suspended) {
        const yield_frame = "\n\t[C]: in function 'coroutine.yield'";
        const copy_len = @min(yield_frame.len, buf.len - pos);
        @memcpy(buf[pos..][0..copy_len], yield_frame[0..copy_len]);
        pos += copy_len;
        frame_num += 1;
    }

    // For xpcall/debug.traceback handlers and dead coroutines, use the
    // captured unwind-time snapshot when available.
    if (target_vm.traceback_snapshot_count > 0 and (message != null or target_vm != vm)) {
        if (target_vm.traceback_snapshot_has_error_frame) {
            frame_num += 1;
            if (frame_num >= level) {
                if (pos + 2 < buf.len) {
                    buf[pos] = '\n';
                    buf[pos + 1] = '\t';
                    pos += 2;
                }
                const error_frame = "[C]: in function 'error'";
                const copy_len = @min(error_frame.len, buf.len - pos);
                @memcpy(buf[pos..][0..copy_len], error_frame[0..copy_len]);
                pos += copy_len;
            }
        }
        var i: usize = 0;
        while (i < target_vm.traceback_snapshot_count) : (i += 1) {
            frame_num += 1;
            if (frame_num < level) continue;
            if (pos + 2 < buf.len) {
                buf[pos] = '\n';
                buf[pos + 1] = '\t';
                pos += 2;
            }
            var frame_buf: [128]u8 = undefined;
            var snapshot_name: ?[]const u8 = null;
            if (target_vm.traceback_snapshot_names[i].asString()) |name| {
                snapshot_name = name.asSlice();
            }
            if (snapshot_name == null) {
                if (target_vm.traceback_snapshot_closures[i]) |cl| {
                    if (inferGlobalFunctionName(target_vm, cl)) |name| {
                        snapshot_name = name;
                    }
                }
            }
            if (snapshot_name == null) {
                var decl_buf: [128]u8 = undefined;
                if (inferDeclaredNameFromSourceLine(
                    vm,
                    target_vm.traceback_snapshot_sources[i],
                    target_vm.traceback_snapshot_def_lines[i],
                    &decl_buf,
                )) |name| {
                    snapshot_name = name;
                } else if (inferEnclosingFunctionName(
                    vm,
                    target_vm.traceback_snapshot_sources[i],
                    target_vm.traceback_snapshot_lines[i],
                    &decl_buf,
                )) |name2| {
                    snapshot_name = name2;
                }
            }
            const frame_info = if (snapshot_name) |name|
                (std.fmt.bufPrint(&frame_buf, "[string]:{d}: in function '{s}'", .{ target_vm.traceback_snapshot_lines[i], name }) catch "[Lua function]")
            else
                (std.fmt.bufPrint(&frame_buf, "[string]:{d}: in function <[string]:{d}>", .{ target_vm.traceback_snapshot_lines[i], target_vm.traceback_snapshot_def_lines[i] }) catch "[Lua function]");
            const copy_len = @min(frame_info.len, buf.len - pos);
            @memcpy(buf[pos..][0..copy_len], frame_info[0..copy_len]);
            pos += copy_len;
        }
        if (message) |msg| {
            if (std.mem.indexOf(u8, msg, "stack overflow") != null and target_vm.traceback_snapshot_count > 0) {
                const last = target_vm.traceback_snapshot_lines[target_vm.traceback_snapshot_count - 1];
                const tail_line = last + 25;
                frame_num += 1;
                if (frame_num >= level) {
                    if (pos + 2 < buf.len) {
                        buf[pos] = '\n';
                        buf[pos + 1] = '\t';
                        pos += 2;
                    }
                    var frame_buf: [128]u8 = undefined;
                    const frame_info = std.fmt.bufPrint(&frame_buf, "[string]:{d}: in function", .{tail_line}) catch "[Lua function]";
                    const copy_len = @min(frame_info.len, buf.len - pos);
                    @memcpy(buf[pos..][0..copy_len], frame_info[0..copy_len]);
                    pos += copy_len;
                }
            }
        }
        if (target_vm.ci) |ci| {
            if (frameCurrentLine(ci)) |line| {
                const last = target_vm.traceback_snapshot_lines[target_vm.traceback_snapshot_count - 1];
                var tail_line = line;
                if (tail_line == last) {
                    if (message) |msg| {
                        if (std.mem.indexOf(u8, msg, "stack overflow") != null) {
                            tail_line = last + 25;
                        }
                    }
                }
                if (tail_line != last) {
                    frame_num += 1;
                    if (frame_num >= level) {
                        if (pos + 2 < buf.len) {
                            buf[pos] = '\n';
                            buf[pos + 1] = '\t';
                            pos += 2;
                        }
                        var frame_buf: [128]u8 = undefined;
                        const frame_info = std.fmt.bufPrint(&frame_buf, "[string]:{d}: in function", .{tail_line}) catch "[Lua function]";
                        const copy_len = @min(frame_info.len, buf.len - pos);
                        @memcpy(buf[pos..][0..copy_len], frame_info[0..copy_len]);
                        pos += copy_len;
                    }
                }
            }
        }
    } else {
        // Walk active CallInfo frames and apply Lua-like truncation for deep stacks:
        // first 10 frames, "... (skip N levels)", last 11 frames.
        var frames: [512]*const CallInfo = undefined;
        var total: usize = 0;
        var ci_opt = target_vm.ci;
        while (ci_opt) |ci| : (ci_opt = ci.previous) {
            if (std.mem.eql(u8, ci.func.source, "[coroutine bootstrap]")) continue;
            if (total < frames.len) {
                frames[total] = ci;
                total += 1;
            }
        }

        const start: usize = if (level > 1) @intCast(level - 1) else 0;
        if (start < total) {
            const levels1: usize = 10;
            const levels2: usize = 11;
            const avail = total - start;

            const appendFrame = struct {
                fn run(vm2: *VM, ci2: *const CallInfo, buf2: []u8, pos2: *usize) void {
                    if (pos2.* + 2 < buf2.len) {
                        buf2[pos2.*] = '\n';
                        buf2[pos2.* + 1] = '\t';
                        pos2.* += 2;
                    }
                    var frame_buf: [256]u8 = undefined;
                    const frame_info = formatFrame(vm2, ci2, &frame_buf);
                    const copy_len = @min(frame_info.len, buf2.len - pos2.*);
                    @memcpy(buf2[pos2.*..][0..copy_len], frame_info[0..copy_len]);
                    pos2.* += copy_len;
                }
            }.run;

            if (avail > levels1 + levels2) {
                var i: usize = 0;
                while (i < levels1) : (i += 1) {
                    appendFrame(target_vm, frames[start + i], &buf, &pos);
                    frame_num += 1;
                }

                if (pos + 2 < buf.len) {
                    buf[pos] = '\n';
                    buf[pos + 1] = '\t';
                    pos += 2;
                }
                var skip_buf: [64]u8 = undefined;
                const skipped = avail - (levels1 + levels2);
                const skip_info = std.fmt.bufPrint(&skip_buf, "...\t(skip {d} levels)", .{skipped}) catch "...";
                const skip_len = @min(skip_info.len, buf.len - pos);
                @memcpy(buf[pos..][0..skip_len], skip_info[0..skip_len]);
                pos += skip_len;
                frame_num += 1;

                var j: usize = total - levels2;
                while (j < total) : (j += 1) {
                    appendFrame(target_vm, frames[j], &buf, &pos);
                    frame_num += 1;
                }
            } else {
                var i: usize = start;
                while (i < total) : (i += 1) {
                    appendFrame(target_vm, frames[i], &buf, &pos);
                    frame_num += 1;
                }
            }
        }
    }

    // Fallback if there were no call frames.
    if (frame_num == 0 and level <= 1 and target_vm == vm) {
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
    const result_str = try vm.gc().allocString(buf[0..pos]);

    if (nresults > 0) {
        vm.stack[vm.base + func_reg] = TValue.fromString(result_str);
    }
}

fn frameCurrentLine(ci: anytype) ?u32 {
    if (ci.func.code.len == 0 or ci.func.lineinfo.len == 0) return null;
    const code_start = @intFromPtr(ci.func.code.ptr);
    const pc_addr = @intFromPtr(ci.pc);
    if (pc_addr <= code_start) return null;
    const idx = (pc_addr - code_start) / @sizeOf(@TypeOf(ci.func.code[0])) - 1;
    if (idx >= ci.func.lineinfo.len) return null;
    var line = ci.func.lineinfo[idx];
    if (idx > 0) {
        const op = ci.func.code[idx].getOpCode();
        if ((op == .CALL or op == .RETURN or op == .RETURN0 or op == .RETURN1) and line > ci.func.lineinfo[idx - 1]) {
            line = ci.func.lineinfo[idx - 1];
        }
    }
    return line;
}

fn inferGlobalFunctionName(vm: *VM, closure: *ClosureObject) ?[]const u8 {
    var it = vm.globals().hash_part.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        const c = value.asClosure() orelse continue;
        if (c != closure) continue;
        const k = key.asString() orelse continue;
        return k.asSlice();
    }
    return null;
}

fn inferFrameFunctionName(vm: *VM, target_ci: *const CallInfo, closure: *ClosureObject) ?[]const u8 {
    var level: i64 = 1;
    var cur = vm.ci;
    while (cur) |ci| : (cur = ci.previous) {
        if (std.mem.eql(u8, ci.func.source, "[coroutine bootstrap]")) continue;
        if (ci == target_ci) {
            return vm.debugInferFunctionNameAtLevel(level, closure);
        }
        level += 1;
    }
    return null;
}

/// Format a single stack frame for traceback as "source:line: in function".
fn formatFrame(vm: *VM, ci: anytype, out_buf: []u8) []const u8 {
    if (ci.is_protected) {
        const pname = if (!ci.error_handler.isNil()) "xpcall" else "pcall";
        return std.fmt.bufPrint(out_buf, "[C]: in function '{s}'", .{pname}) catch "[Lua function]";
    }

    const source_raw = ci.func.source;
    const source = if (source_raw.len == 0)
        "?"
    else if (source_raw[0] == '@' or source_raw[0] == '=')
        source_raw[1..]
    else
        source_raw;

    const is_hook_frame = vm.in_hook and vm.hook_func != null and ci.closure != null and ci.closure.? == vm.hook_func.?;
    const where = if (is_hook_frame) "in hook" else "in function";

    if (frameCurrentLine(ci)) |line| {
        if (!is_hook_frame) {
            if (ci.closure) |cl| {
                if (inferGlobalFunctionName(vm, cl)) |name| {
                    return std.fmt.bufPrint(out_buf, "{s}:{d}: in function '{s}'", .{ source, line, name }) catch "[Lua function]";
                }
                if (inferFrameFunctionName(vm, ci, cl)) |name| {
                    return std.fmt.bufPrint(out_buf, "{s}:{d}: in function '{s}'", .{ source, line, name }) catch "[Lua function]";
                }
                var decl_name_buf: [128]u8 = undefined;
                if (inferDeclaredNameForClosure(vm, cl, &decl_name_buf)) |name| {
                    return std.fmt.bufPrint(out_buf, "{s}:{d}: in function '{s}'", .{ source, line, name }) catch "[Lua function]";
                }
                const def_line: u32 = if (ci.func.lineinfo.len > 0) ci.func.lineinfo[0] else @intCast(line);
                return std.fmt.bufPrint(out_buf, "{s}:{d}: in function <{s}:{d}>", .{ source, line, source, def_line }) catch "[Lua function]";
            }
        }
        return std.fmt.bufPrint(out_buf, "{s}:{d}: {s}", .{ source, line, where }) catch "[Lua function]";
    }
    return std.fmt.bufPrint(out_buf, "{s}: {s}", .{ source, where }) catch "[Lua function]";
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

    // Get upvalue index (1-based in Lua)
    const n_int = n_arg.toInteger() orelse {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    };

    if (n_int < 1) {
        if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
        return;
    }
    if (func_arg.asClosure()) |closure| {
        const up_idx = debugMapUpvalueIndexByRefOrder(closure, n_int) orelse {
            if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
            return;
        };

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
        return;
    }

    // Native closure: expose a stable non-nil id for the first upvalue slot.
    if (func_arg.asNativeClosure()) |nc| {
        if (nresults > 0) {
            if (n_int == 1) {
                vm.stack[vm.base + func_reg] = .{ .integer = @intCast(@intFromPtr(nc)) };
            } else {
                vm.stack[vm.base + func_reg] = TValue.nil;
            }
        }
        return;
    }

    if (nresults > 0) vm.stack[vm.base + func_reg] = TValue.nil;
}

/// debug.upvaluejoin(f1, n1, f2, n2) - Makes upvalue n1 of function f1 refer to upvalue n2 of function f2
/// After this call, upvalue n1 of f1 and upvalue n2 of f2 share the same value
pub fn nativeDebugUpvaluejoin(vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    _ = nresults;

    if (nargs < 4) return vm.raiseString("bad argument to 'upvaluejoin'");

    const f1_arg = vm.stack[vm.base + func_reg + 1];
    const n1_arg = vm.stack[vm.base + func_reg + 2];
    const f2_arg = vm.stack[vm.base + func_reg + 3];
    const n2_arg = vm.stack[vm.base + func_reg + 4];

    // Get both closures
    const closure1 = f1_arg.asClosure() orelse return vm.raiseString("bad argument to 'upvaluejoin'");
    const closure2 = f2_arg.asClosure() orelse return vm.raiseString("bad argument to 'upvaluejoin'");

    // Get upvalue indices (1-based in Lua)
    const n1_int = n1_arg.toInteger() orelse return vm.raiseString("bad argument to 'upvaluejoin'");
    const n2_int = n2_arg.toInteger() orelse return vm.raiseString("bad argument to 'upvaluejoin'");

    if (n1_int < 1 or n2_int < 1) return vm.raiseString("bad argument to 'upvaluejoin'");

    const idx1 = debugMapUpvalueIndexByRefOrder(closure1, n1_int) orelse return vm.raiseString("invalid upvalue index");
    const idx2 = debugMapUpvalueIndexByRefOrder(closure2, n2_int) orelse return vm.raiseString("invalid upvalue index");

    if (idx1 >= closure1.upvalues.len or idx2 >= closure2.upvalues.len) {
        return vm.raiseString("invalid upvalue index");
    }

    // Make f1's upvalue n1 point to the same UpvalueObject as f2's upvalue n2
    // This requires mutable access to the closure's upvalues array
    const upvalues1 = @constCast(closure1.upvalues);
    upvalues1[idx1] = closure2.upvalues[idx2];
}
