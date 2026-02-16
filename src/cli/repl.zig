//! REPL - Read-Eval-Print Loop
//!
//! Interactive Lua interpreter for Moonquakes.
//! Maintains a persistent VM state across inputs.

const std = @import("std");
const VM = @import("../vm/vm.zig").VM;
const GC = @import("../runtime/gc/gc.zig").GC;
const TValue = @import("../runtime/value.zig").TValue;
const object = @import("../runtime/gc/object.zig");
const pipeline = @import("../compiler/pipeline.zig");
const call = @import("../vm/call.zig");
const ver = @import("../version.zig");

pub const REPL = struct {
    allocator: std.mem.Allocator,
    gc: *GC,
    vm: *VM,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        // GC on heap - stable address for VM reference
        const gc = try allocator.create(GC);
        errdefer allocator.destroy(gc);
        gc.* = GC.init(allocator);
        errdefer gc.deinit();
        try gc.initMetamethodKeys();

        const vm = try allocator.create(VM);
        errdefer allocator.destroy(vm);
        try vm.init(gc);

        return Self{
            .allocator = allocator,
            .gc = gc,
            .vm = vm,
        };
    }

    pub fn deinit(self: *Self) void {
        self.vm.deinit();
        self.allocator.destroy(self.vm);
        self.gc.deinit();
        self.allocator.destroy(self.gc);
    }

    /// Run the REPL loop
    pub fn run(self: *Self) !void {
        const stdin = std.fs.File.stdin();
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;

        // Print welcome banner
        try ver.printIdentity(stdout);

        var buf: [8192]u8 = undefined;

        while (true) {
            // Get prompt (check _PROMPT global, default "> ")
            const prompt = self.getPrompt() orelse "> ";
            stdout.writeAll(prompt) catch break;

            // Read line from stdin
            const line = readLine(stdin, &buf) orelse break;

            // Skip empty lines
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            // Determine if input looks like an assignment or statement
            // Assignments and certain statements should not try as expression
            if (looksLikeStatement(trimmed)) {
                // Execute as statement directly
                _ = self.tryStatement(trimmed);
            } else {
                // Try as expression first (to print return values)
                if (self.tryExpression(trimmed)) |result| {
                    printResult(stdout, result);
                } else {
                    // Not a valid expression, try as statement
                    _ = self.tryStatement(trimmed);
                }
            }
        }
    }

    /// Get prompt from _PROMPT global or return null for default
    fn getPrompt(self: *Self) ?[]const u8 {
        const prompt_key = self.gc.allocString("_PROMPT") catch return null;
        const prompt_val = self.vm.globals.get(TValue.fromString(prompt_key)) orelse return null;
        if (prompt_val.asString()) |str| {
            return str.asSlice();
        }
        return null;
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

    /// Try to evaluate input as expression (prepend "return ")
    fn tryExpression(self: *Self, input: []const u8) ?TValue {
        // Build "return <input>"
        var expr_buf: [8192]u8 = undefined;
        const expr = std.fmt.bufPrint(&expr_buf, "return {s}", .{input}) catch return null;

        // Try to compile
        const compile_result = pipeline.compile(self.allocator, expr, .{});
        switch (compile_result) {
            .err => |e| {
                e.deinit(self.allocator);
                return null;
            },
            .ok => {},
        }
        const raw_proto = compile_result.ok;
        defer pipeline.freeRawProto(self.allocator, raw_proto);

        // Materialize and execute
        self.gc.inhibitGC();
        const proto = pipeline.materialize(&raw_proto, self.gc, self.allocator) catch {
            self.gc.allowGC();
            return null;
        };

        const closure = self.gc.allocClosure(proto) catch {
            self.gc.allowGC();
            return null;
        };
        self.gc.allowGC();

        // Execute
        const func_val = TValue.fromClosure(closure);
        const result = call.callValue(self.vm, func_val, &[_]TValue{}) catch return null;

        return result;
    }

    /// Try to execute input as statement.
    /// Returns true if executed, false if compile failed (should try as expression).
    /// Returns null on runtime error.
    fn tryStatement(self: *Self, input: []const u8) ?bool {
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;

        // Compile
        const compile_result = pipeline.compile(self.allocator, input, .{});
        switch (compile_result) {
            .err => |e| {
                e.deinit(self.allocator);
                return false; // Compile failed, caller should try as expression
            },
            .ok => {},
        }
        const raw_proto = compile_result.ok;
        defer pipeline.freeRawProto(self.allocator, raw_proto);

        // Materialize and execute
        self.gc.inhibitGC();
        const proto = pipeline.materialize(&raw_proto, self.gc, self.allocator) catch {
            self.gc.allowGC();
            stderr.writeAll("error: failed to materialize chunk\n") catch {};
            return null;
        };

        const closure = self.gc.allocClosure(proto) catch {
            self.gc.allowGC();
            stderr.writeAll("error: failed to create closure\n") catch {};
            return null;
        };
        self.gc.allowGC();

        // Execute
        const func_val = TValue.fromClosure(closure);
        _ = call.callValue(self.vm, func_val, &[_]TValue{}) catch {
            stderr.writeAll("error: runtime error\n") catch {};
            return null;
        };

        return true;
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
                }
            },
        }
    }
};
