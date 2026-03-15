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
        var arg_index: usize = 1;
        var ignore_environment = false;
        if (args.len > 1 and std.mem.eql(u8, args[1], "-E")) {
            ignore_environment = true;
            arg_index = 2;
        }

        if (args.len <= arg_index) {
            // No arguments:
            // - interactive stdin => REPL
            // - redirected stdin  => run stdin as a chunk
            if (std.posix.isatty(std.posix.STDIN_FILENO)) {
                var repl = try REPL.init(self.allocator);
                defer repl.deinit();
                try repl.run();
            } else {
                const stdin = std.fs.File.stdin();
                const source = try stdin.readToEndAlloc(self.allocator, std.math.maxInt(usize));
                defer self.allocator.free(source);

                var result = launcher.run(self.allocator, source, .{
                    .exec_name = args[0],
                    .script_name = "=stdin",
                    .args = &.{},
                    .ignore_environment = ignore_environment,
                }) catch |err| switch (err) {
                    error.LuaException => std.process.exit(1),
                    error.CompileFailed => std.process.exit(1),
                    else => return err,
                };
                result.deinit(self.allocator);
            }
            return;
        }

        const arg = args[arg_index];
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            try self.printVersion();
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try self.printUsage();
            return;
        }

        if (std.mem.eql(u8, arg, "-e")) {
            if (args.len <= arg_index + 1) {
                var stderr_writer = std.fs.File.stderr().writer(&.{});
                const stderr = &stderr_writer.interface;
                try stderr.print("Error: '-e' expects a chunk argument\n", .{});
                std.process.exit(1);
            }
            const chunk = args[arg_index + 1];
            const script_args: []const []const u8 = if (args.len > arg_index + 2)
                @as([]const []const u8, @ptrCast(args[arg_index + 2 ..]))
            else
                &.{};

            var result = launcher.run(self.allocator, chunk, .{
                .exec_name = args[0],
                .script_name = "(command line)",
                .args = script_args,
                .ignore_environment = ignore_environment,
            }) catch |err| switch (err) {
                error.LuaException => std.process.exit(1),
                error.CompileFailed => std.process.exit(1),
                else => return err,
            };
            result.deinit(self.allocator);
            return;
        }

        if (std.mem.eql(u8, arg, "-")) {
            const stdin = std.fs.File.stdin();
            const source = try stdin.readToEndAlloc(self.allocator, std.math.maxInt(usize));
            defer self.allocator.free(source);

            const script_args: []const []const u8 = if (args.len > arg_index + 1)
                @as([]const []const u8, @ptrCast(args[arg_index + 1 ..]))
            else
                &.{};

            var result = launcher.run(self.allocator, source, .{
                .exec_name = args[0],
                .script_name = "=stdin",
                .args = script_args,
                .ignore_environment = ignore_environment,
            }) catch |err| switch (err) {
                error.LuaException => std.process.exit(1),
                error.CompileFailed => std.process.exit(1),
                else => return err,
            };
            result.deinit(self.allocator);
            return;
        }

        var preload_modules = std.ArrayList([]const u8){};
        defer preload_modules.deinit(self.allocator);

        var script_index = arg_index;
        while (script_index < args.len) {
            const opt = args[script_index];
            if (std.mem.eql(u8, opt, "-l")) {
                if (script_index + 1 >= args.len) {
                    var stderr_writer = std.fs.File.stderr().writer(&.{});
                    const stderr = &stderr_writer.interface;
                    try stderr.print("Error: '-l' expects a module name\n", .{});
                    std.process.exit(1);
                }
                try preload_modules.append(self.allocator, args[script_index + 1]);
                script_index += 2;
                continue;
            }
            if (opt.len > 2 and opt[0] == '-' and opt[1] == 'l') {
                try preload_modules.append(self.allocator, opt[2..]);
                script_index += 1;
                continue;
            }
            break;
        }

        if (script_index >= args.len) {
            var stderr_writer = std.fs.File.stderr().writer(&.{});
            const stderr = &stderr_writer.interface;
            try stderr.print("Error: no script provided\n", .{});
            std.process.exit(1);
        }

        const file_path = args[script_index];

        // Collect script arguments (args after the script file)
        // args[0] = interpreter, args[1] = script, args[2..] = script args
        const script_args: []const []const u8 = if (args.len > script_index + 1)
            @as([]const []const u8, @ptrCast(args[script_index + 1 ..]))
        else
            &.{};

        // Use launcher for execution with arg support
        var result = launcher.runFile(self.allocator, file_path, .{
            .exec_name = args[0],
            .script_name = file_path,
            .args = script_args,
            .ignore_environment = ignore_environment,
            .preload_modules = preload_modules.items,
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
