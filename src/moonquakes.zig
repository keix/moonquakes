//! Moonquakes - A Clean-Room Lua 5.4 Implementation
//!
//! This project is a clean-room implementation inspired by
//! the Lua 5.4 language specification.
//! It does not include or depend on the original Lua source code.
//!
//! Use it freely. Embed it freely. Learn from it freely.
//!
//! Copyright (c) 2025 KEI SAWAMURA. Licensed under the MIT License.

const std = @import("std");

// Re-export public API
pub const cli = @import("cli/cli.zig");
pub const CLI = cli.CLI;

const ver = @import("version.zig");
pub const version = ver.version;

pub const pipeline = @import("compiler/pipeline.zig");

const owned = @import("runtime/owned.zig");
pub const OwnedReturnValue = owned.OwnedReturnValue;
pub const OwnedValue = owned.OwnedValue;

// Launcher for execution context setup (arg injection, etc.)
pub const launcher = @import("launcher.zig");
pub const RunOptions = launcher.RunOptions;

// Core types for embedding
pub const VM = @import("vm/vm.zig").VM;
pub const Runtime = @import("runtime/runtime.zig").Runtime;
pub const GC = @import("runtime/gc/gc.zig").GC;
pub const Mnemonics = @import("vm/mnemonics.zig");
pub const ReturnValue = @import("vm/execution.zig").ReturnValue;
pub const TValue = @import("runtime/value.zig").TValue;
pub const Proto = @import("compiler/proto.zig").Proto;

const ErrorHandler = @import("vm/error.zig");

/// High-level API for embedding Moonquakes
/// Pure execution without runtime conventions (no arg, etc.)
/// For script execution with arg support, use launcher.run() instead.
pub const Moonquakes = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Moonquakes {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Moonquakes) void {
        _ = self;
    }

    /// Execute compiled bytecode with a fresh VM.
    /// TODO: migrate to Runtime-based initialization (Runtime owns GC/globals/registry).
    pub fn run(self: *Moonquakes, proto: *const Proto) !ReturnValue {
        // Create GC (global state) and VM (thread state).
        // TODO: replace with Runtime.init + VM.init(rt).
        var gc = GC.init(self.allocator);
        defer gc.deinit();
        try gc.initMetamethodKeys();

        var vm: VM = undefined;
        try vm.init(&gc);
        defer vm.deinit();

        return Mnemonics.execute(&vm, proto) catch |err| {
            try self.printTranslatedError(err);
            return err;
        };
    }

    /// Compile and execute Lua source in one step.
    /// Returns owned values that don't depend on VM lifetime.
    /// Note: Does not set up `arg` global. Use launcher.run() for that.
    pub fn runSource(self: *Moonquakes, source: []const u8) !OwnedReturnValue {
        // Phase 1: Compile to RawProto (no GC needed)
        const compile_result = pipeline.compile(self.allocator, source, .{});
        switch (compile_result) {
            .err => |e| {
                defer e.deinit(self.allocator);
                try self.printCompileError(e);
                return error.CompileFailed;
            },
            .ok => {},
        }
        const raw_proto = compile_result.ok;
        defer pipeline.freeRawProto(self.allocator, raw_proto);

        // Phase 2: Create GC and VM, then materialize constants.
        // TODO: replace with Runtime.init + VM.init(rt).
        var gc = GC.init(self.allocator);
        defer gc.deinit();
        try gc.initMetamethodKeys();

        var vm: VM = undefined;
        try vm.init(&gc);
        defer vm.deinit();

        const proto = try pipeline.materialize(&raw_proto, vm.gc(), self.allocator);
        // Note: ProtoObject is GC-managed, no manual free needed

        // Phase 3: Execute
        const result = Mnemonics.execute(&vm, proto) catch |err| {
            try self.printTranslatedError(err);
            return err;
        };

        // Convert to owned values before VM is destroyed
        return owned.toOwnedReturnValue(self.allocator, result);
    }

    /// Load and execute Lua file.
    /// Returns owned values that don't depend on VM lifetime.
    /// Note: Does not set up `arg` global. Use launcher.runFile() for that.
    pub fn loadFile(self: *Moonquakes, file_path: []const u8) !OwnedReturnValue {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const source = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(source);

        _ = try file.readAll(source);
        return try self.runSource(source);
    }

    /// Debug: dump all tokens from source
    pub fn dumpTokens(_: *Moonquakes, source: []const u8) void {
        const lexer = @import("compiler/lexer.zig");
        lexer.dumpAllTokens(source);
    }

    /// Debug: dump bytecode instructions
    pub fn dumpProto(_: *Moonquakes, proto: *const Proto) !void {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;

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
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;

        try stdout.print("=== Moonquakes Analysis ===\n", .{});
        try stdout.print("Source: {s}\n\n", .{source});

        try stdout.print("Tokens:\n", .{});
        self.dumpTokens(source);
        try stdout.print("\n", .{});

        // Compile
        const compile_result = pipeline.compile(self.allocator, source, .{});
        switch (compile_result) {
            .err => |e| {
                defer e.deinit(self.allocator);
                try stdout.print("Compile error at line {d}: {s}\n", .{ e.line, e.message });
                return error.CompileFailed;
            },
            .ok => {},
        }
        const raw_proto = compile_result.ok;
        defer pipeline.freeRawProto(self.allocator, raw_proto);

        // TODO: replace with Runtime.init + VM.init(rt).
        var gc = GC.init(self.allocator);
        defer gc.deinit();
        try gc.initMetamethodKeys();

        var vm: VM = undefined;
        try vm.init(&gc);
        defer vm.deinit();

        const proto = try pipeline.materialize(&raw_proto, vm.gc(), self.allocator);
        // Note: ProtoObject is GC-managed, no manual free needed

        try self.dumpProto(proto);
        try stdout.print("\n", .{});

        const result = try Mnemonics.execute(&vm, proto);
        try stdout.print("Execution result: ", .{});
        switch (result) {
            .none => try stdout.print("nil\n", .{}),
            .single => |val| try stdout.print("{}\n", .{val}),
            .multiple => |vals| {
                for (vals, 0..) |val, i| {
                    if (i > 0) try stdout.print(", ", .{});
                    try stdout.print("{any}", .{val});
                }
                try stdout.print("\n", .{});
            },
        }
    }

    /// Translate VM error and print to stderr
    fn printTranslatedError(self: *Moonquakes, err: anyerror) !void {
        const translated_error = translateVMError(self.allocator, err) catch |trans_err| switch (trans_err) {
            error.OutOfMemory => "out of memory during error translation",
        };
        defer if (translated_error.len > 0) self.allocator.free(translated_error);

        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        stderr.print("{s}\n", .{translated_error}) catch {};
    }

    /// Print compile error to stderr
    fn printCompileError(self: *Moonquakes, e: pipeline.CompileError) !void {
        _ = self;
        var stderr_writer = std.fs.File.stderr().writer(&.{});
        const stderr = &stderr_writer.interface;
        stderr.print("[string]:{d}: {s}\n", .{ e.line, e.message }) catch {};
    }
};

