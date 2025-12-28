const std = @import("std");
const Table = @import("../core/table.zig").Table;
const Function = @import("../core/function.zig").Function;
const NativeFnId = @import("../core/native.zig").NativeFnId;
const TValue = @import("../core/value.zig").TValue;
const string = @import("string.zig");
const io = @import("io.zig");
const global = @import("global.zig");

pub fn initGlobalEnvironment(globals: *Table, allocator: std.mem.Allocator) !void {
    // Create io table
    var io_table = try allocator.create(Table);
    io_table.* = Table.init(allocator);

    // Add io.write as native function
    const io_write_fn = Function{ .native = .{ .id = NativeFnId.io_write } };
    try io_table.set("write", .{ .function = io_write_fn });

    try globals.set("io", .{ .table = io_table });

    // Add tostring as global function
    const tostring_fn = Function{ .native = .{ .id = NativeFnId.tostring } };
    try globals.set("tostring", .{ .function = tostring_fn });

    // Add print as global function
    const print_fn = Function{ .native = .{ .id = NativeFnId.print } };
    try globals.set("print", .{ .function = print_fn });
}

pub fn invoke(id: NativeFnId, vm: anytype, func_reg: u32, nargs: u32, nresults: u32) !void {
    switch (id) {
        .print => try global.nativePrint(vm, func_reg, nargs, nresults),
        .io_write => try io.nativeIoWrite(vm, func_reg, nargs, nresults),
        .tostring => try string.nativeToString(vm, func_reg, nargs, nresults),
    }
}
