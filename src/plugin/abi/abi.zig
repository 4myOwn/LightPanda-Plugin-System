// Copyright (C) 2023-2024 Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

//! ABI (Application Binary Interface) definitions for the Lightpanda Plugin System.
//!
//! This module defines the stable ABI that all plugins must export.
//! The ABI ensures binary compatibility between the Core and plugins,
//! regardless of compilation units or Zig compiler versions.
//!
//! All plugins MUST export these four functions:
//! - plugin_init()
//! - plugin_shutdown()
//! - plugin_metadata()
//! - plugin_api_version()

const std = @import("std");
const builtin = @import("builtin");

/// Current ABI version - increment when breaking changes occur
pub const current_abi_version: u32 = 1;

/// Magic number to identify valid plugin binaries
pub const plugin_magic: u32 = 0x4C504E47; // "LPNG"

/// Plugin initialization result codes
pub const InitResult = enum(c_int) {
    success = 0,
    failed = -1,
    api_mismatch = -2,
    missing_dependencies = -3,
    permission_denied = -4,
};

/// Plugin shutdown reason
pub const ShutdownReason = enum(c_int) {
    normal = 0,
    crash = 1,
    reload = 2,
    unload = 3,
};

/// Plugin metadata structure exported by all plugins
pub const PluginMetadata = extern struct {
    /// Magic number for validation
    magic: u32,
    /// Name of the plugin (null-terminated string)
    name: [*:0]const u8,
    /// Unique identifier (null-terminated string)
    id: [*:0]const u8,
    /// Version string (null-terminated string)
    version: [*:0]const u8,
    /// Author information (null-terminated string)
    author: [*:0]const u8,
    /// Description (null-terminated string)
    description: [*:0]const u8,
    /// Minimum API version required
    api_version: u32,
    /// ABI version this plugin was compiled against
    abi_version: u32,
};

/// Function pointer type for plugin initialization
pub const PluginInitFn = *const fn (*anyopaque) callconv(.C) InitResult;

/// Function pointer type for plugin shutdown
pub const PluginShutdownFn = *const fn (ShutdownReason) callconv(.C) void;

/// Function pointer type for getting plugin metadata
pub const PluginMetadataFn = *const fn () callconv(.C) *const PluginMetadata;

/// Function pointer type for getting API version
pub const PluginApiVersionFn = *const fn () callconv(.C) u32;

/// Plugin entry point structure
pub const PluginEntryPoints = extern struct {
    init: PluginInitFn,
    shutdown: PluginShutdownFn,
    get_metadata: PluginMetadataFn,
    get_api_version: PluginApiVersionFn,
};

/// Validate that a plugin has the correct magic number
pub fn validateMagic(magic: u32) bool {
    return magic == plugin_magic;
}

/// Check ABI compatibility between core and plugin
pub fn checkAbiCompatibility(core_version: u32, plugin_version: u32) bool {
    // Major version must match
    return (core_version >> 16) == (plugin_version >> 16);
}

/// Create plugin metadata helper
pub fn createMetadata(
    comptime name: []const u8,
    comptime id: []const u8,
    comptime version: []const u8,
    comptime author: []const u8,
    comptime description: []const u8,
    comptime api_version: u32,
) PluginMetadata {
    return .{
        .magic = plugin_magic,
        .name = name.ptr,
        .id = id.ptr,
        .version = version.ptr,
        .author = author.ptr,
        .description = description.ptr,
        .api_version = api_version,
        .abi_version = current_abi_version,
    };
}

/// Export macro for plugins - use this in plugin root files
pub fn exportPlugin(comptime metadata: PluginMetadata, comptime init_fn: anytype, comptime shutdown_fn: anytype) void {
    comptime {
        // Export the metadata function
        @export(&metadata, .{ .name = "plugin_metadata_data" });
    }

    // Export plugin_init
    @export(init_fn, .{ .name = "plugin_init" });

    // Export plugin_shutdown
    @export(shutdown_fn, .{ .name = "plugin_shutdown" });

    // Export plugin_metadata
    @export(pluginMetadataWrapper, .{ .name = "plugin_metadata" });

    // Export plugin_api_version
    @export(pluginApiVersionWrapper, .{ .name = "plugin_api_version" });
}

fn pluginMetadataWrapper() callconv(.C) *const PluginMetadata {
    // This will be overridden by each plugin
    @panic("plugin_metadata not properly initialized");
}

fn pluginApiVersionWrapper() callconv(.C) u32 {
    return current_abi_version;
}

test "ABI version compatibility" {
    try std.testing.expect(validateMagic(plugin_magic));
    try std.testing.expect(!validateMagic(0));
    
    // Same major version should be compatible
    try std.testing.expect(checkAbiCompatibility(0x00010000, 0x00010005));
    
    // Different major version should not be compatible
    try std.testing.expect(!checkAbiCompatibility(0x00010000, 0x00020000));
}