/// Sugar Layer: Translate VM errors to user-friendly messages
fn translateVMError(allocator: std.mem.Allocator, vm_error: anyerror) ![]const u8 {
    const vm_error_typed = switch (vm_error) {
        error.PcOutOfRange => ErrorHandler.VMError.PcOutOfRange,
        error.CallStackOverflow => ErrorHandler.VMError.CallStackOverflow,
        error.ArithmeticError => ErrorHandler.VMError.ArithmeticError,
        error.DivideByZero => ErrorHandler.VMError.DivideByZero,
        error.ModuloByZero => ErrorHandler.VMError.ModuloByZero,
        error.IntegerRepresentation => ErrorHandler.VMError.IntegerRepresentation,
        error.OrderComparisonError => ErrorHandler.VMError.OrderComparisonError,
        error.InvalidForLoopInit => ErrorHandler.VMError.InvalidForLoopInit,
        error.InvalidForLoopStep => ErrorHandler.VMError.InvalidForLoopStep,
        error.InvalidForLoopLimit => ErrorHandler.VMError.InvalidForLoopLimit,
        error.NotAFunction => ErrorHandler.VMError.NotAFunction,
        error.InvalidTableKey => ErrorHandler.VMError.InvalidTableKey,
        error.InvalidTableOperation => ErrorHandler.VMError.InvalidTableOperation,
        error.ProtectedMetatable => ErrorHandler.VMError.ProtectedMetatable,
        error.UnknownOpcode => ErrorHandler.VMError.UnknownOpcode,
        error.VariableReturnNotImplemented => ErrorHandler.VMError.VariableReturnNotImplemented,
        else => {
            return try allocator.dupe(u8, "runtime error occurred");
        },
    };

    return ErrorHandler.reportError(vm_error_typed, allocator, null);
}
