//! REPL - Read-Eval-Print Loop
//!
//! Interactive Lua interpreter for Moonquakes.
//! Maintains a persistent Runtime/VM state across inputs.

const std = @import("std");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const VM = @import("../vm/vm.zig").VM;
const GC = @import("../runtime/gc/gc.zig").GC;
const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");
const pipeline = @import("../compiler/pipeline.zig");
const RawProto = @import("../compiler/proto.zig").RawProto;
const ReturnValue = @import("../vm/execution.zig").ReturnValue;
const call = @import("../vm/call.zig");
const metamethod = @import("../vm/metamethod.zig");
const ver = @import("../version.zig");
const launcher = @import("../launcher.zig");

pub const REPL = struct {
    allocator: std.mem.Allocator,
    rt: *Runtime,
    vm: *VM,
    prompt_key: *object.StringObject,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        // Create Runtime (owns GC, globals, registry)
        const rt = try Runtime.init(allocator);
        errdefer rt.deinit();

        // Create VM (thread state)
        const vm = try VM.init(rt);
        errdefer vm.deinit();

        // Pre-intern _PROMPT key (rooted via registry)
        const prompt_key = try rt.gc.allocString("_PROMPT");
        try vm.registry().set(TValue.fromString(prompt_key), TValue.fromString(prompt_key));

        return Self{
            .allocator = allocator,
            .rt = rt,
            .vm = vm,
            .prompt_key = prompt_key,
        };
    }

    pub fn deinit(self: *Self) void {
        self.vm.deinit();
        self.rt.deinit();
    }

    pub fn applyStartup(self: *Self, options: launcher.RunOptions) !void {
        self.vm.rt.warnings_enabled = options.warnings_enabled;
        try launcher.injectArg(self.vm.globals(), self.vm.gc(), options);
        try launcher.applyEnvironment(self.vm, self.allocator, options.ignore_environment);
        for (options.preload_modules) |module_spec| {
            try launcher.runPreloadModule(self.vm, module_spec);
        }
        for (options.exec_chunks) |chunk| {
            try launcher.executeInitChunk(self.vm, self.allocator, chunk, "=(command line)");
        }
    }

    /// Run the REPL loop
    pub fn run(self: *Self) !void {
        const stdin = std.fs.File.stdin();
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;

        // Print welcome banner
        try ver.printIdentity(stdout);

        var buf: [8192]u8 = undefined;
        var chunk = std.ArrayList(u8){};
        defer chunk.deinit(self.allocator);
        var continuation = false;
        const stdin_is_tty = std.posix.isatty(std.posix.STDIN_FILENO);

        while (true) {
            self.writePrompt(stdout, if (continuation) "_PROMPT2" else "_PROMPT", if (continuation) ">> " else "> ") catch break;

            const line = readLine(stdin, &buf) orelse {
                if (!stdin_is_tty) stdout.writeAll("\n") catch {};
                if (continuation) {
                    self.reportIncompleteChunk(chunk.items, stderr);
                }
                break;
            };

            if (!stdin_is_tty) {
                stdout.writeAll(line) catch break;
                stdout.writeAll("\n") catch break;
            }

            if (chunk.items.len == 0) {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;
            }

            try chunk.appendSlice(self.allocator, line);
            try chunk.append(self.allocator, '\n');

            const status = self.evalChunk(chunk.items, stderr);
            switch (status) {
                .incomplete => continuation = true,
                .handled => {
                    continuation = false;
                    chunk.clearRetainingCapacity();
                },
            }
        }
    }

    fn writePrompt(self: *Self, stdout: anytype, key_name: []const u8, default: []const u8) !void {
        const key_obj = if (std.mem.eql(u8, key_name, "_PROMPT")) self.prompt_key else try self.vm.gc().allocString(key_name);
        const prompt_val = self.vm.globals().get(TValue.fromString(key_obj)) orelse {
            try stdout.writeAll(default);
            return;
        };
        self.writePromptValue(stdout, prompt_val) catch try stdout.writeAll(default);
    }

    /// Read a line from stdin, returns null on EOF
    fn readLine(stdin: std.fs.File, buf: []u8) ?[]const u8 {
        var pos: usize = 0;
        while (pos < buf.len - 1) {
            var char_buf: [1]u8 = undefined;
            const bytes_read = stdin.read(&char_buf) catch return null;
            if (bytes_read == 0) {
                // EOF
                if (pos == 0) return null;
                break;
            }
            if (char_buf[0] == '\n') break;
            buf[pos] = char_buf[0];
            pos += 1;
        }
        return buf[0..pos];
    }

    const EvalStatus = enum { incomplete, handled };

    const CompileAttempt = union(enum) {
        ok: RawProto,
        incomplete,
        err: pipeline.CompileError,

        fn deinit(self: *CompileAttempt, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .ok => |raw| pipeline.freeRawProto(allocator, raw),
                .err => |*e| e.deinit(allocator),
                .incomplete => {},
            }
        }
    };

    fn evalChunk(self: *Self, input: []const u8, stderr: anytype) EvalStatus {
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        if (trimmed.len == 0) return .handled;

        const expr_source = self.buildExpressionSource(trimmed) catch null;
        defer if (expr_source) |source| self.allocator.free(source);
        var expr_attempt: ?CompileAttempt = null;
        defer if (expr_attempt) |*attempt| attempt.deinit(self.allocator);

        if (expr_source) |source| {
            expr_attempt = self.compileAttempt(source);
        }

        var stmt_attempt = self.compileAttempt(trimmed);
        defer stmt_attempt.deinit(self.allocator);

        if (expr_attempt) |*attempt| {
            switch (attempt.*) {
                .ok => |raw_proto| {
                    const result = self.executeRawProto(raw_proto, stderr) orelse return .handled;
                    self.printReturnValue(result, stderr);
                    return .handled;
                },
                .incomplete => return .incomplete,
                .err => {},
            }
        }

        switch (stmt_attempt) {
            .ok => |raw_proto| {
                const result = self.executeRawProto(raw_proto, stderr) orelse return .handled;
                self.printReturnValue(result, stderr);
                return .handled;
            },
            .incomplete => return .incomplete,
            .err => |e| {
                stderr.print("[string]:{d}: {s}\n", .{ e.line, e.message }) catch {};
                return .handled;
            },
        }
    }

    fn buildExpressionSource(self: *Self, input: []const u8) !?[]u8 {
        if (input.len == 0) return null;
        if (input[0] == '=') {
            return try std.fmt.allocPrint(self.allocator, "return {s}", .{input[1..]});
        }
        if (looksLikeStatement(input)) return null;
        return try std.fmt.allocPrint(self.allocator, "return {s}", .{input});
    }

    fn compileAttempt(self: *Self, source: []const u8) CompileAttempt {
        const compile_result = pipeline.compile(self.allocator, source, .{});
        switch (compile_result) {
            .ok => |raw_proto| return .{ .ok = raw_proto },
            .err => |e| {
                if (isIncompleteCompileError(e.message)) {
                    e.deinit(self.allocator);
                    return .incomplete;
                }
                return .{ .err = e };
            },
        }
    }

    fn executeRawProto(self: *Self, raw_proto: RawProto, stderr: anytype) ?ReturnValue {
        const proto = pipeline.materialize(&raw_proto, self.vm.gc(), self.allocator) catch {
            stderr.writeAll("error: failed to materialize chunk\n") catch {};
            return null;
        };
        const result = @import("../vm/mnemonics.zig").execute(self.vm, proto) catch {
            if (self.vm.lua_error_value.asString()) |err_str| {
                stderr.print("[string]:?: {s}\n", .{err_str.asSlice()}) catch {};
            } else {
                stderr.writeAll("error: runtime error\n") catch {};
            }
            return null;
        };

        return result;
    }

    fn reportIncompleteChunk(self: *Self, input: []const u8, stderr: anytype) void {
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        if (trimmed.len == 0) return;

        if (self.buildExpressionSource(trimmed) catch null) |expr_source| {
            defer self.allocator.free(expr_source);
            var expr_result = pipeline.compile(self.allocator, expr_source, .{});
            defer expr_result.deinit(self.allocator);
            if (expr_result == .err and !isIncompleteCompileError(expr_result.err.message)) {
                const e = expr_result.err;
                stderr.print("[string]:{d}: {s}\n", .{ e.line, e.message }) catch {};
                return;
            }
        }

        var stmt_result = pipeline.compile(self.allocator, trimmed, .{});
        defer stmt_result.deinit(self.allocator);
        if (stmt_result == .err) {
            const e = stmt_result.err;
            stderr.print("[string]:{d}: {s}\n", .{ e.line, e.message }) catch {};
        }
    }

    fn isIncompleteCompileError(message: []const u8) bool {
        return std.mem.indexOf(u8, message, "near <eof>") != null;
    }

    /// Check if input looks like a statement (not an expression)
    /// Used to avoid evaluating assignments like "x = 42" as expressions
    fn looksLikeStatement(input: []const u8) bool {
        // Skip whitespace
        var i: usize = 0;
        while (i < input.len and (input[i] == ' ' or input[i] == '\t')) : (i += 1) {}
        if (i >= input.len) return false;

        // Check for statement keywords
        const keywords = [_][]const u8{
            "local", "function", "if", "for", "while", "repeat", "do", "return", "break", "goto",
        };
        for (keywords) |kw| {
            if (input.len >= i + kw.len and std.mem.eql(u8, input[i..][0..kw.len], kw)) {
                // Check that it's a complete keyword (followed by space or end)
                if (i + kw.len >= input.len or !isAlphaNum(input[i + kw.len])) {
                    return true;
                }
            }
        }

        // Check for assignment: name followed by = (but not ==)
        // Also check for augmented assignment patterns like "a, b = ..."
        var j = i;
        while (j < input.len and (isAlphaNum(input[j]) or input[j] == '_' or input[j] == '.')) : (j += 1) {}
        // Skip whitespace after name
        while (j < input.len and (input[j] == ' ' or input[j] == '\t')) : (j += 1) {}
        // Check for = or , (multi-assignment)
        if (j < input.len) {
            if (input[j] == '=') {
                // Make sure it's not ==
                if (j + 1 >= input.len or input[j + 1] != '=') {
                    return true;
                }
            }
            if (input[j] == ',') {
                return true; // Multi-assignment like "a, b = ..."
            }
        }

        return false;
    }

    fn isAlphaNum(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
    }

    /// Print a result value
    fn printResult(stdout: anytype, val: TValue) void {
        if (val.isNil()) return; // Don't print nil results

        printValue(stdout, val) catch {};
        stdout.writeAll("\n") catch {};
    }

    /// Print a TValue
    fn printValue(stdout: anytype, val: TValue) !void {
        switch (val) {
            .nil => try stdout.writeAll("nil"),
            .boolean => |b| try stdout.writeAll(if (b) "true" else "false"),
            .integer => |i| try stdout.print("{d}", .{i}),
            .number => |n| try stdout.print("{d}", .{n}),
            .object => |obj| {
                switch (obj.type) {
                    .string => {
                        const str: *object.StringObject = @fieldParentPtr("header", obj);
                        try stdout.writeAll(str.asSlice());
                    },
                    .table => try stdout.print("table: 0x{x}", .{@intFromPtr(obj)}),
                    .closure => try stdout.print("function: 0x{x}", .{@intFromPtr(obj)}),
                    .native_closure => try stdout.print("function: 0x{x}", .{@intFromPtr(obj)}),
                    .userdata => try stdout.print("userdata: 0x{x}", .{@intFromPtr(obj)}),
                    .proto => try stdout.print("proto: 0x{x}", .{@intFromPtr(obj)}),
                    .upvalue => try stdout.print("upvalue: 0x{x}", .{@intFromPtr(obj)}),
                    .thread => try stdout.print("thread: 0x{x}", .{@intFromPtr(obj)}),
                    .file => {
                        const file_obj: *object.FileObject = @fieldParentPtr("header", obj);
                        if (file_obj.closed) {
                            try stdout.writeAll("file (closed)");
                        } else {
                            try stdout.print("file (0x{x})", .{@intFromPtr(obj)});
                        }
                    },
                }
            },
        }
    }

    fn printResultWithGlobalPrint(self: *Self, val: TValue, stderr: anytype) void {
        if (val.isNil()) return;

        const print_key = self.vm.gc().allocString("print") catch {
            stderr.writeAll("error calling 'print'\n") catch {};
            return;
        };
        const print_val = self.vm.globals().get(TValue.fromString(print_key)) orelse {
            stderr.writeAll("error calling 'print'\n") catch {};
            return;
        };

        _ = call.callValue(self.vm, print_val, &[_]TValue{val}) catch {
            stderr.writeAll("error calling 'print'\n") catch {};
            return;
        };
    }

    fn printReturnValue(self: *Self, result: ReturnValue, stderr: anytype) void {
        switch (result) {
            .none => {},
            .single => |val| self.printResultWithGlobalPrint(val, stderr),
            .multiple => |vals| {
                self.printResultsWithGlobalPrint(vals, stderr);
            },
        }
    }

    fn printResultsWithGlobalPrint(self: *Self, vals: []TValue, stderr: anytype) void {
        if (vals.len == 0) return;

        const print_key = self.vm.gc().allocString("print") catch {
            stderr.writeAll("error calling 'print'\n") catch {};
            return;
        };
        const print_val = self.vm.globals().get(TValue.fromString(print_key)) orelse {
            stderr.writeAll("error calling 'print'\n") catch {};
            return;
        };

        _ = call.callValue(self.vm, print_val, vals) catch {
            stderr.writeAll("error calling 'print'\n") catch {};
            return;
        };
    }

    fn writePromptValue(self: *Self, stdout: anytype, val: TValue) !void {
        switch (val) {
            .nil => try stdout.writeAll("nil"),
            .boolean => |b| try stdout.writeAll(if (b) "true" else "false"),
            .integer => |i| try stdout.print("{d}", .{i}),
            .number => |n| try stdout.print("{d}", .{n}),
            else => {
                if (metamethod.getMetamethod(val, .tostring, &self.vm.gc().mm_keys, &self.vm.gc().shared_mt)) |mm| {
                    if (!self.vm.pushTempRoot(mm)) return error.OutOfMemory;
                    if (!self.vm.pushTempRoot(val)) {
                        self.vm.popTempRoots(1);
                        return error.OutOfMemory;
                    }
                    defer self.vm.popTempRoots(2);

                    const result = try call.callValue(self.vm, mm, &[_]TValue{val});
                    return self.writePromptValue(stdout, result);
                }

                try printValue(stdout, val);
            },
        }
    }
};
