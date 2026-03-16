const std = @import("std");
const mq = @import("moonquakes.zig");
const interrupt = @import("interrupt.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    interrupt.install();

    var cli = mq.CLI.init(allocator);

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    try cli.run(args);
}
