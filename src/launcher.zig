//! Launcher - Execution Context Setup
//!
//! Prepares VM execution environment before running scripts.
//! Handles runtime-injected globals like `arg`, `_ENV`, etc.
//!
//! This is where "execution conventions" live, not language features.
//! Embedders can use this directly or build their own launcher.

const std = @import("std");
const Runtime = @import("runtime/runtime.zig").Runtime;
const VM = @import("vm/vm.zig").VM;
const GC = @import("runtime/gc/gc.zig").GC;
const TableObject = @import("runtime/gc/object.zig").TableObject;
const TValue = @import("runtime/value.zig").TValue;
const Mnemonics = @import("vm/mnemonics.zig");
const ReturnValue = @import("vm/execution.zig").ReturnValue;
const pipeline = @import("compiler/pipeline.zig");
const owned = @import("runtime/owned.zig");
pub const OwnedReturnValue = owned.OwnedReturnValue;

fn stripUtf8Bom(bytes: []const u8) []const u8 {
    if (bytes.len >= 3 and bytes[0] == 0xEF and bytes[1] == 0xBB and bytes[2] == 0xBF) {
        return bytes[3..];
    }
    return bytes;
}

fn stripInitialHashLine(bytes: []const u8, preserve_newline: bool) []const u8 {
    if (bytes.len == 0 or bytes[0] != '#') return bytes;
    var i: usize = 0;
    while (i < bytes.len and bytes[i] != '\n' and bytes[i] != '\r') : (i += 1) {}
    if (i >= bytes.len) return "";
    if (bytes[i] == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') {
        return if (preserve_newline) bytes[i + 1 ..] else bytes[i + 2 ..];
    }
    return if (preserve_newline) bytes[i..] else bytes[i + 1 ..];
}

/// Execution options for script launch
pub const RunOptions = struct {
    /// Executable name/path (becomes arg[-1] in CLI convention)
    exec_name: []const u8 = "",
    /// Script name (becomes arg[0])
    script_name: []const u8 = "",
    /// Script arguments (become arg[1], arg[2], ...)
    args: []const []const u8 = &.{},
    // Future extensions:
    // env: ?*TableObject = null,
    // preload: []const PreloadModule = &.{},
};

/// Inject `arg` table into VM globals
/// Called by launcher before execution, not by Moonquakes facade
pub fn injectArg(globals: *TableObject, gc: *GC, options: RunOptions) !void {
    const arg_table = try gc.allocTable();

    // arg[-1] = executable name/path (when available)
    if (options.exec_name.len > 0) {
        const exec_str = try gc.allocString(options.exec_name);
        try arg_table.set(.{ .integer = -1 }, TValue.fromString(exec_str));
    }

    // arg[0] = script name
    const script_str = try gc.allocString(options.script_name);
    try arg_table.set(.{ .integer = 0 }, TValue.fromString(script_str));

    // arg[1], arg[2], ... = script arguments
    for (options.args, 0..) |arg, i| {
        const arg_str = try gc.allocString(arg);
        try arg_table.set(.{ .integer = @as(i64, @intCast(i + 1)) }, TValue.fromString(arg_str));
    }

    // Set arg global
    const arg_key = try gc.allocString("arg");
    try globals.set(TValue.fromString(arg_key), TValue.fromTable(arg_table));
}

/// Full execution pipeline with options
/// Creates Runtime, VM, injects context, compiles, executes, returns owned result
pub fn run(allocator: std.mem.Allocator, source: []const u8, options: RunOptions) !OwnedReturnValue {
    var source_name_buf: ?[]u8 = null;
    defer if (source_name_buf) |buf| allocator.free(buf);

    const source_name: []const u8 = if (options.script_name.len > 0) blk: {
        if (options.script_name[0] == '@' or options.script_name[0] == '=') {
            break :blk options.script_name;
        }
        source_name_buf = try std.fmt.allocPrint(allocator, "@{s}", .{options.script_name});
        break :blk source_name_buf.?;
    } else "[string]";

    // Phase 1: Compile to RawProto (no GC needed)
    const compile_result = pipeline.compile(allocator, source, .{ .source_name = source_name });
    switch (compile_result) {
        .err => |e| {
            defer e.deinit(allocator);
            std.debug.print("[string]:{d}: {s}\n", .{ e.line, e.message });
            return error.CompileFailed;
        },
        .ok => {},
    }
    const raw_proto = compile_result.ok;
    defer pipeline.freeRawProto(allocator, raw_proto);

    // Phase 2: Create Runtime (shared state) and VM (thread state)
    const rt = try Runtime.init(allocator);
    defer rt.deinit();

    const vm = try VM.init(rt);
    defer vm.deinit();

    // Phase 3: Inject execution context (arg table, etc.)
    try injectArg(vm.globals(), vm.gc(), options);

    // Phase 4: Materialize constants (returns GC-managed ProtoObject)
    const proto = try pipeline.materialize(&raw_proto, vm.gc(), allocator);
    // No defer needed - ProtoObject is GC-managed

    // Phase 5: Execute
    const result = Mnemonics.execute(vm, proto) catch |err| {
        if (err == error.LuaException) {
            // Print Lua error message before VM is destroyed
            if (vm.lua_error_value.asString()) |err_str| {
                std.debug.print("[string]:?: {s}\n", .{err_str.asSlice()});
            } else {
                std.debug.print("[string]:?: (error object is not a string)\n", .{});
            }
        }
        return err;
    };

    // Convert to owned values before VM is destroyed
    return owned.toOwnedReturnValue(allocator, result);
}

/// Load file and execute with options
pub fn runFile(allocator: std.mem.Allocator, file_path: []const u8, options: RunOptions) !OwnedReturnValue {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const source = try allocator.alloc(u8, file_size);
    defer allocator.free(source);

    _ = try file.readAll(source);

    // Use file_path as script_name if not provided
    var opts = options;
    if (opts.script_name.len == 0) {
        opts.script_name = file_path;
    }

    const chunk_source = stripInitialHashLine(stripUtf8Bom(source), true);
    return run(allocator, chunk_source, opts);
}
