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
        var interactive = false;
        var warnings_enabled = false;

        if (args.len == 2 and (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v"))) {
            try self.printVersion();
            return;
        }
        if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
            try self.printUsage();
            return;
        }

        var pre_script_tokens = std.ArrayList([]const u8){};
        defer pre_script_tokens.deinit(self.allocator);
        var preload_modules = std.ArrayList([]const u8){};
        defer preload_modules.deinit(self.allocator);
        var exec_chunks = std.ArrayList([]const u8){};
        defer exec_chunks.deinit(self.allocator);

        var script_name: ?[]const u8 = null;

        while (arg_index < args.len) {
            const opt = args[arg_index];
            if (std.mem.eql(u8, opt, "--")) {
                try pre_script_tokens.append(self.allocator, opt);
                arg_index += 1;
                break;
            }
            if (std.mem.eql(u8, opt, "-E")) {
                ignore_environment = true;
                try pre_script_tokens.append(self.allocator, opt);
                arg_index += 1;
                continue;
            }
            if (std.mem.eql(u8, opt, "-i")) {
                interactive = true;
                try pre_script_tokens.append(self.allocator, opt);
                arg_index += 1;
                continue;
            }
            if (std.mem.eql(u8, opt, "-W") or (opt.len > 2 and opt[0] == '-' and opt[1] == 'W')) {
                warnings_enabled = true;
                try pre_script_tokens.append(self.allocator, opt);
                arg_index += 1;
                continue;
            }
            if (std.mem.eql(u8, opt, "-e")) {
                if (arg_index + 1 >= args.len) {
                    var stderr_writer = std.fs.File.stderr().writer(&.{});
                    const stderr = &stderr_writer.interface;
                    try stderr.print("'-e' needs argument\n", .{});
                    std.process.exit(1);
                }
                try pre_script_tokens.append(self.allocator, opt);
                try exec_chunks.append(self.allocator, args[arg_index + 1]);
                arg_index += 2;
                continue;
            }
            if (opt.len > 2 and opt[0] == '-' and opt[1] == 'e') {
                try pre_script_tokens.append(self.allocator, opt);
                try exec_chunks.append(self.allocator, opt[2..]);
                arg_index += 1;
                continue;
            }
            if (std.mem.eql(u8, opt, "-l")) {
                if (arg_index + 1 >= args.len) {
                    var stderr_writer = std.fs.File.stderr().writer(&.{});
                    const stderr = &stderr_writer.interface;
                    try stderr.print("'-l' needs argument\n", .{});
                    std.process.exit(1);
                }
                try pre_script_tokens.append(self.allocator, opt);
                try preload_modules.append(self.allocator, args[arg_index + 1]);
                arg_index += 2;
                continue;
            }
            if (opt.len > 2 and opt[0] == '-' and opt[1] == 'l') {
                try pre_script_tokens.append(self.allocator, opt);
                try preload_modules.append(self.allocator, opt[2..]);
                arg_index += 1;
                continue;
            }
            if (std.mem.eql(u8, opt, "-")) {
                script_name = "-";
                arg_index += 1;
                break;
            }
            if (opt.len > 0 and opt[0] == '-') {
                var stderr_writer = std.fs.File.stderr().writer(&.{});
                const stderr = &stderr_writer.interface;
                try stderr.print("unrecognized option '{s}'\n", .{opt});
                std.process.exit(1);
            }
            script_name = opt;
            arg_index += 1;
            break;
        }

        if (script_name == null and arg_index < args.len) {
            script_name = args[arg_index];
            arg_index += 1;
        }

        const script_args: []const []const u8 = if (args.len > arg_index)
            @as([]const []const u8, @ptrCast(args[arg_index..]))
        else
            &.{};

        var pre_script_args = std.ArrayList([]const u8){};
        defer pre_script_args.deinit(self.allocator);
        try pre_script_args.append(self.allocator, args[0]);
        for (pre_script_tokens.items) |tok| {
            try pre_script_args.append(self.allocator, tok);
        }

        if (script_name) |script| {
            if (std.mem.eql(u8, script, "-")) {
                const stdin = std.fs.File.stdin();
                const source = try stdin.readToEndAlloc(self.allocator, std.math.maxInt(usize));
                defer self.allocator.free(source);
                var result = launcher.run(self.allocator, source, .{
                    .exec_name = args[0],
                    .script_name = "-",
                    .args = script_args,
                    .ignore_environment = ignore_environment,
                    .warnings_enabled = warnings_enabled,
                    .preload_modules = preload_modules.items,
                    .exec_chunks = exec_chunks.items,
                    .pre_script_args = pre_script_args.items,
                }) catch |err| switch (err) {
                    error.LuaException => std.process.exit(1),
                    error.CompileFailed => std.process.exit(1),
                    else => return err,
                };
                result.deinit(self.allocator);
                return;
            }

            var result = launcher.runFile(self.allocator, script, .{
                .exec_name = args[0],
                .script_name = script,
                .args = script_args,
                .ignore_environment = ignore_environment,
                .warnings_enabled = warnings_enabled,
                .preload_modules = preload_modules.items,
                .exec_chunks = exec_chunks.items,
                .pre_script_args = pre_script_args.items,
            }) catch |err| switch (err) {
                error.FileNotFound => {
                    var stderr_writer = std.fs.File.stderr().writer(&.{});
                    const stderr = &stderr_writer.interface;
                    try stderr.print("Error: file not found: {s}\n", .{script});
                    std.process.exit(1);
                },
                error.LuaException => std.process.exit(1),
                error.CompileFailed => std.process.exit(1),
                else => return err,
            };
            result.deinit(self.allocator);
            return;
        }

        // No script: `-e`/`-l` alone should execute and exit, not block on stdin.
        if (!interactive and (exec_chunks.items.len > 0 or preload_modules.items.len > 0)) {
            var result = launcher.run(self.allocator, "", .{
                .exec_name = args[0],
                .script_name = "=(command line)",
                .args = &.{},
                .ignore_environment = ignore_environment,
                .warnings_enabled = warnings_enabled,
                .preload_modules = preload_modules.items,
                .exec_chunks = exec_chunks.items,
                .pre_script_args = pre_script_args.items,
            }) catch |err| switch (err) {
                error.LuaException => std.process.exit(1),
                error.CompileFailed => std.process.exit(1),
                else => return err,
            };
            result.deinit(self.allocator);
            return;
        }

        // No script: REPL or stdin chunk.
        if (interactive or std.posix.isatty(std.posix.STDIN_FILENO)) {
            var repl = try REPL.init(self.allocator);
            defer repl.deinit();
            try repl.applyStartup(.{
                .exec_name = args[0],
                .script_name = "=stdin",
                .args = &.{},
                .ignore_environment = ignore_environment,
                .warnings_enabled = warnings_enabled,
                .preload_modules = preload_modules.items,
                .exec_chunks = exec_chunks.items,
                .pre_script_args = pre_script_args.items,
            });
            try repl.run();
            return;
        }

        const stdin = std.fs.File.stdin();
        const source = try stdin.readToEndAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(source);
        var result = launcher.run(self.allocator, source, .{
            .exec_name = args[0],
            .script_name = "=stdin",
            .args = &.{},
            .ignore_environment = ignore_environment,
            .warnings_enabled = warnings_enabled,
            .preload_modules = preload_modules.items,
            .exec_chunks = exec_chunks.items,
            .pre_script_args = pre_script_args.items,
        }) catch |err| switch (err) {
            error.LuaException => std.process.exit(1),
            error.CompileFailed => std.process.exit(1),
            else => return err,
        };
        result.deinit(self.allocator);
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
