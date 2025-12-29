const std = @import("std");
const TValue = @import("value.zig").TValue;

pub const Table = struct {
    hash_part: std.HashMap([]const u8, TValue, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Table {
        return Table{
            .hash_part = std.HashMap([]const u8, TValue, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Table) void {
        self.hash_part.deinit();
    }

    pub fn get(self: *const Table, key: []const u8) ?TValue {
        return self.hash_part.get(key);
    }

    pub fn set(self: *Table, key: []const u8, value: TValue) !void {
        try self.hash_part.put(key, value);
    }
};
