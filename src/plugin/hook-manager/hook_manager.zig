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

//! Hook Manager module for the Lightpanda Plugin System.
//!
//! The Hook Manager provides a mechanism for plugins to register callbacks
//! at specific points in the browser lifecycle. Hooks are similar to events
//! but are specifically tied to browser operations and page lifecycle.
//!
//! Available hooks:
//! - onBrowserStart
//! - onBrowserShutdown
//! - onPageCreated
//! - onPageDestroyed
//! - onNavigationStart
//! - onNavigationEnd
//! - onRequest
//! - onResponse
//! - onDOMParsed
//! - onDOMReady
//! - onMutation
//! - onScriptExecuted
//! - onConsole
//! - onStyleComputed
//! - onLayoutFinished
//! - onPaint
//! - onRender
//! - onAccessibilityTree
//! - onSecurityCheck
//! - onPerformanceSample
//! - onBeforeScreenshot
//! - onAfterScreenshot
//! - onError

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.hook_manager);

/// All available hook types
pub const HookType = enum {
    /// Browser lifecycle hooks
    onBrowserStart,
    onBrowserShutdown,

    /// Page lifecycle hooks
    onPageCreated,
    onPageDestroyed,

    /// Navigation hooks
    onNavigationStart,
    onNavigationEnd,

    /// Network hooks
    onRequest,
    onResponse,

    /// DOM hooks
    onDOMParsed,
    onDOMReady,
    onMutation,

    /// Script hooks
    onScriptExecuted,

    /// Console hooks
    onConsole,

    /// Style and layout hooks
    onStyleComputed,
    onLayoutFinished,
    onPaint,
    onRender,

    /// Accessibility hooks
    onAccessibilityTree,

    /// Security hooks
    onSecurityCheck,

    /// Performance hooks
    onPerformanceSample,

    /// Screenshot hooks
    onBeforeScreenshot,
    onAfterScreenshot,

    /// Error handling
    onError,
};

/// Hook callback function signature
pub const HookCallback = *const fn (?*anyopaque) callconv(.C) void;

/// Hook registration entry
pub const HookEntry = struct {
    hook_type: HookType,
    callback: HookCallback,
    context: ?*anyopaque,
    plugin_id: []const u8,
    priority: u8 = 100,
};

/// Hook manager configuration
pub const Config = struct {
    /// Maximum number of hooks per type
    max_hooks_per_type: usize = 64,
    /// Whether to enable debug logging
    debug_logging: bool = false,
};

/// Main Hook Manager structure
pub const HookManager = struct {
    allocator: Allocator,
    config: Config,
    hooks: [std.meta.fields(HookType).len]std.ArrayList(HookEntry),
    total_hooks: usize,

    /// Initialize the Hook Manager
    pub fn init(allocator: Allocator, config: Config) !HookManager {
        var self = HookManager{
            .allocator = allocator,
            .config = config,
            .hooks = undefined,
            .total_hooks = 0,
        };

        // Initialize all hook lists
        inline for (std.meta.fields(HookType)) |field| {
            self.hooks[@intFromEnum(@field(HookType, field.name))] = 
                std.ArrayList(HookEntry).init(allocator);
        }

        return self;
    }

    /// Deinitialize the Hook Manager
    pub fn deinit(self: *HookManager) void {
        inline for (std.meta.fields(HookType)) |field| {
            self.hooks[@intFromEnum(@field(HookType, field.name))].deinit();
        }
    }

    /// Register a hook callback
    pub fn register(
        self: *HookManager,
        hook_type: HookType,
        callback: HookCallback,
        context: ?*anyopaque,
        plugin_id: []const u8,
        priority: u8,
    ) !void {
        const hook_list = &self.hooks[@intFromEnum(hook_type)];

        if (hook_list.items.len >= self.config.max_hooks_per_type) {
            log.err("Maximum hooks reached for hook type {s}", .{@tagName(hook_type)});
            return error.HooksExhausted;
        }

        try hook_list.append(.{
            .hook_type = hook_type,
            .callback = callback,
            .context = context,
            .plugin_id = plugin_id,
            .priority = priority,
        });

        self.total_hooks += 1;

        // Sort by priority (lower value = higher priority)
        sortHooksByPriority(hook_list.items);

        log.debug("Hook {s} registered by plugin {s} (total: {d})", .{
            @tagName(hook_type),
            plugin_id,
            hook_list.items.len,
        });
    }

    /// Unregister all hooks for a specific plugin
    pub fn unregisterPlugin(self: *HookManager, plugin_id: []const u8) void {
        inline for (std.meta.fields(HookType)) |field| {
            const hook_type = @field(HookType, field.name);
            const hook_list = &self.hooks[@intFromEnum(hook_type)];

            var i: usize = 0;
            while (i < hook_list.items.len) {
                if (std.mem.eql(u8, hook_list.items[i].plugin_id, plugin_id)) {
                    _ = hook_list.orderedRemove(i);
                    self.total_hooks -= 1;
                } else {
                    i += 1;
                }
            }
        }

        log.debug("All hooks unregistered for plugin {s}", .{plugin_id});
    }

    /// Unregister a specific hook callback
    pub fn unregister(
        self: *HookManager,
        hook_type: HookType,
        callback: HookCallback,
    ) bool {
        const hook_list = &self.hooks[@intFromEnum(hook_type)];

        for (hook_list.items, 0..) |entry, i| {
            if (entry.callback == callback) {
                _ = hook_list.orderedRemove(i);
                self.total_hooks -= 1;
                log.debug("Hook {s} unregistered", .{@tagName(hook_type)});
                return true;
            }
        }
        return false;
    }

    /// Trigger a hook with optional context data
    pub fn trigger(self: *HookManager, hook_type: HookType, context: ?*anyopaque) void {
        const hook_list = &self.hooks[@intFromEnum(hook_type)];

        log.debug("Triggering hook {s} ({d} listeners)", .{
            @tagName(hook_type),
            hook_list.items.len,
        });

        for (hook_list.items) |entry| {
            entry.callback(entry.context orelse context);
        }
    }

    /// Get the number of registered hooks for a hook type
    pub fn getHookCount(self: *HookManager, hook_type: HookType) usize {
        return self.hooks[@intFromEnum(hook_type)].items.len;
    }

    /// Get total number of registered hooks
    pub fn getTotalHookCount(self: *HookManager) usize {
        return self.total_hooks;
    }

    /// Check if a hook type has any registered callbacks
    pub fn hasHooks(self: *HookManager, hook_type: HookType) bool {
        return self.hooks[@intFromEnum(hook_type)].items.len > 0;
    }

    /// Get all plugin IDs that have registered hooks for a type
    pub fn getPluginIds(self: *HookManager, hook_type: HookType, buffer: [][]const u8) usize {
        const hook_list = &self.hooks[@intFromEnum(hook_type)];
        var count: usize = 0;

        for (hook_list.items) |entry| {
            if (count < buffer.len) {
                buffer[count] = entry.plugin_id;
                count += 1;
            }
        }

        return count;
    }
};

