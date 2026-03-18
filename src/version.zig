//! Version Information
//!
//! Single source of truth for Moonquakes identity.

pub const version: [:0]const u8 = "0.2.0";
pub const name: [:0]const u8 = "Moonquakes";
pub const tagline: [:0]const u8 = "An interpretation of Lua.";
pub const copyright: [:0]const u8 =
    "Copyright (c) 2025 KEI SAWAMURA. Licensed under the MIT License.";

pub fn printIdentity(writer: anytype) !void {
    try writer.print("{s} v{s}\n", .{ name, version });
}
