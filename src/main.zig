const std = @import("std");
const mq_mod = @import("moonquakes.zig");
const Moonquakes = mq_mod.Moonquakes;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mq = Moonquakes.init(allocator);
    defer mq.deinit();

    var cli = mq_mod.CLI.init(allocator, &mq);

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    try cli.run(args);
}
