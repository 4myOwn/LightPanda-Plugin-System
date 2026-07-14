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

//! Plugin Loader module for the Lightpanda Plugin System.
//!
//! The Plugin Loader handles dynamic library loading and unloading,
//! symbol resolution, and entry point discovery.
//!
//! Supported formats:
//! - Linux: .so
//! - Windows: .dll
//! - macOS: .dylib

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.plugin_loader);
const abi = @import("../abi/abi.zig");

/// Dynamic library handle
pub const LibraryHandle = *anyopaque;

/// Plugin entry points
pub const EntryPointPoints = struct {
    init: *const fn (*anyopaque) callconv(.C) abi.InitResult,
    shutdown: *const fn (abi.ShutdownReason) callconv(.C) void,
    get_metadata: *const fn () callconv(.C) *const abi.PluginMetadata,
    get_api_version: *const fn () callconv(.C) u32,
};

/// Plugin Loader configuration
pub const Config = struct {
    /// Whether to use sandboxing (future: separate process)
    use_sandbox: bool = false,
    /// Sandbox command (if sandboxing enabled)
    sandbox_command: ?[]const u8 = null,
};

/// Main Plugin Loader structure
pub const PluginLoader = struct {
    allocator: Allocator,
    config: Config,
    loaded_libraries: std.StringHashMap(LibraryHandle),

    /// Initialize the Plugin Loader
    pub fn init(allocator: Allocator, config: Config) !PluginLoader {
        return .{
            .allocator = allocator,
            .config = config,
            .loaded_libraries = std.StringHashMap(LibraryHandle).init(allocator),
        };
    }

    /// Deinitialize the Plugin Loader
    pub fn deinit(self: *PluginLoader) void {
        // Unload all libraries
        var it = self.loaded_libraries.iterator();
        while (it.next()) |entry| {
            unloadLibrary(entry.value_ptr.*) catch {};
            self.allocator.free(entry.key_ptr.*);
        }
        self.loaded_libraries.deinit();
    }

    /// Load a plugin library
    pub fn load(self: *PluginLoader, path: []const u8) !LibraryHandle {
        // Check if already loaded
        if (self.loaded_libraries.get(path)) |handle| {
            return handle;
        }

        const handle = try loadLibrary(path);

        // Store handle
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);

        try self.loaded_libraries.put(key, handle);
        log.info("Loaded plugin library: {s}", .{path});

        return handle;
    }

    /// Unload a plugin library
    pub fn unload(self: *PluginLoader, handle: LibraryHandle) !void {
        // Find and remove from map
        var it = self.loaded_libraries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* == handle) {
                try unloadLibrary(handle);
                self.allocator.free(entry.key_ptr.*);
                _ = self.loaded_libraries.remove(entry.key_ptr.*);
                log.info("Unloaded plugin library", .{});
                return;
            }
        }

        // If not found in map, just unload
        try unloadLibrary(handle);
    }

    /// Get entry points from a loaded library
    pub fn getEntryPoints(self: *PluginLoader, handle: LibraryHandle) !EntryPointPoints {
        _ = self;

        const init_fn = try getSymbol(*const fn (*anyopaque) callconv(.C) abi.InitResult, handle, "plugin_init");
        const shutdown_fn = try getSymbol(*const fn (abi.ShutdownReason) callconv(.C) void, handle, "plugin_shutdown");
        const metadata_fn = try getSymbol(*const fn () callconv(.C) *const abi.PluginMetadata, handle, "plugin_metadata");
        const api_version_fn = try getSymbol(*const fn () callconv(.C) u32, handle, "plugin_api_version");

        return .{
            .init = init_fn,
            .shutdown = shutdown_fn,
            .get_metadata = metadata_fn,
            .get_api_version = api_version_fn,
        };
    }

    /// Validate plugin binary
    pub fn validatePlugin(path: []const u8) !bool {
        _ = path;
        // TODO: Validate magic number and structure
        return true;
    }
};

/// Load a dynamic library (platform-specific)
fn loadLibrary(path: []const u8) !LibraryHandle {
    switch (std.os.target.os.tag) {
        .linux => {
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
        .macos => {
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
            const HANDLE = windows.HANDLE;
            
            const kernel32 = struct {
                extern "kernel32" fn LoadLibraryA(lpFileName: [*:0]u8) ?HANDLE;
                extern "kernel32" fn GetLastError() u32;
            };

            const path_z = std.os.windows.toZString(path) catch return error.LibraryLoadFailed;
            const handle = kernel32.LoadLibraryA(path_z) orelse {
                log.err("LoadLibrary failed: {}", .{kernel32.GetLastError()});
                return error.LibraryLoadFailed;
            };
            return @ptrCast(@alignCast(handle));
        },
        else => {
            log.err("Unsupported platform for dynamic libraries", .{});
            return error.UnsupportedPlatform;
        },
    }
}

/// Unload a dynamic library (platform-specific)
fn unloadLibrary(handle: LibraryHandle) !void {
    switch (std.os.target.os.tag) {
        .linux, .macos => {
            const C = extern struct {
                extern "c" fn dlclose(*anyopaque) c_int;
                extern "c" fn dlerror() [*:0]u8;
            };

            const result = C.dlclose(@ptrCast(handle));
            if (result != 0) {
                log.err("dlclose failed: {s}", .{C.dlerror()});
                return error.LibraryUnloadFailed;
            }
        },
        .windows => {
            const windows = std.os.windows;
            const kernel32 = struct {
                extern "kernel32" fn FreeLibrary(hModule: windows.HMODULE) callconv(windows.WINAPI) c_int;
            };

            const result = kernel32.FreeLibrary(@ptrCast(@alignCast(handle)));
            if (result == 0) {
                log.err("FreeLibrary failed", .{});
                return error.LibraryUnloadFailed;
            }
        },
        else => {
            return error.UnsupportedPlatform;
        },
    }
}

/// Get a symbol from a loaded library (platform-specific)
fn getSymbol(comptime T: type, handle: LibraryHandle, name: []const u8) !T {
    const name_z = std.os.windows.toZString(name) catch return error.SymbolNotFound;

    switch (std.os.target.os.tag) {
        .linux, .macos => {
            const C = extern struct {
                extern "c" fn dlsym(*anyopaque, [*:0]u8) ?*anyopaque;
                extern "c" fn dlerror() [*:0]u8;
            };

            const sym = C.dlsym(@ptrCast(handle), name_z) orelse {
                log.err("Symbol {s} not found: {s}", .{ name, C.dlerror() });
                return error.SymbolNotFound;
            };
            return @ptrCast(sym);
        },
        .windows => {
            const windows = std.os.windows;
            const kernel32 = struct {
                extern "kernel32" fn GetProcAddress(hModule: windows.HMODULE, lpProcName: [*:0]u8) ?windows.FARPROC;
            };

            const sym = kernel32.GetProcAddress(@ptrCast(@alignCast(handle)), name_z) orelse {
                log.err("Symbol {s} not found", .{name});
                return error.SymbolNotFound;
            };
            return @ptrCast(sym);
        },
        else => {
            return error.UnsupportedPlatform;
        },
    }
}

test "PluginLoader basic operations" {
    const allocator = std.testing.allocator;
    var loader = try PluginLoader.init(allocator, .{});
    defer loader.deinit();

    // Note: Actual library loading tests would require compiled plugin binaries
    // This test verifies initialization and cleanup
    try std.testing.expectEqual(@as(usize, 0), loader.loaded_libraries.count());
}
