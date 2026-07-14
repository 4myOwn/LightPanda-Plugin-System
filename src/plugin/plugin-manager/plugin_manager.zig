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

//! Plugin Manager module for the Lightpanda Plugin System.
//!
//! The Plugin Manager is the central orchestrator for the plugin system.
//! It coordinates discovery, loading, initialization, and lifecycle management
//! of all plugins.
//!
//! Features:
//! - Automatic plugin discovery
//! - Dependency resolution
//! - Hot reload support
//! - Lifecycle management (install, enable, disable, reload, unload)

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.plugin_manager);

const abi = @import("../abi/abi.zig");
const event_bus = @import("../event-bus/event_bus.zig");
const hook_manager = @import("../hook-manager/hook_manager.zig");
const permission_manager = @import("../permission-manager/permission_manager.zig");
const plugin_registry = @import("../plugin-registry/plugin_registry.zig");
const plugin_loader = @import("../plugin-loader/plugin_loader.zig");

/// Plugin Manager configuration
pub const Config = struct {
    /// Path to plugins directory
    plugins_dir: []const u8 = "./plugins",
    /// Whether to auto-load plugins on startup
    auto_load: bool = true,
    /// Whether to enable hot reload
    hot_reload: bool = true,
    /// Whether to watch for file changes
    watch_for_changes: bool = true,
    /// Maximum number of plugins
    max_plugins: usize = 100,
};

/// Plugin Manager state
pub const State = enum {
    uninitialized,
    initializing,
    ready,
    shutting_down,
    stopped,
};