/// Sort hooks by priority (lower value = higher priority)
fn sortHooksByPriority(hooks: []HookEntry) void {
    std.mem.sort(HookEntry, hooks, {}, struct {
        fn lessThan(_: void, a: HookEntry, b: HookEntry) bool {
            return a.priority < b.priority;
        }
    }.lessThan);
}

/// Convert hook type to string
pub fn hookTypeToString(hook_type: HookType) []const u8 {
    return @tagName(hook_type);
}

/// Convert string to hook type (returns null if not found)
pub fn stringToHookType(s: []const u8) ?HookType {
    inline for (std.meta.fields(HookType)) |field| {
        if (std.mem.eql(u8, s, field.name)) {
            return @field(HookType, field.name);
        }
    }
    return null;
}

test "HookManager basic operations" {
    const allocator = std.testing.allocator;
    var manager = try HookManager.init(allocator, .{});
    defer manager.deinit();

    // Register a hook
    var call_count: usize = 0;
    const callback: HookCallback = struct {
        fn cb(ctx: ?*anyopaque) void {
            const ptr = @as(*usize, @ptrCast(@alignCast(ctx.?)));
            ptr.* += 1;
        }
    }.cb;

    try manager.register(.onDOMReady, callback, &call_count, "test_plugin", 100);
    try std.testing.expectEqual(@as(usize, 1), manager.getHookCount(.onDOMReady));
    try std.testing.expect(manager.hasHooks(.onDOMReady));

    // Trigger the hook
    manager.trigger(.onDOMReady, &call_count);
    try std.testing.expectEqual(@as(usize, 1), call_count);

    // Unregister
    try std.testing.expect(manager.unregister(.onDOMReady, callback));
    try std.testing.expect(!manager.hasHooks(.onDOMReady));
}

test "HookManager priority ordering" {
    const allocator = std.testing.allocator;
    var manager = try HookManager.init(allocator, .{});
    defer manager.deinit();

    var execution_order: [3]u8 = undefined;
    var index: usize = 0;

    const makeCallback = struct {
        fn make(id: u8) HookCallback {
            return struct {
                fn cb(ctx: ?*anyopaque) void {
                    const state = @as(*struct { order: *[3]u8, idx: *usize }, @ptrCast(@alignCast(ctx.?)));
                    state.order[state.idx.*] = id;
                    state.idx.* += 1;
                }
            }.cb;
        }
    }.make;

    // Register in reverse priority order
    try manager.register(.onPageCreated, makeCallback(3), null, "plugin3", 150); // low
    try manager.register(.onPageCreated, makeCallback(1), null, "plugin1", 50);  // high
    try manager.register(.onPageCreated, makeCallback(2), null, "plugin2", 100); // normal

    var state = struct {
        var order: [3]u8 = undefined;
        var idx: usize = 0;
    };

    manager.trigger(.onPageCreated, &.{ .order = &state.order, .idx = &state.idx });

    // Should execute in priority order: 1, 2, 3
    try std.testing.expectEqual(@as(u8, 1), state.order[0]);
    try std.testing.expectEqual(@as(u8, 2), state.order[1]);
    try std.testing.expectEqual(@as(u8, 3), state.order[2]);
}
