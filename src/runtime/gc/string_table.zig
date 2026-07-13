//! Interned string table
//!
//! PUC-lstring-style intrusive chaining: each interned StringObject links
//! to the next one in its bucket through `next_interned`. Compared to a
//! probing hash map this has no tombstones, so heavy intern/free churn
//! (many unique short-lived strings) cannot degrade probe chains — the
//! failure mode that previously capped the intern threshold at 16 bytes.
//! The table also shrinks when three quarters empty, releasing capacity
//! after string-heavy phases.

const std = @import("std");
const object = @import("object.zig");
const StringObject = object.StringObject;

pub const StringTable = struct {
    buckets: []?*StringObject,
    count: usize = 0,
    allocator: std.mem.Allocator,

    const MIN_BUCKETS: usize = 64;

    pub fn init(allocator: std.mem.Allocator) StringTable {
        return .{ .buckets = &.{}, .allocator = allocator };
    }

    /// Frees the bucket array only; the strings are GC objects with their
    /// own lifetime.
    pub fn deinit(self: *StringTable) void {
        if (self.buckets.len > 0) self.allocator.free(self.buckets);
        self.buckets = &.{};
        self.count = 0;
    }

    pub fn find(self: *const StringTable, str: []const u8, hash: u32) ?*StringObject {
        if (self.buckets.len == 0) return null;
        var node = self.buckets[@as(usize, hash) & (self.buckets.len - 1)];
        while (node) |s| : (node = s.next_interned) {
            if (s.hash == hash and s.len == str.len and std.mem.eql(u8, s.asSlice(), str)) {
                return s;
            }
        }
        return null;
    }

    pub fn insert(self: *StringTable, obj: *StringObject) !void {
        if (self.count >= self.buckets.len) {
            try self.resize(@max(MIN_BUCKETS, self.buckets.len * 2));
        }
        const idx = @as(usize, obj.hash) & (self.buckets.len - 1);
        obj.next_interned = self.buckets[idx];
        self.buckets[idx] = obj;
        obj.interned = true;
        self.count += 1;
    }

    pub fn remove(self: *StringTable, obj: *StringObject) void {
        if (self.buckets.len == 0) return;
        const idx = @as(usize, obj.hash) & (self.buckets.len - 1);
        var link = &self.buckets[idx];
        while (link.*) |s| {
            if (s == obj) {
                link.* = s.next_interned;
                s.next_interned = null;
                s.interned = false;
                self.count -= 1;
                break;
            }
            link = &s.next_interned;
        }
        // Shrink when three quarters empty so string-churn phases do not
        // pin peak capacity forever.
        if (self.buckets.len > MIN_BUCKETS and self.count < self.buckets.len / 4) {
            self.resize(self.buckets.len / 2) catch {};
        }
    }

    fn resize(self: *StringTable, new_len: usize) !void {
        const new_buckets = try self.allocator.alloc(?*StringObject, new_len);
        @memset(new_buckets, null);
        for (self.buckets) |head| {
            var node = head;
            while (node) |s| {
                const next = s.next_interned;
                const idx = @as(usize, s.hash) & (new_len - 1);
                s.next_interned = new_buckets[idx];
                new_buckets[idx] = s;
                node = next;
            }
        }
        if (self.buckets.len > 0) self.allocator.free(self.buckets);
        self.buckets = new_buckets;
    }
};
