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

//! Plugin Registry module for the Lightpanda Plugin System.
//!
//! The Plugin Registry maintains metadata about all registered plugins,
//! including their state, dependencies, hooks, and permissions.
//! It provides a central location for querying plugin information.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.plugin_registry);

/// Plugin lifecycle state
pub const PluginState = enum {
    /// Plugin discovered but not loaded
    discovered,
    /// Plugin loaded into memory
    loaded,
    /// Plugin initialized and ready
    enabled,
    /// Plugin loaded but inactive
    disabled,
    /// Plugin failed to load
    failed,
    /// Plugin is being unloaded
    unloading,
};

/// Plugin dependency specification
pub const Dependency = struct {
    /// Plugin ID of the dependency
    plugin_id: []const u8,
    /// Minimum version required (semver string)
    min_version: ?[]const u8 = null,
    /// Maximum version allowed (semver string)
    max_version: ?[]const u8 = null,
};

/// Plugin metadata (from manifest)
pub const PluginMetadata = struct {
    /// Unique identifier
    id: []const u8,
    /// Display name
    name: []const u8,
    /// Version string
    version: []const u8,
    /// Author information
    author: []const u8,
    /// Description
    description: []const u8,
    /// Entry point library filename
    entry: []const u8,
    /// API version required
    api_version: u32,
    /// Required permissions (as strings)
    permissions: [][]const u8,
    /// Declared hooks
    hooks: [][]const u8,
    /// Dependencies on other plugins
    dependencies: []Dependency,
    /// Path to the plugin directory
    path: []const u8,
};

/// Runtime plugin information
pub const PluginInfo = struct {
    /// Metadata from manifest
    metadata: PluginMetadata,
    /// Current state
    state: PluginState,
    /// Handle to loaded library
    handle: ?*anyopaque = null,
    /// Load timestamp
    loaded_at: u64 = 0,
    /// Enable timestamp
    enabled_at: ?u64 = null,
    /// Error message if failed
    error_message: ?[]const u8 = null,
    /// Number of times reloaded
    reload_count: u32 = 0,
};

/// Registry entry
const RegistryEntry = struct {
    info: PluginInfo,
    key: []const u8,
};

/// Plugin Registry configuration
pub const Config = struct {
    /// Maximum number of registered plugins
    max_plugins: usize = 100,
    /// Whether to enable debug logging
    debug_logging: bool = false,
};

