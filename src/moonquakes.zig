const std = @import("std");
const TValue = @import("runtime/value.zig").TValue;
const proto_mod = @import("compiler/proto.zig");
const Proto = proto_mod.Proto;
const RawProto = proto_mod.RawProto;
const VM = @import("vm/vm.zig").VM;
const lexer = @import("compiler/lexer.zig");
const parser = @import("compiler/parser.zig");
const materialize = @import("compiler/materialize.zig").materialize;
const ErrorHandler = @import("vm/error.zig");

/// Owned value that doesn't depend on VM/GC lifetime.
/// Strings are copied and owned by the caller.
pub const OwnedValue = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    number: f64,
    string: []u8,

    pub fn deinit(self: *OwnedValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            else => {},
        }
    }

    pub fn format(self: OwnedValue, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .nil => try writer.writeAll("nil"),
            .boolean => |b| try writer.print("{}", .{b}),
            .integer => |i| try writer.print("{}", .{i}),
            .number => |n| try writer.print("{d}", .{n}),
            .string => |s| try writer.print("{s}", .{s}),
        }
    }
};

/// Return value from Moonquakes execution.
/// Owns all GC-managed data (strings copied out).
pub const OwnedReturnValue = union(enum) {
    none,
    single: OwnedValue,

    pub fn deinit(self: *OwnedReturnValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .single => |*v| v.deinit(allocator),
            .none => {},
        }
    }
};

