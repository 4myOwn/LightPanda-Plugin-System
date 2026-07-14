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

//! Plugin SDK for the Lightpanda Plugin System.
//!
//! The SDK provides a high-level API for plugin developers to easily
//! create plugins without dealing with low-level implementation details.
//!
//! Usage example:
//! ```zig
//! const plugin = @import("plugin_sdk");
//!
//! var my_plugin = plugin.Plugin{
//!     .id = "my_plugin",
//!     .name = "My Plugin",
//!     .version = "1.0.0",
//! };
//!
//! export fn plugin_init(api: *plugin.PluginAPI) callconv(.C) plugin.InitResult {
//!     api.registerHook(.onDOMReady, onDOMReadyHandler);
//!     return .success;
//! }
//!
//! fn onDOMReadyHandler(ctx: ?*anyopaque) callconv(.C) void {
//!     // Handle DOM ready event
//! }
//! ```

const std = @import("std");
const abi = @import("../abi/abi.zig");
const hook_manager = @import("../hook-manager/hook_manager.zig");
const permission_manager = @import("../permission-manager/permission_manager.zig");

/// Plugin initialization result
pub const InitResult = abi.InitResult;

/// Plugin API version
pub const api_version: u32 = 1;

/// Plugin metadata structure
pub const PluginMetadata = struct {
    id: []const u8,
    name: []const u8,
    version: []const u8,
    author: []const u8 = "Unknown",
    description: []const u8 = "",
};

/// Plugin API interface provided to plugins
pub const PluginAPI = opaque {
    /// Register a hook callback
    pub fn registerHook(
        self: *PluginAPI,
        hook_type: hook_manager.HookType,
        callback: hook_manager.HookCallback,
        context: ?*anyopaque,
        priority: u8,
    ) bool {
        _ = self;
        _ = hook_type;
        _ = callback;
        _ = context;
        _ = priority;
        // Implementation provided by host
        return false;
    }

    /// Unregister a hook callback
    pub fn unregisterHook(
        self: *PluginAPI,
        hook_type: hook_manager.HookType,
        callback: hook_manager.HookCallback,
    ) bool {
        _ = self;
        _ = hook_type;
        _ = callback;
        // Implementation provided by host
        return false;
    }

    /// Check if plugin has a permission
    pub fn hasPermission(self: *PluginAPI, permission: []const u8) bool {
        _ = self;
        _ = permission;
        // Implementation provided by host
        return false;
    }

    /// Log a message
    pub fn log(self: *PluginAPI, level: LogLevel, message: []const u8) void {
        _ = self;
        _ = level;
        _ = message;
        // Implementation provided by host
    }

    /// Emit an event
    pub fn emitEvent(self: *PluginAPI, event_name: []const u8, payload: ?[]const u8) void {
        _ = self;
        _ = event_name;
        _ = payload;
        // Implementation provided by host
    }

    /// Subscribe to an event
    pub fn subscribeEvent(
        self: *PluginAPI,
        event_name: []const u8,
        handler: EventCallback,
        context: ?*anyopaque,
    ) ?u64 {
        _ = self;
        _ = event_name;
        _ = handler;
        _ = context;
        // Implementation provided by host
        return null;
    }

    /// Get page URL
    pub fn getPageUrl(self: *PluginAPI) ?[]const u8 {
        _ = self;
        // Implementation provided by host
        return null;
    }

    /// Get page title
    pub fn getPageTitle(self: *PluginAPI) ?[]const u8 {
        _ = self;
        // Implementation provided by host
        return null;
    }

    /// Query DOM selector
    pub fn querySelector(self: *PluginAPI, selector: []const u8) ?*anyopaque {
        _ = self;
        _ = selector;
        // Implementation provided by host
        return null;
    }

    /// Query all DOM selectors
    pub fn querySelectorAll(self: *PluginAPI, selector: []const u8) []?anyopaque {
        _ = self;
        _ = selector;
        // Implementation provided by host
        return &.{};
    }
};

/// Log levels
pub const LogLevel = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    error = 3,
};

/// Event callback signature
pub const EventCallback = *const fn ([]const u8, ?*anyopaque) callconv(.C) void;

/// Helper to create plugin metadata
pub fn createMetadata(
    comptime id: []const u8,
    comptime name: []const u8,
    comptime version: []const u8,
    comptime author: []const u8,
    comptime description: []const u8,
) PluginMetadata {
    return .{
        .id = id,
        .name = name,
        .version = version,
        .author = author,
        .description = description,
    };
}

/// Macro to export plugin entry points
pub fn exportPlugin(
    comptime metadata: PluginMetadata,
    comptime init_fn: anytype,
    comptime shutdown_fn: anytype,
) void {
    // Create static metadata
    var static_metadata = abi.createMetadata(
        metadata.name,
        metadata.id,
        metadata.version,
        metadata.author,
        metadata.description,
        api_version,
    );

    // Export functions
    @export(init_fn, .{ .name = "plugin_init" });
    @export(shutdown_fn, .{ .name = "plugin_shutdown" });

    // Export metadata getter
    const MetadataGetter = struct {
        fn get() callconv(.C) *const abi.PluginMetadata {
            return &static_metadata;
        }
    };
    @export(MetadataGetter.get, .{ .name = "plugin_metadata" });

    // Export API version
    const ApiVersionGetter = struct {
        fn get() callconv(.C) u32 {
            return api_version;
        }
    };
    @export(ApiVersionGetter.get, .{ .name = "plugin_api_version" });
}

/// Logger helper for plugins
pub const Logger = struct {
    plugin_id: []const u8,
    api: *PluginAPI,

    pub fn debug(self: Logger, comptime format: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(std.heap.page_allocator, format, args) catch return;
        defer std.heap.page_allocator.free(msg);
        self.api.log(.debug, msg);
    }

    pub fn info(self: Logger, comptime format: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(std.heap.page_allocator, format, args) catch return;
        defer std.heap.page_allocator.free(msg);
        self.api.log(.info, msg);
    }

    pub fn warn(self: Logger, comptime format: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(std.heap.page_allocator, format, args) catch return;
        defer std.heap.page_allocator.free(msg);
        self.api.log(.warn, msg);
    }

    pub fn error(self: Logger, comptime format: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(std.heap.page_allocator, format, args) catch return;
        defer std.heap.page_allocator.free(msg);
        self.api.log(.error, msg);
    }
};

test "PluginSDK metadata creation" {
    const metadata = createMetadata(
        "test",
        "Test Plugin",
        "1.0.0",
        "Test Author",
        "A test plugin",
    );

    try std.testing.expectEqualStrings("test", metadata.id);
    try std.testing.expectEqualStrings("Test Plugin", metadata.name);
    try std.testing.expectEqualStrings("1.0.0", metadata.version);
}
