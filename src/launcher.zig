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

/// Execution options for script launch
pub const RunOptions = struct {
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

    // arg[0] = script name
    const key_0 = try gc.allocString("0");
    const script_str = try gc.allocString(options.script_name);
    try arg_table.set(TValue.fromString(key_0), TValue.fromString(script_str));

    // arg[1], arg[2], ... = script arguments
    var key_buffer: [32]u8 = undefined;
    for (options.args, 0..) |arg, i| {
        const key_slice = std.fmt.bufPrint(&key_buffer, "{d}", .{i + 1}) catch continue;
        const key_str = try gc.allocString(key_slice);
        const arg_str = try gc.allocString(arg);
        try arg_table.set(TValue.fromString(key_str), TValue.fromString(arg_str));
    }

    // Set arg global
    const arg_key = try gc.allocString("arg");
    try globals.set(TValue.fromString(arg_key), TValue.fromTable(arg_table));
}

/// Full execution pipeline with options
/// Creates Runtime, VM, injects context, compiles, executes, returns owned result
pub fn run(allocator: std.mem.Allocator, source: []const u8, options: RunOptions) !OwnedReturnValue {
    // Phase 1: Compile to RawProto (no GC needed)
    const compile_result = pipeline.compile(allocator, source, .{});
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

    return run(allocator, source, opts);
}
