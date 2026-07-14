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

//! Plugin Host module for the Lightpanda Plugin System.
//!
//! The Plugin Host runs as a separate process that loads and executes
//! plugins in an isolated environment. This provides:
//! - Process isolation
//! - Crash containment
//! - Security boundaries
//!
//! The host communicates with the Core via IPC.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.plugin_host);

const abi = @import("../abi/abi.zig");
const ipc = @import("../ipc/ipc.zig");

/// Plugin Host configuration
pub const Config = struct {
    /// Path to plugin library
    plugin_path: []const u8,
    /// Whether to enable debug logging
    debug_logging: bool = false,
};

/// Main Plugin Host structure
pub const PluginHost = struct {
    allocator: Allocator,
    config: Config,
    ipc_channel: ?ipc.Channel,
    plugin_handle: ?*anyopaque,
    entry_points: ?abi.PluginEntryPoints,
    running: bool,

    /// Initialize the Plugin Host
    pub fn init(allocator: Allocator, config: Config) !PluginHost {
        return .{
            .allocator = allocator,
            .config = config,
            .ipc_channel = null,
            .plugin_handle = null,
            .entry_points = null,
            .running = false,
        };
    }

    /// Deinitialize the Plugin Host
    pub fn deinit(self: *PluginHost) void {
        self.stop();
    }

    /// Start the Plugin Host
    pub fn start(self: *PluginHost) !void {
        if (self.running) {
            return error.AlreadyRunning;
        }

        // Load the plugin
        self.plugin_handle = try loadPlugin(self.config.plugin_path);
        
        // Get entry points
        self.entry_points = try getEntryPoints(self.plugin_handle.?);

        self.running = true;
        log.info("Plugin Host started for {s}", .{self.config.plugin_path});
    }

    /// Stop the Plugin Host
    pub fn stop(self: *PluginHost) void {
        if (!self.running) {
            return;
        }

        // Shutdown plugin if loaded
        if (self.entry_points) |ep| {
            ep.shutdown(.normal);
        }

        // Unload plugin
        if (self.plugin_handle) |handle| {
            unloadPlugin(handle) catch {};
        }

        self.running = false;
        log.info("Plugin Host stopped", .{});
    }

    /// Run the main event loop
    pub fn run(self: *PluginHost) !void {
        try self.start();
        defer self.stop();

        var buffer: [4096]u8 = undefined;

        while (self.running) {
            // Wait for IPC message
            const msg = self.ipc_channel.?.receive(&buffer) catch |err| {
                if (err == error.ConnectionClosed) {
                    log.info("IPC connection closed, shutting down", .{});
                    break;
                }
                log.err("IPC receive error: {}", .{err});
                continue;
            };

            // Handle message
            try self.handleMessage(msg);
        }
    }

    /// Handle an IPC message
    fn handleMessage(self: *PluginHost, msg: ipc.Message) !void {
        switch (msg.header.message_type) {
            .init => try self.handleInit(msg.payload),
            .shutdown => try self.handleShutdown(msg.payload),
            .api_call => try self.handleApiCall(msg.payload),
            .hook_trigger => try self.handleHookTrigger(msg.payload),
            else => {
                log.warn("Unknown message type: {s}", .{@tagName(msg.header.message_type)});
            },
        }
    }

    /// Handle init message
    fn handleInit(self: *PluginHost, payload: []const u8) !void {
        _ = payload;
        
        if (self.entry_points) |ep| {
            const result = ep.init(null);
            
            // Send response
            try self.sendResponse(.{
                .message_type = .api_response,
                .message_id = 0,
                .payload_size = 1,
                .sender_id = 0,
            }, &.{@intFromEnum(result)});
        }
    }

    /// Handle shutdown message
    fn handleShutdown(self: *PluginHost, payload: []const u8) !void {
        _ = payload;
        
        const reason: abi.ShutdownReason = if (payload.len > 0)
            @enumFromInt(payload[0])
        else
            .normal;

        if (self.entry_points) |ep| {
            ep.shutdown(reason);
        }

        self.running = false;
    }

    /// Handle API call message
    fn handleApiCall(self: *PluginHost, payload: []const u8) !void {
        _ = self;
        _ = payload;
        // TODO: Implement API call handling
    }

    /// Handle hook trigger message
    fn handleHookTrigger(self: *PluginHost, payload: []const u8) !void {
        _ = self;
        _ = payload;
        // TODO: Implement hook trigger handling
    }

    /// Send IPC response
    fn sendResponse(self: *PluginHost, header: ipc.MessageHeader, data: []const u8) !void {
        _ = self;
        _ = header;
        _ = data;
        // TODO: Implement response sending
    }

    /// Load a plugin library
    fn loadPlugin(path: []const u8) !*anyopaque {
        // Use platform-specific dynamic loading
        switch (std.os.target.os.tag) {
            .linux, .macos => {
                const C = extern struct {
                    pub const RTLD_LAZY = 1;
                    pub const RTLD_LOCAL = 8;
                    extern "c" fn dlopen(*const u8, c_int) ?*anyopaque;
                    extern "c" fn dlerror() [*:0]u8;
                };

                const ptr = C.dlopen(path.ptr, C.RTLD_LAZY | C.RTLD_LOCAL) orelse {
                    log.err("dlopen failed: {s}", .{C.dlerror()});
                    return error.LibraryLoadFailed;
                };
                return @ptrCast(ptr);
            },
            .windows => {
                const windows = std.os.windows;
                const kernel32 = struct {
                    extern "kernel32" fn LoadLibraryA(lpFileName: [*:0]u8) ?windows.HANDLE;
                };

                const path_z = std.os.windows.toZString(path) catch return error.LibraryLoadFailed;
                const handle = kernel32.LoadLibraryA(path_z) orelse {
                    return error.LibraryLoadFailed;
                };
                return @ptrCast(@alignCast(handle));
            },
            else => {
                return error.UnsupportedPlatform;
            },
        }
    }

    /// Get plugin entry points
    fn getEntryPoints(handle: *anyopaque) !abi.PluginEntryPoints {
        switch (std.os.target.os.tag) {
            .linux, .macos => {
                const C = extern struct {
                    extern "c" fn dlsym(*anyopaque, [*:0]u8) ?*anyopaque;
                    extern "c" fn dlerror() [*:0]u8;
                };

                const init_fn = C.dlsym(@ptrCast(handle, "plugin_init")) orelse return error.SymbolNotFound;
                const shutdown_fn = C.dlsym(@ptrCast(handle), "plugin_shutdown") orelse return error.SymbolNotFound;
                const metadata_fn = C.dlsym(@ptrCast(handle), "plugin_metadata") orelse return error.SymbolNotFound;
                const api_version_fn = C.dlsym(@ptrCast(handle), "plugin_api_version") orelse return error.SymbolNotFound;

                return .{
                    .init = @ptrCast(init_fn),
                    .shutdown = @ptrCast(shutdown_fn),
                    .get_metadata = @ptrCast(metadata_fn),
                    .get_api_version = @ptrCast(api_version_fn),
                };
            },
            .windows => {
                const windows = std.os.windows;
                const kernel32 = struct {
                    extern "kernel32" fn GetProcAddress(hModule: windows.HMODULE, lpProcName: [*:0]u8) ?windows.FARPROC;
                };

                const init_fn = kernel32.GetProcAddress(@ptrCast(@alignCast(handle)), "plugin_init") orelse return error.SymbolNotFound;
                const shutdown_fn = kernel32.GetProcAddress(@ptrCast(@alignCast(handle)), "plugin_shutdown") orelse return error.SymbolNotFound;
                const metadata_fn = kernel32.GetProcAddress(@ptrCast(@alignCast(handle)), "plugin_metadata") orelse return error.SymbolNotFound;
                const api_version_fn = kernel32.GetProcAddress(@ptrCast(@alignCast(handle)), "plugin_api_version") orelse return error.SymbolNotFound;

                return .{
                    .init = @ptrCast(init_fn),
                    .shutdown = @ptrCast(shutdown_fn),
                    .get_metadata = @ptrCast(metadata_fn),
                    .get_api_version = @ptrCast(api_version_fn),
                };
            },
            else => {
                return error.UnsupportedPlatform;
            },
        }
    }

    /// Unload a plugin library
    fn unloadPlugin(handle: *anyopaque) !void {
        switch (std.os.target.os.tag) {
            .linux, .macos => {
                const C = extern struct {
                    extern "c" fn dlclose(*anyopaque) c_int;
                };
                _ = C.dlclose(@ptrCast(handle));
            },
            .windows => {
                const windows = std.os.windows;
                const kernel32 = struct {
                    extern "kernel32" fn FreeLibrary(hModule: windows.HMODULE) callconv(windows.WINAPI) c_int;
                };
                _ = kernel32.FreeLibrary(@ptrCast(@alignCast(handle)));
            },
            else => {
                return error.UnsupportedPlatform;
            },
        }
    }
};

/// Main entry point for plugin host executable
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: plugin-host <plugin_path>\n", .{});
        std.process.exit(1);
    }

    var host = try PluginHost.init(allocator, .{
        .plugin_path = args[1],
        .debug_logging = false,
    });
    defer host.deinit();

    try host.run();
}

test "PluginHost initialization" {
    const allocator = std.testing.allocator;
    var host = try PluginHost.init(allocator, .{
        .plugin_path = "/tmp/test.so",
        .debug_logging = false,
    });
    defer host.deinit();

    try std.testing.expect(!host.running);
}
