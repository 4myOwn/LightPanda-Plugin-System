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

//! Plugin module root for the Lightpanda Plugin System.
//!
//! This module exports all public APIs for the plugin system.
//! Import this module to access the complete plugin functionality.
//!
//! Example usage:
//! ```zig
//! const plugin = @import("plugin");
//!
//! // Initialize the core plugin system
//! var core = try plugin.Core.init(allocator, .{
//!     .plugins_dir = "./plugins",
//!     .enabled = true,
//! });
//! defer core.deinit();
//!
//! try core.start();
//! ```

pub const abi = @import("abi/abi.zig");
pub const event_bus = @import("event-bus/event_bus.zig");
pub const hook_manager = @import("hook-manager/hook_manager.zig");
pub const permission_manager = @import("permission-manager/permission_manager.zig");
pub const plugin_registry = @import("plugin-registry/plugin_registry.zig");
pub const plugin_loader = @import("plugin-loader/plugin_loader.zig");
pub const plugin_api = @import("plugin-api/plugin_api.zig");
pub const plugin_sdk = @import("plugin-sdk/plugin_sdk.zig");
pub const plugin_host = @import("plugin-host/plugin_host.zig");
pub const ipc = @import("ipc/ipc.zig");
pub const plugin_manager = @import("plugin-manager/plugin_manager.zig");
pub const core = @import("core/core.zig");

// Re-export commonly used types
pub const Core = core.Core;
pub const PluginManager = plugin_manager.PluginManager;
pub const HookManager = hook_manager.HookManager;
pub const EventBus = event_bus.EventBus;
pub const PermissionManager = permission_manager.PermissionManager;
pub const PluginAPI = plugin_api.PluginAPI;
pub const PluginLoader = plugin_loader.PluginLoader;

// Re-export important enums and structs
pub const HookType = hook_manager.HookType;
pub const Permission = permission_manager.Permission;
pub const PluginState = plugin_registry.PluginState;
pub const MessageType = ipc.MessageType;

test "Plugin system compilation test" {
    // This test ensures all modules compile correctly together
    _ = abi.current_abi_version;
    _ = event_bus.EventBus;
    _ = hook_manager.HookType.onDOMReady;
    _ = permission_manager.Permission.dom_read;
    _ = plugin_registry.PluginState.enabled;
    _ = ipc.MessageType.init;
    _ = plugin_api.api_version;
    _ = core.Core;
}
