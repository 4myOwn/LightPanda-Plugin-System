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

//! Permission Manager module for the Lightpanda Plugin System.
//!
//! The Permission Manager controls access to browser APIs and resources.
//! Each plugin must declare its required permissions in its manifest.
//! Permissions are checked at runtime before API calls are executed.
//!
//! Inspired by Chrome Extensions permission system.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.permission_manager);

/// All available permissions
pub const Permission = enum {
    /// DOM access permissions
    dom_read,
    dom_write,
    dom_manipulate,

    /// Network permissions
    network_read,
    network_write,
    network_intercept,

    /// Filesystem permissions
    filesystem_read,
    filesystem_write,

    /// Clipboard permissions
    clipboard_read,
    clipboard_write,

    /// Console permissions
    console_read,
    console_write,

    /// Cookie permissions
    cookies_read,
    cookies_write,

    /// Storage permissions
    storage_read,
    storage_write,

    /// Screenshot permissions
    screenshot_capture,

    /// Settings permissions
    settings_read,
    settings_write,

    /// Event permissions
    events_emit,
    events_subscribe,

    /// Logging permissions
    logging,
};

/// Permission state
pub const PermissionState = enum {
    granted,
    denied,
    prompt,
};

/// Permission request result
pub const PermissionResult = struct {
    permission: Permission,
    state: PermissionState,
};

/// Permission check result
pub const CheckResult = union(enum) {
    allowed,
    denied: []const u8,
    missing: Permission,
};

/// Permission set for a plugin
pub const PermissionSet = struct {
    bits: u64 = 0,

    pub fn has(self: PermissionSet, permission: Permission) bool {
        const bit = @as(u64, 1) << @intFromEnum(permission);
        return (self.bits & bit) != 0;
    }

    pub fn add(self: *PermissionSet, permission: Permission) void {
        const bit = @as(u64, 1) << @intFromEnum(permission);
        self.bits |= bit;
    }

    pub fn remove(self: *PermissionSet, permission: Permission) void {
        const bit = @as(u64, 1) << @intFromEnum(permission);
        self.bits &= ~bit;
    }

    pub fn clear(self: *PermissionSet) void {
        self.bits = 0;
    }

    pub fn all(self: PermissionSet) bool {
        // Check if all defined permissions are set
        const all_bits = (@as(u64, 1) << std.meta.fields(Permission).len) - 1;
        return (self.bits & all_bits) == all_bits;
    }

    pub fn isEmpty(self: PermissionSet) bool {
        return self.bits == 0;
    }

    /// Convert to array of permissions
    pub fn toArray(self: PermissionSet, allocator: Allocator) ![]Permission {
        var list = std.ArrayList(Permission).init(allocator);
        errdefer list.deinit();

        inline for (std.meta.fields(Permission)) |field| {
            const perm = @field(Permission, field.name);
            if (self.has(perm)) {
                try list.append(perm);
            }
        }

        return list.toOwnedSlice();
    }
};

/// Permission grant entry
pub const PermissionGrant = struct {
    plugin_id: []const u8,
    permissions: PermissionSet,
    granted_at: u64,
    expires_at: ?u64 = null,
};

/// Permission manager configuration
pub const Config = struct {
    /// Default permission state for unknown plugins
    default_state: PermissionState = .denied,
    /// Whether to log permission checks
    log_checks: bool = false,
    /// Whether to allow prompting for permissions
    allow_prompt: bool = false,
};