/// This project is a clean-room implementation inspired by
/// the Lua 5.4 language specification.
/// It does not include or depend on the original Lua source code.
///
/// Use it freely. Embed it freely. Learn from it freely.
///
/// Copyright (c) 2025 KEI SAWAMURA. Licensed under the MIT License.
///
pub const Moonquakes = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Moonquakes {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Moonquakes) void {
        _ = self;
    }

    /// Compile Lua source code into bytecode
    ///
    /// NOTE:
    /// Proto returned here borrows memory from ProtoBuilder.
    /// Lifetime is NOT independent. Do not use this API yet.
    ///
    /// Ownership model for Proto will be decided after:
    /// - CALL / RETURN semantics are finalized
    /// - closure and upvalue representation is defined
    /// - GC root ownership is clarified
    ///
    /// DEPRECATED: Use compileWithGC instead for proper GC integration
    pub fn compile(self: *Moonquakes, source: []const u8) !Proto {
        // Create a temporary VM just to get access to GC
        var vm = try VM.init(self.allocator);
        defer vm.deinit();

        return try self.compileWithGC(source, &vm.gc);
    }

    /// Compile Lua source code with GC for string allocation
    fn compileWithGC(self: *Moonquakes, source: []const u8, gc: *@import("runtime/gc/gc.zig").GC) !Proto {
        var lx = lexer.Lexer.init(source);
        var builder = parser.ProtoBuilder.init(self.allocator, gc);
        defer builder.deinit();

        var p = parser.Parser.init(&lx, &builder);
        defer p.deinit();
        try p.parseChunk();

        return try builder.toProto(self.allocator);
    }

    /// Execute compiled bytecode
    pub fn run(self: *Moonquakes, proto: *const Proto) !VM.ReturnValue {
        var vm = try VM.init(self.allocator);
        defer vm.deinit();

        // Execute with Sugar Layer error translation
        return vm.execute(proto) catch |err| {
            // Translate VM errors to user-friendly messages using Sugar Layer
            const translated_error = self.translateVMError(err) catch |trans_err| switch (trans_err) {
                error.OutOfMemory => "out of memory during error translation",
            };
            defer if (translated_error.len > 0) self.allocator.free(translated_error);

            // Print the user-friendly error message
            const stderr = std.io.getStdErr().writer();
            stderr.print("{s}\n", .{translated_error}) catch {};

            // Propagate the original error for proper control flow
            return err;
        };
    }

    /// Compile and execute Lua source in one step.
    /// Returns owned values that don't depend on VM lifetime.
    pub fn runSource(self: *Moonquakes, source: []const u8) !OwnedReturnValue {
        // Phase 1: Compile to RawProto (no GC needed)
        var lx = lexer.Lexer.init(source);
        var builder = parser.ProtoBuilder.init(self.allocator);
        defer builder.deinit();

        var p = parser.Parser.init(&lx, &builder);
        defer p.deinit();
        try p.parseChunk();

        const raw_proto = try builder.toRawProto(self.allocator);
        defer freeRawProto(self.allocator, raw_proto);

        // Phase 2: Create VM and materialize constants
        var vm = try VM.init(self.allocator);
        defer vm.deinit();

        const proto = try materialize(&raw_proto, &vm.gc, self.allocator);
        defer freeProto(self.allocator, proto);

        // Phase 3: Execute
        const result = vm.execute(proto) catch |err| {
            const translated_error = self.translateVMError(err) catch |trans_err| switch (trans_err) {
                error.OutOfMemory => "out of memory during error translation",
            };
            defer if (translated_error.len > 0) self.allocator.free(translated_error);

            const stderr = std.io.getStdErr().writer();
            stderr.print("{s}\n", .{translated_error}) catch {};

            return err;
        };

        // Convert to owned values before VM is destroyed
        return self.toOwnedReturnValue(result);
    }

    fn freeRawProto(allocator: std.mem.Allocator, raw: RawProto) void {
        allocator.free(raw.code);
        allocator.free(raw.booleans);
        allocator.free(raw.integers);
        allocator.free(raw.numbers);
        for (raw.strings) |s| {
            allocator.free(s);
        }
        allocator.free(raw.strings);
        allocator.free(raw.native_ids);
        allocator.free(raw.const_refs);
        for (raw.protos) |nested| {
            // Recursively free contents, then destroy the struct itself
            freeRawProto(allocator, nested.*);
            allocator.destroy(@constCast(nested));
        }
        allocator.free(raw.protos);
    }

    fn freeProto(allocator: std.mem.Allocator, proto: *Proto) void {
        allocator.free(proto.k);
        allocator.free(proto.code);
        allocator.free(proto.upvalues);
        for (proto.protos) |nested| {
            freeProto(allocator, @constCast(nested));
        }
        allocator.free(proto.protos);
        allocator.destroy(proto);
    }

    /// Load and execute Lua file.
    /// Returns owned values that don't depend on VM lifetime.
    pub fn loadFile(self: *Moonquakes, file_path: []const u8) !OwnedReturnValue {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const source = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(source);

        _ = try file.readAll(source);
        return try self.runSource(source);
    }

    /// Convert VM ReturnValue to OwnedReturnValue (copies GC-managed data)
    fn toOwnedReturnValue(self: *Moonquakes, result: VM.ReturnValue) !OwnedReturnValue {
        return switch (result) {
            .none => .none,
            .single => |val| .{ .single = try self.toOwnedValue(val) },
            .multiple => .none, // TODO: support multiple return values
        };
    }

    /// Convert TValue to OwnedValue (copies strings)
    fn toOwnedValue(self: *Moonquakes, val: TValue) !OwnedValue {
        return switch (val) {
            .nil => .nil,
            .boolean => |b| .{ .boolean = b },
            .integer => |i| .{ .integer = i },
            .number => |n| .{ .number = n },
            .object => |obj| switch (obj.type) {
                .string => .{ .string = try self.allocator.dupe(u8, val.asString().?.asSlice()) },
                .table => .nil, // TODO: serialize table
                .closure, .native_closure => .nil, // TODO: represent closure
                .upvalue, .userdata => .nil,
            },
        };
    }

    /// Debug: dump all tokens from source
    pub fn dumpTokens(_: *Moonquakes, source: []const u8) void {
        lexer.dumpAllTokens(source);
    }

    /// Debug: dump bytecode instructions
    pub fn dumpProto(_: *Moonquakes, proto: *const Proto) !void {
        const stdout = std.io.getStdOut().writer();

        try stdout.print("Generated bytecode:\n", .{});
        for (proto.code, 0..) |instr, i| {
            try stdout.print("{d}: {}\n", .{ i, instr });
        }

        try stdout.print("Constants:\n", .{});
        for (proto.k, 0..) |constant, i| {
            try stdout.print("K{d}: {}\n", .{ i, constant });
        }
    }

    /// Debug: comprehensive analysis of source code
    pub fn analyze(self: *Moonquakes, source: []const u8) !void {
        const stdout = std.io.getStdOut().writer();

        try stdout.print("=== Moonquakes Analysis ===\n", .{});
        try stdout.print("Source: {s}\n\n", .{source});

        try stdout.print("Tokens:\n", .{});
        self.dumpTokens(source);
        try stdout.print("\n", .{});

        const proto = try self.compile(source);
        defer self.allocator.free(proto.code);
        defer self.allocator.free(proto.k);

        try self.dumpProto(&proto);
        try stdout.print("\n", .{});

        const result = try self.run(&proto);
        try stdout.print("Execution result: ", .{});
        switch (result) {
            .none => try stdout.print("nil\n", .{}),
            .single => |val| try stdout.print("{}\n", .{val}),
            .multiple => |vals| {
                for (vals, 0..) |val, i| {
                    if (i > 0) try stdout.print(", ", .{});
                    try stdout.print("{}", .{val});
                }
                try stdout.print("\n", .{});
            },
        }
    }

    /// Sugar Layer: Translate VM errors to user-friendly messages
    fn translateVMError(self: *Moonquakes, vm_error: anyerror) ![]const u8 {
        // Check if this is a VM internal error that should be translated
        const vm_error_typed = switch (vm_error) {
            error.PcOutOfRange => ErrorHandler.VMError.PcOutOfRange,
            error.CallStackOverflow => ErrorHandler.VMError.CallStackOverflow,
            error.ArithmeticError => ErrorHandler.VMError.ArithmeticError,
            error.OrderComparisonError => ErrorHandler.VMError.OrderComparisonError,
            error.InvalidForLoopInit => ErrorHandler.VMError.InvalidForLoopInit,
            error.InvalidForLoopStep => ErrorHandler.VMError.InvalidForLoopStep,
            error.InvalidForLoopLimit => ErrorHandler.VMError.InvalidForLoopLimit,
            error.NotAFunction => ErrorHandler.VMError.NotAFunction,
            error.InvalidTableKey => ErrorHandler.VMError.InvalidTableKey,
            error.InvalidTableOperation => ErrorHandler.VMError.InvalidTableOperation,
            error.UnknownOpcode => ErrorHandler.VMError.UnknownOpcode,
            error.VariableReturnNotImplemented => ErrorHandler.VMError.VariableReturnNotImplemented,
            else => {
                // For non-VM errors, return a generic message
                return try self.allocator.dupe(u8, "runtime error occurred");
            },
        };

        // Use Sugar Layer to translate the error
        return ErrorHandler.reportError(vm_error_typed, self.allocator, null);
    }
};
