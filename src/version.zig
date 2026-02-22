//! Version Information
//!
//! Single source of truth for Moonquakes identity.

pub const version = "0.1.1";
pub const name = "Moonquakes";
pub const tagline = "An interpretation of Lua.";
pub const copyright =
    "Copyright (c) 2025 KEI SAWAMURA. Licensed under the MIT License.";

pub fn printIdentity(writer: anytype) !void {
    try writer.print("{s} {s} - {s}\n", .{ name, version, tagline });
    try writer.print("{s}\n", .{copyright});
}
