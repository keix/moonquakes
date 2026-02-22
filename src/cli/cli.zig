//! Command-line Interface
//!
//! CLI entry point for Moonquakes interpreter.
//! Uses launcher directly for script execution with arg support.
//! Starts REPL when no arguments are provided.

const std = @import("std");
const launcher = @import("../launcher.zig");
const ver = @import("../version.zig");
const REPL = @import("repl.zig").REPL;

pub const version = ver.version;

pub const CLI = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CLI {
        return .{ .allocator = allocator };
    }

    pub fn run(self: *CLI, args: []const [:0]const u8) !void {
        if (args.len < 2) {
            // No arguments - start REPL
            var repl = try REPL.init(self.allocator);
            defer repl.deinit();
            try repl.run();
            return;
        }

        const arg = args[1];
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try self.printVersion();
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try self.printUsage();
            return;
        }

        const file_path = arg;

        // Collect script arguments (args after the script file)
        // args[0] = interpreter, args[1] = script, args[2..] = script args
        const script_args: []const []const u8 = if (args.len > 2)
            @as([]const []const u8, @ptrCast(args[2..]))
        else
            &.{};

        // Use launcher for execution with arg support
        var result = launcher.runFile(self.allocator, file_path, .{
            .script_name = file_path,
            .args = script_args,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                var stderr_writer = std.fs.File.stderr().writer(&.{});
                const stderr = &stderr_writer.interface;
                try stderr.print("Error: file not found: {s}\n", .{file_path});
                std.process.exit(1);
            },
            error.LuaException => {
                // Error message already printed by launcher
                std.process.exit(1);
            },
            error.CompileFailed => {
                // Error message already printed by launcher
                std.process.exit(1);
            },
            else => return err,
        };
        result.deinit(self.allocator);
        // Lua 5.4 spec: return values are not printed unless explicitly via print()
    }

    fn printVersion(_: *CLI) !void {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try ver.printIdentity(stdout);
    }

    fn printUsage(_: *CLI) !void {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try stdout.writeAll(
            \\Usage: moonquakes [options] [script [args...]]
            \\
            \\Options:
            \\  -v, --version  Print version
            \\  -h, --help     Print this help
            \\
            \\If no script is given, start interactive mode (REPL).
            \\
            \\Example:
            \\  moonquakes              # Start REPL
            \\  moonquakes script.lua   # Run script
            \\
        );
    }
};