/// Main Plugin Registry structure
pub const PluginRegistry = struct {
    allocator: Allocator,
    config: Config,
    plugins: std.StringHashMap(PluginInfo),
    load_order: std.ArrayList([]const u8),

    /// Initialize the Plugin Registry
    pub fn init(allocator: Allocator, config: Config) !PluginRegistry {
        return .{
            .allocator = allocator,
            .config = config,
            .plugins = std.StringHashMap(PluginInfo).init(allocator),
            .load_order = std.ArrayList([]const u8).init(allocator),
        };
    }

    /// Deinitialize the Plugin Registry
    pub fn deinit(self: *PluginRegistry) void {
        // Free all allocated strings
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            self.freePluginInfo(entry.value_ptr);
        }
        self.plugins.deinit();
        self.load_order.deinit();
    }

    /// Register a new plugin
    pub fn register(self: *PluginRegistry, metadata: PluginMetadata) !void {
        if (self.plugins.count() >= self.config.max_plugins) {
            log.err("Maximum plugin count reached", .{});
            return error.PluginLimitReached;
        }

        const key = try self.allocator.dupe(u8, metadata.id);
        errdefer self.allocator.free(key);

        const entry = try self.plugins.getOrPut(key);
        if (entry.found_existing) {
            log.warn("Plugin {s} already registered, updating", .{metadata.id});
            self.freePluginInfo(entry.value_ptr);
        }

        entry.value_ptr.* = .{
            .metadata = try self.copyMetadata(metadata),
            .state = .discovered,
            .handle = null,
            .loaded_at = 0,
            .enabled_at = null,
            .error_message = null,
            .reload_count = 0,
        };

        log.info("Registered plugin {s} v{s}", .{ metadata.id, metadata.version });
    }

    /// Update plugin state
    pub fn updateState(self: *PluginRegistry, plugin_id: []const u8, state: PluginState) !void {
        const entry = self.plugins.getEntry(plugin_id) orelse return error.PluginNotFound;
        entry.value_ptr.state = state;

        if (state == .enabled) {
            entry.value_ptr.enabled_at = @intCast(std.time.timestamp());
        }

        log.debug("Plugin {s} state changed to {s}", .{ plugin_id, @tagName(state) });
    }

    /// Set plugin handle
    pub fn setHandle(self: *PluginRegistry, plugin_id: []const u8, handle: *anyopaque) !void {
        const entry = self.plugins.getEntry(plugin_id) orelse return error.PluginNotFound;
        entry.value_ptr.handle = handle;
        entry.value_ptr.loaded_at = @intCast(std.time.timestamp());
    }

    /// Get plugin info
    pub fn getPlugin(self: *PluginRegistry, plugin_id: []const u8) ?*PluginInfo {
        const entry = self.plugins.getEntry(plugin_id) orelse return null;
        return entry.value_ptr;
    }

    /// Get plugin state
    pub fn getState(self: *PluginRegistry, plugin_id: []const u8) ?PluginState {
        const info = self.getPlugin(plugin_id) orelse return null;
        return info.state;
    }

    /// Check if plugin exists
    pub fn hasPlugin(self: *PluginRegistry, plugin_id: []const u8) bool {
        return self.plugins.contains(plugin_id);
    }

    /// Remove a plugin from registry
    pub fn remove(self: *PluginRegistry, plugin_id: []const u8) bool {
        const entry = self.plugins.fetchRemove(plugin_id) orelse return false;
        self.freePluginInfo(&entry.value);
        self.allocator.free(entry.key);

        // Remove from load order
        for (self.load_order.items, 0..) |id, i| {
            if (std.mem.eql(u8, id, plugin_id)) {
                _ = self.load_order.orderedRemove(i);
                break;
            }
        }

        log.info("Removed plugin {s} from registry", .{plugin_id});
        return true;
    }

    /// Get all plugins
    pub fn getAllPlugins(self: *PluginRegistry) std.StringHashMap(PluginInfo).Iterator {
        return self.plugins.iterator();
    }

    /// Get plugins by state
    pub fn getPluginsByState(self: *PluginRegistry, state: PluginState) std.ArrayList([]const u8) {
        var result = std.ArrayList([]const u8).init(self.allocator);

        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state == state) {
                result.append(entry.key_ptr.*) catch continue;
            }
        }

        return result;
    }

    /// Get enabled plugins
    pub fn getEnabledPlugins(self: *PluginRegistry) std.ArrayList([]const u8) {
        return self.getPluginsByState(.enabled);
    }

    /// Get failed plugins with error messages
    pub fn getFailedPlugins(self: *PluginRegistry) std.ArrayList(struct {
        id: []const u8,
        error: ?[]const u8,
    }) {
        var result = std.ArrayList(struct {
            id: []const u8,
            error: ?[]const u8,
        }).init(self.allocator);

        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state == .failed) {
                result.append(.{
                    .id = entry.key_ptr.*,
                    .error = entry.value_ptr.error_message,
                }) catch continue;
            }
        }

        return result;
    }

    /// Add to load order
    pub fn addToLoadOrder(self: *PluginRegistry, plugin_id: []const u8) !void {
        if (!self.hasPlugin(plugin_id)) {
            return error.PluginNotFound;
        }

        // Check if already in order
        for (self.load_order.items) |id| {
            if (std.mem.eql(u8, id, plugin_id)) {
                return;
            }
        }

        try self.load_order.append(try self.allocator.dupe(u8, plugin_id));
    }

    /// Get load order
    pub fn getLoadOrder(self: *PluginRegistry) [][]const u8 {
        return self.load_order.items;
    }

    /// Increment reload count
    pub fn incrementReloadCount(self: *PluginRegistry, plugin_id: []const u8) !void {
        const entry = self.plugins.getEntry(plugin_id) orelse return error.PluginNotFound;
        entry.value_ptr.reload_count += 1;
    }

    /// Set error message for failed plugin
    pub fn setError(self: *PluginRegistry, plugin_id: []const u8, error_msg: []const u8) !void {
        const entry = self.plugins.getEntry(plugin_id) orelse return error.PluginNotFound;
        
        // Free previous error message if exists
        if (entry.value_ptr.error_message) |prev| {
            self.allocator.free(prev);
        }

        entry.value_ptr.error_message = try self.allocator.dupe(u8, error_msg);
        entry.value_ptr.state = .failed;
    }

    /// Clear error message
    pub fn clearError(self: *PluginRegistry, plugin_id: []const u8) !void {
        const entry = self.plugins.getEntry(plugin_id) orelse return error.PluginNotFound;

        if (entry.value_ptr.error_message) |msg| {
            self.allocator.free(msg);
            entry.value_ptr.error_message = null;
        }
    }

    /// Get plugin count
    pub fn getCount(self: *PluginRegistry) usize {
        return self.plugins.count();
    }

    /// Get count by state
    pub fn getCountByState(self: *PluginRegistry, state: PluginState) usize {
        var count: usize = 0;
        var it = self.plugins.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state == state) {
                count += 1;
            }
        }
        return count;
    }

    /// Copy metadata (allocates strings)
    fn copyMetadata(self: *PluginRegistry, src: PluginMetadata) !PluginMetadata {
        return .{
            .id = try self.allocator.dupe(u8, src.id),
            .name = try self.allocator.dupe(u8, src.name),
            .version = try self.allocator.dupe(u8, src.version),
            .author = try self.allocator.dupe(u8, src.author),
            .description = try self.allocator.dupe(u8, src.description),
            .entry = try self.allocator.dupe(u8, src.entry),
            .api_version = src.api_version,
            .permissions = try self.allocator.dupe([]const u8, src.permissions),
            .hooks = try self.allocator.dupe([]const u8, src.hooks),
            .dependencies = try self.allocator.dupe(Dependency, src.dependencies),
            .path = try self.allocator.dupe(u8, src.path),
        };
    }

    /// Free allocated plugin info
    fn freePluginInfo(self: *PluginRegistry, info: *PluginInfo) void {
        self.allocator.free(info.metadata.id);
        self.allocator.free(info.metadata.name);
        self.allocator.free(info.metadata.version);
        self.allocator.free(info.metadata.author);
        self.allocator.free(info.metadata.description);
        self.allocator.free(info.metadata.entry);
        self.allocator.free(info.metadata.path);

        for (info.metadata.permissions) |perm| {
            self.allocator.free(perm);
        }
        self.allocator.free(info.metadata.permissions);

        for (info.metadata.hooks) |hook| {
            self.allocator.free(hook);
        }
        self.allocator.free(info.metadata.hooks);

        for (info.metadata.dependencies) |dep| {
            self.allocator.free(dep.plugin_id);
            if (dep.min_version) |v| self.allocator.free(v);
            if (dep.max_version) |v| self.allocator.free(v);
        }
        self.allocator.free(info.metadata.dependencies);

        if (info.error_message) |msg| {
            self.allocator.free(msg);
        }
    }
};

test "PluginRegistry basic operations" {
    const allocator = std.testing.allocator;
    var registry = try PluginRegistry.init(allocator, .{});
    defer registry.deinit();

    // Register a plugin
    const metadata = PluginMetadata{
        .id = "test_plugin",
        .name = "Test Plugin",
        .version = "1.0.0",
        .author = "Test Author",
        .description = "A test plugin",
        .entry = "plugin.so",
        .api_version = 1,
        .permissions = &.{},
        .hooks = &.{},
        .dependencies = &.{},
        .path = "/plugins/test",
    };

    try registry.register(metadata);
    try std.testing.expect(registry.hasPlugin("test_plugin"));

    // Update state
    try registry.updateState("test_plugin", .loaded);
    try std.testing.expectEqual(PluginState.loaded, registry.getState("test_plugin").?);

    // Get plugin
    const info = registry.getPlugin("test_plugin");
    try std.testing.expect(info != null);
    try std.testing.expectEqualStrings("Test Plugin", info.?.metadata.name);

    // Remove
    try std.testing.expect(registry.remove("test_plugin"));
    try std.testing.expect(!registry.hasPlugin("test_plugin"));
}