/// Main Plugin Manager structure
pub const PluginManager = struct {
    allocator: Allocator,
    config: Config,
    state: State,
    registry: plugin_registry.PluginRegistry,
    loader: plugin_loader.PluginLoader,
    event_bus: event_bus.EventBus,
    hook_manager: hook_manager.HookManager,
    permission_manager: permission_manager.PermissionManager,
    watcher_thread: ?std.Thread,
    running: bool,

    /// Initialize the Plugin Manager
    pub fn init(allocator: Allocator, config: Config) !PluginManager {
        return .{
            .allocator = allocator,
            .config = config,
            .state = .uninitialized,
            .registry = try plugin_registry.PluginRegistry.init(allocator, .{}),
            .loader = try plugin_loader.PluginLoader.init(allocator, .{}),
            .event_bus = try event_bus.EventBus.init(allocator, .{}),
            .hook_manager = try hook_manager.HookManager.init(allocator, .{}),
            .permission_manager = try permission_manager.PermissionManager.init(allocator, .{}),
            .watcher_thread = null,
            .running = false,
        };
    }

    /// Deinitialize the Plugin Manager
    pub fn deinit(self: *PluginManager) void {
        self.running = false;

        if (self.watcher_thread) |thread| {
            thread.join();
        }

        // Unload all plugins
        self.unloadAll() catch {};

        self.registry.deinit();
        self.loader.deinit();
        self.event_bus.deinit();
        self.hook_manager.deinit();
        self.permission_manager.deinit();
    }

    /// Start the Plugin Manager
    pub fn start(self: *PluginManager) !void {
        if (self.state != .uninitialized) {
            return error.InvalidState;
        }

        self.state = .initializing;
        self.running = true;

        // Start event bus
        try self.event_bus.start();

        // Discover and load plugins
        if (self.config.auto_load) {
            try self.discoverPlugins();
            try self.loadDiscoveredPlugins();
        }

        // Start file watcher if enabled
        if (self.config.watch_for_changes and self.config.hot_reload) {
            self.watcher_thread = try std.Thread.spawn(.{}, watchForChanges, .{self});
        }

        self.state = .ready;
        log.info("Plugin Manager started", .{});
    }

    /// Stop the Plugin Manager
    pub fn stop(self: *PluginManager) void {
        if (self.state != .ready) {
            return;
        }

        self.state = .shutting_down;
        self.running = false;

        // Stop event bus
        self.event_bus.stop();

        // Unload all plugins
        self.unloadAll() catch {};

        self.state = .stopped;
        log.info("Plugin Manager stopped", .{});
    }

    /// Discover plugins in the plugins directory
    pub fn discoverPlugins(self: *PluginManager) !void {
        const dir = std.fs.cwd().openDir(self.config.plugins_dir, .{ .iterate = true }) catch |err| {
            log.warn("Cannot open plugins directory: {}", .{err});
            return;
        };
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.path, "plugin.yml")) {
                try self.parseAndRegisterPlugin(entry.path);
            }
        }

        log.info("Discovered {d} plugins", .{self.registry.getCount()});
    }

    /// Parse plugin manifest and register
    fn parseAndRegisterPlugin(self: *PluginManager, manifest_path: []const u8) !void {
        _ = self;
        _ = manifest_path;
        // TODO: Parse YAML manifest and register plugin
        log.debug("Found plugin manifest: {s}", .{manifest_path});
    }

    /// Load all discovered plugins
    pub fn loadDiscoveredPlugins(self: *PluginManager) !void {
        var it = self.registry.getAllPlugins();
        while (it.next()) |entry| {
            if (entry.value_ptr.state == .discovered) {
                try self.loadPlugin(entry.key_ptr.*);
            }
        }
    }

    /// Load a specific plugin
    pub fn loadPlugin(self: *PluginManager, plugin_id: []const u8) !void {
        const info = self.registry.getPlugin(plugin_id) orelse return error.PluginNotFound;

        if (info.state != .discovered and info.state != .disabled) {
            return error.InvalidState;
        }

        // Check dependencies
        try self.resolveDependencies(plugin_id);

        // Load the library
        const handle = try self.loader.load(info.metadata.entry);

        // Get plugin entry points
        const entry_points = try self.loader.getEntryPoints(handle);

        // Validate ABI
        const api_version = entry_points.get_api_version();
        if (api_version != abi.current_abi_version) {
            log.err("Plugin {s} has incompatible API version: {d}", .{ plugin_id, api_version });
            try self.registry.setError(plugin_id, "Incompatible API version");
            return error.ApiVersionMismatch;
        }

        // Register handle
        try self.registry.setHandle(plugin_id, handle);
        try self.registry.updateState(plugin_id, .loaded);

        // Grant permissions
        const perms = try permission_manager.PermissionSet.createPermissionSetFromStrings(
            self.allocator,
            info.metadata.permissions,
        );
        try self.permission_manager.grant(plugin_id, perms);

        // Initialize plugin
        const api = try self.createPluginApi(plugin_id);
        const result = entry_points.init(api);

        if (result == .success) {
            try self.registry.updateState(plugin_id, .enabled);
            try self.registry.addToLoadOrder(plugin_id);
            log.info("Plugin {s} loaded and enabled", .{plugin_id});
        } else {
            try self.registry.setError(plugin_id, "Initialization failed");
            return error.InitializationFailed;
        }
    }

    /// Unload a specific plugin
    pub fn unloadPlugin(self: *PluginManager, plugin_id: []const u8) !void {
        const info = self.registry.getPlugin(plugin_id) orelse return error.PluginNotFound;

        if (info.state == .unloading) {
            return;
        }

        try self.registry.updateState(plugin_id, .unloading);

        // Call plugin shutdown
        const entry_points = self.loader.getEntryPoints(info.handle.?);
        entry_points.shutdown(.normal);

        // Unregister hooks
        self.hook_manager.unregisterPlugin(plugin_id);

        // Revoke permissions
        self.permission_manager.revokeAll(plugin_id);

        // Unload library
        try self.loader.unload(info.handle.?);

        try self.registry.remove(plugin_id);
        log.info("Plugin {s} unloaded", .{plugin_id});
    }

    /// Unload all plugins
    pub fn unloadAll(self: *PluginManager) !void {
        const order = self.registry.getLoadOrder();
        var i: usize = order.len;
        while (i > 0) {
            i -= 1;
            self.unloadPlugin(order[i]) catch |err| {
                log.err("Failed to unload plugin {s}: {}", .{ order[i], err });
            };
        }
    }

    /// Enable a disabled plugin
    pub fn enablePlugin(self: *PluginManager, plugin_id: []const u8) !void {
        const info = self.registry.getPlugin(plugin_id) orelse return error.PluginNotFound;

        if (info.state != .disabled) {
            return error.InvalidState;
        }

        // Re-grant permissions
        const perms = try permission_manager.PermissionSet.createPermissionSetFromStrings(
            self.allocator,
            info.metadata.permissions,
        );
        try self.permission_manager.grant(plugin_id, perms);

        // Initialize plugin
        const api = try self.createPluginApi(plugin_id);
        const entry_points = self.loader.getEntryPoints(info.handle.?);
        const result = entry_points.init(api);

        if (result == .success) {
            try self.registry.updateState(plugin_id, .enabled);
            log.info("Plugin {s} enabled", .{plugin_id});
        } else {
            return error.InitializationFailed;
        }
    }

    /// Disable a plugin without unloading
    pub fn disablePlugin(self: *PluginManager, plugin_id: []const u8) !void {
        const info = self.registry.getPlugin(plugin_id) orelse return error.PluginNotFound;

        if (info.state != .enabled) {
            return error.InvalidState;
        }

        // Call plugin shutdown (with reload reason since we're just disabling)
        const entry_points = self.loader.getEntryPoints(info.handle.?);
        entry_points.shutdown(.unload);

        // Revoke permissions
        self.permission_manager.revokeAll(plugin_id);

        try self.registry.updateState(plugin_id, .disabled);
        log.info("Plugin {s} disabled", .{plugin_id});
    }

    /// Reload a plugin (hot reload)
    pub fn reloadPlugin(self: *PluginManager, plugin_id: []const u8) !void {
        const info = self.registry.getPlugin(plugin_id) orelse return error.PluginNotFound;

        if (info.state != .enabled) {
            return error.InvalidState;
        }

        log.info("Reloading plugin {s}", .{plugin_id});

        // Shutdown plugin
        const entry_points = self.loader.getEntryPoints(info.handle.?);
        entry_points.shutdown(.reload);

        // Unload library
        try self.loader.unload(info.handle.?);

        // Reload library
        const new_handle = try self.loader.load(info.metadata.entry);

        // Update handle
        try self.registry.setHandle(plugin_id, new_handle);
        try self.registry.incrementReloadCount(plugin_id);

        // Re-initialize
        const api = try self.createPluginApi(plugin_id);
        const new_entry_points = self.loader.getEntryPoints(new_handle);
        const result = new_entry_points.init(api);

        if (result == .success) {
            try self.registry.updateState(plugin_id, .enabled);
            log.info("Plugin {s} reloaded successfully", .{plugin_id});
        } else {
            try self.registry.setError(plugin_id, "Reload failed");
            return error.ReloadFailed;
        }
    }

    /// Resolve plugin dependencies
    fn resolveDependencies(self: *PluginManager, plugin_id: []const u8) !void {
        const info = self.registry.getPlugin(plugin_id) orelse return error.PluginNotFound;

        for (info.metadata.dependencies) |dep| {
            if (!self.registry.hasPlugin(dep.plugin_id)) {
                log.err("Plugin {s} missing dependency: {s}", .{ plugin_id, dep.plugin_id });
                return error.MissingDependency;
            }

            const dep_info = self.registry.getPlugin(dep.plugin_id).?;
            
            // Check if dependency is enabled
            if (dep_info.state != .enabled) {
                // Try to load dependency first
                try self.loadPlugin(dep.plugin_id);
            }

            // TODO: Check version constraints
            _ = dep.min_version;
            _ = dep.max_version;
        }
    }

    /// Create plugin API for a specific plugin
    fn createPluginApi(self: *PluginManager, plugin_id: []const u8) !*anyopaque {
        _ = self;
        _ = plugin_id;
        // TODO: Create wrapped API with permission checks
        return @ptrCast(@alignCast(&.{ .version = abi.current_abi_version }));
    }

    /// File watcher thread function
    fn watchForChanges(self: *PluginManager) void {
        _ = self;
        // TODO: Implement file watching for hot reload
        while (self.running) {
            std.time.sleep(std.time.ns_per_s);
        }
    }

    /// Get plugin count
    pub fn getPluginCount(self: *PluginManager) usize {
        return self.registry.getCount();
    }

    /// Get enabled plugin count
    pub fn getEnabledCount(self: *PluginManager) usize {
        return self.registry.getCountByState(.enabled);
    }

    /// Get state
    pub fn getState(self: *PluginManager) State {
        return self.state;
    }
};

test "PluginManager initialization" {
    const allocator = std.testing.allocator;
    var manager = try PluginManager.init(allocator, .{
        .plugins_dir = "./src/plugin/plugins",
        .auto_load = false,
    });
    defer manager.deinit();

    try std.testing.expectEqual(State.uninitialized, manager.getState());

    try manager.start();
    try std.testing.expectEqual(State.ready, manager.getState());

    manager.stop();
    try std.testing.expectEqual(State.stopped, manager.getState());
}
