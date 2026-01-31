const std = @import("std");
const mq_mod = @import("moonquakes.zig");
const Moonquakes = mq_mod.Moonquakes;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var mq = Moonquakes.init(allocator);
    defer mq.deinit();

    // Get command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1) {
        const file_path = args[1];
        try stdout.print("Reading from file: {s}\n", .{file_path});

        var result = mq.loadFile(file_path) catch |err| switch (err) {
            error.FileNotFound => {
                try stdout.print("Error: File '{s}' not found\n", .{file_path});
                return;
            },
            else => return err,
        };
        defer result.deinit(allocator);

        try stdout.print("Moonquakes speaks for the first time!\n", .{});
        try stdout.print("Result: ", .{});
        switch (result) {
            .none => try stdout.print("nil\n", .{}),
            .single => |val| try stdout.print("{}\n", .{val}),
        }
    } else {
        try stdout.print("Usage: moonquakes <lua_file>\n", .{});
        try stdout.print("\n", .{});
        try stdout.print("Example usage:\n", .{});
        try stdout.print("  moonquakes script.lua    # Execute Lua file\n", .{});
    }
}
