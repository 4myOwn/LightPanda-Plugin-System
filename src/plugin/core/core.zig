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

//! Core module for the Lightpanda Plugin System.
//!
//! The Core module provides the integration point between the browser core
//! and the plugin system. It fires events at key points in the browser
//! lifecycle, allowing plugins to react without accessing internal structures.
//!
//! The Core knows NOTHING about specific plugins - it only interacts with
//! the Plugin Manager through public APIs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.plugin_core);

const plugin_manager = @import("../plugin-manager/plugin_manager.zig");
const hook_manager = @import("../hook-manager/hook_manager.zig");
const event_bus = @import("../event-bus/event_bus.zig");

/// Core Plugin configuration
pub const Config = struct {
    /// Path to plugins directory
    plugins_dir: []const u8 = "./plugins",
    /// Whether to enable plugin system
    enabled: bool = true,
    /// Whether to log plugin events
    log_events: bool = false,
};

/// Main Core Plugin structure
pub const Core = struct {
    allocator: Allocator,
    config: Config,
    manager: ?plugin_manager.PluginManager,
    initialized: bool,

    /// Initialize the Core Plugin system
    pub fn init(allocator: Allocator, config: Config) !Core {
        return .{
            .allocator = allocator,
            .config = config,
            .manager = null,
            .initialized = false,
        };
    }

    /// Deinitialize the Core Plugin system
    pub fn deinit(self: *Core) void {
        if (self.manager) |*mgr| {
            mgr.stop();
            mgr.deinit();
        }
        self.initialized = false;
    }

    /// Start the plugin system
    pub fn start(self: *Core) !void {
        if (!self.config.enabled) {
            log.info("Plugin system disabled", .{});
            return;
        }

        if (self.initialized) {
            return error.AlreadyInitialized;
        }

        var mgr = try plugin_manager.PluginManager.init(self.allocator, .{
            .plugins_dir = self.config.plugins_dir,
            .auto_load = true,
        });
        errdefer mgr.deinit();

        try mgr.start();

        self.manager = mgr;
        self.initialized = true;

        // Fire browser start hook
        self.fireHook(.onBrowserStart, null);

        log.info("Core plugin system started", .{});
    }

    /// Stop the plugin system
    pub fn stop(self: *Core) void {
        if (!self.initialized) {
            return;
        }

        // Fire browser shutdown hook
        self.fireHook(.onBrowserShutdown, null);

        if (self.manager) |*mgr| {
            mgr.stop();
            mgr.deinit();
            self.manager = null;
        }

        self.initialized = false;
        log.info("Core plugin system stopped", .{});
    }

    /// Fire a hook event
    pub fn fireHook(self: *Core, hook_type: hook_manager.HookType, context: ?*anyopaque) void {
        if (!self.initialized or self.manager == null) {
            return;
        }

        if (self.config.log_events) {
            log.debug("Firing hook: {s}", .{hook_manager.hookTypeToString(hook_type)});
        }

        self.manager.?.hook_manager.trigger(hook_type, context);
    }

    /// Fire page created event
    pub fn onPageCreated(self: *Core, page_id: u64, context: ?*anyopaque) void {
        _ = page_id;
        self.fireHook(.onPageCreated, context);
    }

    /// Fire page destroyed event
    pub fn onPageDestroyed(self: *Core, page_id: u64, context: ?*anyopaque) void {
        _ = page_id;
        self.fireHook(.onPageDestroyed, context);
    }

    /// Fire navigation start event
    pub fn onNavigationStart(self: *Core, url: []const u8, context: ?*anyopaque) void {
        _ = url;
        self.fireHook(.onNavigationStart, context);
    }

    /// Fire navigation end event
    pub fn onNavigationEnd(self: *Core, url: []const u8, success: bool, context: ?*anyopaque) void {
        _ = url;
        _ = success;
        self.fireHook(.onNavigationEnd, context);
    }

    /// Fire DOM parsed event
    pub fn onDOMParsed(self: *Core, context: ?*anyopaque) void {
        self.fireHook(.onDOMParsed, context);
    }

    /// Fire DOM ready event
    pub fn onDOMReady(self: *Core, context: ?*anyopaque) void {
        self.fireHook(.onDOMReady, context);
    }

    /// Fire request event
    pub fn onRequest(self: *Core, url: []const u8, method: []const u8, context: ?*anyopaque) void {
        _ = url;
        _ = method;
        self.fireHook(.onRequest, context);
    }

    /// Fire response event
    pub fn onResponse(self: *Core, url: []const u8, status: u16, context: ?*anyopaque) void {
        _ = url;
        _ = status;
        self.fireHook(.onResponse, context);
    }

    /// Fire console message event
    pub fn onConsole(self: *Core, level: []const u8, message: []const u8, context: ?*anyopaque) void {
        _ = level;
        _ = message;
        self.fireHook(.onConsole, context);
    }

    /// Fire error event
    pub fn onError(self: *Core, error_msg: []const u8, context: ?*anyopaque) void {
        _ = error_msg;
        self.fireHook(.onError, context);
    }

    /// Get plugin manager
    pub fn getManager(self: *Core) ?*plugin_manager.PluginManager {
        if (!self.initialized) return null;
        return &self.manager.?;
    }

    /// Check if plugin system is initialized
    pub fn isInitialized(self: *Core) bool {
        return self.initialized;
    }

    /// Get plugin count
    pub fn getPluginCount(self: *Core) usize {
        if (!self.initialized) return 0;
        return self.manager.?.getPluginCount();
    }

    /// Get enabled plugin count
    pub fn getEnabledPluginCount(self: *Core) usize {
        if (!self.initialized) return 0;
        return self.manager.?.getEnabledCount();
    }
};

test "Core initialization" {
    const allocator = std.testing.allocator;
    var core = try Core.init(allocator, .{
        .plugins_dir = "./plugins",
        .enabled = true,
    });
    defer core.deinit();

    try std.testing.expect(!core.isInitialized());

    try core.start();
    try std.testing.expect(core.isInitialized());

    try std.testing.expect(core.getPluginCount() >= 0);

    core.stop();
    try std.testing.expect(!core.isInitialized());
}
