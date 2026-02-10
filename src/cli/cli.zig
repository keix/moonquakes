//! Command-line Interface
//!
//! CLI entry point for Moonquakes interpreter.
//! Uses launcher directly for script execution with arg support.

const std = @import("std");
const launcher = @import("../launcher.zig");
const ver = @import("../version.zig");

pub const version = ver.version;

pub const CLI = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CLI {
        return .{ .allocator = allocator };
    }

    pub fn run(self: *CLI, args: []const [:0]const u8) !void {
        if (args.len < 2) {
            try self.printUsage();
            return;
        }

        const arg = args[1];
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try self.printVersion();
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
                return;
            },
            else => return err,
        };
        result.deinit(self.allocator);
        // Lua 5.4 spec: return values are not printed unless explicitly via print()
    }

    fn printVersion(_: *CLI) !void {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try stdout.print("Moonquakes {s} Copyright (C) 2025 Kei Sawamura.\n", .{version});
    }

    fn printUsage(_: *CLI) !void {
        var stdout_writer = std.fs.File.stdout().writer(&.{});
        const stdout = &stdout_writer.interface;
        try stdout.writeAll(
            \\Usage: moonquakes [options] <lua_file> [script_args...]
            \\
            \\Options:
            \\  -v, --version  Print version
            \\
            \\Example:
            \\  moonquakes script.lua arg1 arg2
            \\
        );
    }
};