/// Main Permission Manager structure
pub const PermissionManager = struct {
    allocator: Allocator,
    config: Config,
    grants: std.StringHashMap(PermissionGrant),
    current_time: *const fn () callconv(.C) u64,

    /// Initialize the Permission Manager
    pub fn init(allocator: Allocator, config: Config) !PermissionManager {
        return .{
            .allocator = allocator,
            .config = config,
            .grants = std.StringHashMap(PermissionGrant).init(allocator),
            .current_time = getDefaultTime,
        };
    }

    /// Deinitialize the Permission Manager
    pub fn deinit(self: *PermissionManager) void {
        var it = self.grants.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.grants.deinit();
    }

    /// Grant permissions to a plugin
    pub fn grant(self: *PermissionManager, plugin_id: []const u8, permissions: PermissionSet) !void {
        const key = try self.allocator.dupe(u8, plugin_id);
        errdefer self.allocator.free(key);

        const existing = self.grants.getEntry(plugin_id);
        if (existing) |entry| {
            // Merge permissions
            var merged = entry.value_ptr.permissions;
            merged.bits |= permissions.bits;
            entry.value_ptr.permissions = merged;
        } else {
            try self.grants.put(key, .{
                .plugin_id = key,
                .permissions = permissions,
                .granted_at = self.current_time(),
                .expires_at = null,
            });
        }

        log.info("Granted permissions to plugin {s}", .{plugin_id});
    }

    /// Revoke permissions from a plugin
    pub fn revoke(self: *PermissionManager, plugin_id: []const u8, permissions: PermissionSet) void {
        const entry = self.grants.getEntry(plugin_id) orelse return;

        var updated = entry.value_ptr.permissions;
        updated.bits &= ~permissions.bits;
        entry.value_ptr.permissions = updated;

        log.info("Revoked permissions from plugin {s}", .{plugin_id});
    }

    /// Revoke all permissions from a plugin
    pub fn revokeAll(self: *PermissionManager, plugin_id: []const u8) void {
        _ = self.grants.remove(plugin_id);
        log.info("Revoked all permissions from plugin {s}", .{plugin_id});
    }

    /// Check if a plugin has a specific permission
    pub fn check(self: *PermissionManager, plugin_id: []const u8, permission: Permission) CheckResult {
        const grant = self.grants.get(plugin_id) orelse {
            if (self.config.log_checks) {
                log.debug("Permission {s} check failed for {s}: no grant", .{
                    @tagName(permission),
                    plugin_id,
                });
            }
            return .{ .missing = permission };
        };

        if (grant.permissions.has(permission)) {
            if (self.config.log_checks) {
                log.debug("Permission {s} granted for {s}", .{
                    @tagName(permission),
                    plugin_id,
                });
            }
            return .allowed;
        }

        if (self.config.log_checks) {
            log.debug("Permission {s} denied for {s}", .{
                @tagName(permission),
                plugin_id,
            });
        }
        return .{ .denied = "Permission not granted" };
    }

    /// Check multiple permissions at once
    pub fn checkMultiple(
        self: *PermissionManager,
        plugin_id: []const u8,
        permissions: PermissionSet,
    ) CheckResult {
        inline for (std.meta.fields(Permission)) |field| {
            const perm = @field(Permission, field.name);
            if (permissions.has(perm)) {
                const result = self.check(plugin_id, perm);
                if (result != .allowed) {
                    return result;
                }
            }
        }
        return .allowed;
    }

    /// Get all permissions for a plugin
    pub fn getPermissions(self: *PermissionManager, plugin_id: []const u8) ?PermissionSet {
        const grant = self.grants.get(plugin_id) orelse return null;
        return grant.permissions;
    }

    /// Set the current time function (for testing)
    pub fn setCurrentTimeFn(self: *PermissionManager, fn_ptr: *const fn () callconv(.C) u64) void {
        self.current_time = fn_ptr;
    }

    /// Parse permission from string
    pub fn parsePermission(s: []const u8) ?Permission {
        inline for (std.meta.fields(Permission)) |field| {
            if (std.mem.eql(u8, s, field.name)) {
                return @field(Permission, field.name);
            }
        }
        return null;
    }

    /// Convert permission to string
    pub fn permissionToString(permission: Permission) []const u8 {
        return @tagName(permission);
    }

    /// Create a permission set from an array of permissions
    pub fn createPermissionSet(permissions: []const Permission) PermissionSet {
        var set = PermissionSet{};
        for (permissions) |perm| {
            set.add(perm);
        }
        return set;
    }

    /// Create a permission set from strings
    pub fn createPermissionSetFromStrings(allocator: Allocator, strings: [][]const u8) !PermissionSet {
        var set = PermissionSet{};
        for (strings) |s| {
            if (parsePermission(s)) |perm| {
                set.add(perm);
            }
        }
        return set;
    }
};

/// Default time function
fn getDefaultTime() callconv(.C) u64 {
    return @intCast(std.time.timestamp());
}

test "PermissionSet basic operations" {
    var set = PermissionSet{};
    try std.testing.expect(set.isEmpty());

    set.add(.dom_read);
    try std.testing.expect(set.has(.dom_read));
    try std.testing.expect(!set.has(.dom_write));

    set.add(.dom_write);
    try std.testing.expect(set.has(.dom_write));

    set.remove(.dom_read);
    try std.testing.expect(!set.has(.dom_read));
    try std.testing.expect(set.has(.dom_write));

    set.clear();
    try std.testing.expect(set.isEmpty());
}

test "PermissionManager grant and check" {
    const allocator = std.testing.allocator;
    var manager = try PermissionManager.init(allocator, .{});
    defer manager.deinit();

    // Grant permissions
    var perms = PermissionSet{};
    perms.add(.dom_read);
    perms.add(.network_read);

    try manager.grant("test_plugin", perms);

    // Check permissions
    try std.testing.expectEqual(CheckResult.allowed, manager.check("test_plugin", .dom_read));
    try std.testing.expectEqual(CheckResult.allowed, manager.check("test_plugin", .network_read));
    try std.testing.expect(manager.check("test_plugin", .dom_write) != .allowed);

    // Revoke permission
    var revoke_perms = PermissionSet{};
    revoke_perms.add(.dom_read);
    manager.revoke("test_plugin", revoke_perms);

    try std.testing.expect(manager.check("test_plugin", .dom_read) != .allowed);
    try std.testing.expectEqual(CheckResult.allowed, manager.check("test_plugin", .network_read));
}

test "PermissionManager revoke all" {
    const allocator = std.testing.allocator;
    var manager = try PermissionManager.init(allocator, .{});
    defer manager.deinit();

    // Grant permissions
    var perms = PermissionSet{};
    perms.add(.dom_read);
    try manager.grant("test_plugin", perms);

    // Revoke all
    manager.revokeAll("test_plugin");

    try std.testing.expect(manager.check("test_plugin", .dom_read) != .allowed);
}
