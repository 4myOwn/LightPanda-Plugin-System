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

//! Plugin API module for the Lightpanda Plugin System.
//!
//! The Plugin API defines all public interfaces that plugins can use to
//! interact with the browser core. This is the ONLY way plugins can access
//! browser functionality - direct access to internal structures is forbidden.
//!
//! The API is designed to be:
//! - Stable across versions
//! - Type-safe
//! - Permission-aware
//! - Memory-safe (no raw pointers to internal data)

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.plugin_api);

/// API version
pub const api_version: u32 = 1;

/// Page information handle
pub const PageHandle = struct {
    id: u64,
    opaque: *anyopaque,
};

/// DOM element handle
pub const ElementHandle = struct {
    id: u64,
    page: *PageHandle,
};

/// Network request handle
pub const RequestHandle = struct {
    id: u64,
    url: []const u8,
    method: []const u8,
};

/// Network response handle
pub const ResponseHandle = struct {
    id: u64,
    request: *RequestHandle,
    status: u16,
    headers: []const u8,
};

/// Console message
pub const ConsoleMessage = struct {
    level: enum { debug, info, warn, error },
    text: []const u8,
    timestamp: u64,
    source: []const u8,
};

/// Storage types
pub const StorageType = enum {
    local,
    session,
    cookies,
};

/// API result type
pub const Result = union(enum) {
    success: []const u8,
    error: []const u8,
    not_found,
    permission_denied,
};

/// Page API namespace
pub const PageAPI = struct {
    /// Get current page URL
    url: *const fn () callconv(.C) ?[]const u8,
    /// Get current page title
    title: *const fn () callconv(.C) ?[]const u8,
    /// Get page HTML content
    html: *const fn () callconv(.C) ?[]const u8,
    /// Get page cookies
    cookies: *const fn () callconv(.C) ?[]const u8,
    /// Get page headers
    headers: *const fn () callconv(.C) ?[]const u8,
};

/// DOM API namespace
pub const DomAPI = struct {
    /// Query single element by selector
    querySelector: *const fn ([]const u8) callconv(.C) ?*ElementHandle,
    /// Query all elements by selector
    querySelectorAll: *const fn ([]const u8) callconv(.C) []*ElementHandle,
    /// Get element text content
    text: *const fn (*ElementHandle) callconv(.C) ?[]const u8,
    /// Get element attribute
    attribute: *const fn (*ElementHandle, []const u8) callconv(.C) ?[]const u8,
};

/// CSS API namespace
pub const CssAPI = struct {
    /// Get computed styles for element
    styles: *const fn (*ElementHandle) callconv(.C) ?[]const u8,
};

/// Network API namespace
pub const NetworkAPI = struct {
    /// Get all requests
    requests: *const fn () callconv(.C) []*RequestHandle,
    /// Get all responses
    responses: *const fn () callconv(.C) []*ResponseHandle,
};

/// Console API namespace
pub const ConsoleAPI = struct {
    /// Get all console messages
    logs: *const fn () callconv(.C) []*ConsoleMessage,
};

/// Storage API namespace
pub const StorageAPI = struct {
    /// Read from storage
    read: *const fn (StorageType, []const u8) callconv(.C) ?[]const u8,
    /// Write to storage
    write: *const fn (StorageType, []const u8, []const u8) callconv(.C) bool,
};

/// Settings API namespace
pub const SettingsAPI = struct {
    /// Read setting
    read: *const fn ([]const u8) callconv(.C) ?[]const u8,
    /// Write setting
    write: *const fn ([]const u8, []const u8) callconv(.C) bool,
};

/// Events API namespace
pub const EventsAPI = struct {
    /// Emit an event
    emit: *const fn ([]const u8, ?[]const u8) callconv(.C) void,
    /// Subscribe to an event
    subscribe: *const fn ([]const u8, *const fn ([]const u8) callconv(.C) void) callconv(.C) ?u64,
    /// Unsubscribe from an event
    unsubscribe: *const fn (u64) callconv(.C) void,
};

/// Logger API namespace
pub const LoggerAPI = struct {
    /// Log info message
    info: *const fn ([]const u8) callconv(.C) void,
    /// Log warning message
    warn: *const fn ([]const u8) callconv(.C) void,
    /// Log error message
    error: *const fn ([]const u8) callconv(.C) void,
};

/// Complete Plugin API structure
pub const PluginAPI = struct {
    /// API version
    version: u32,
    /// Page operations
    page: PageAPI,
    /// DOM operations
    dom: DomAPI,
    /// CSS operations
    css: CssAPI,
    /// Network operations
    network: NetworkAPI,
    /// Console operations
    console: ConsoleAPI,
    /// Storage operations
    storage: StorageAPI,
    /// Settings operations
    settings: SettingsAPI,
    /// Events operations
    events: EventsAPI,
    /// Logging operations
    logger: LoggerAPI,
};

/// Create a new Plugin API instance
pub fn createPluginAPI(allocator: Allocator) !PluginAPI {
    _ = allocator;
    
    // In production, these would be implemented by the Core
    // For now, we provide stub implementations
    return .{
        .version = api_version,
        .page = .{
            .url = stubUrl,
            .title = stubTitle,
            .html = stubHtml,
            .cookies = stubCookies,
            .headers = stubHeaders,
        },
        .dom = .{
            .querySelector = stubQuerySelector,
            .querySelectorAll = stubQuerySelectorAll,
            .text = stubText,
            .attribute = stubAttribute,
        },
        .css = .{
            .styles = stubStyles,
        },
        .network = .{
            .requests = stubRequests,
            .responses = stubResponses,
        },
        .console = .{
            .logs = stubLogs,
        },
        .storage = .{
            .read = stubStorageRead,
            .write = stubStorageWrite,
        },
        .settings = .{
            .read = stubSettingsRead,
            .write = stubSettingsWrite,
        },
        .events = .{
            .emit = stubEmit,
            .subscribe = stubSubscribe,
            .unsubscribe = stubUnsubscribe,
        },
        .logger = .{
            .info = stubLogInfo,
            .warn = stubLogWarn,
            .error = stubLogError,
        },
    };
}

// Stub implementations
fn stubUrl() callconv(.C) ?[]const u8 { return null; }
fn stubTitle() callconv(.C) ?[]const u8 { return null; }
fn stubHtml() callconv(.C) ?[]const u8 { return null; }
fn stubCookies() callconv(.C) ?[]const u8 { return null; }
fn stubHeaders() callconv(.C) ?[]const u8 { return null; }

fn stubQuerySelector(_: []const u8) callconv(.C) ?*ElementHandle { return null; }
fn stubQuerySelectorAll(_: []const u8) callconv(.C) []*ElementHandle { return &.{}; }
fn stubText(_: *ElementHandle) callconv(.C) ?[]const u8 { return null; }
fn stubAttribute(_: *ElementHandle, _: []const u8) callconv(.C) ?[]const u8 { return null; }

fn stubStyles(_: *ElementHandle) callconv(.C) ?[]const u8 { return null; }

fn stubRequests() callconv(.C) []*RequestHandle { return &.{}; }
fn stubResponses() callconv(.C) []*ResponseHandle { return &.{}; }

fn stubLogs() callconv(.C) []*ConsoleMessage { return &.{}; }

fn stubStorageRead(_: StorageType, _: []const u8) callconv(.C) ?[]const u8 { return null; }
fn stubStorageWrite(_: StorageType, _: []const u8, _: []const u8) callconv(.C) bool { return false; }

fn stubSettingsRead(_: []const u8) callconv(.C) ?[]const u8 { return null; }
fn stubSettingsWrite(_: []const u8, _: []const u8) callconv(.C) bool { return false; }

fn stubEmit(_: []const u8, _: ?[]const u8) callconv(.C) void {}
fn stubSubscribe(_: []const u8, _: anytype) callconv(.C) ?u64 { return null; }
fn stubUnsubscribe(_: u64) callconv(.C) void {}

fn stubLogInfo(_: []const u8) callconv(.C) void { log.info("{s}", .{""}); }
fn stubLogWarn(_: []const u8) callconv(.C) void { log.warn("{s}", .{""}); }
fn stubLogError(_: []const u8) callconv(.C) void { log.err("{s}", .{""}); }

test "PluginAPI creation" {
    const api = try createPluginAPI(std.testing.allocator);
    try std.testing.expectEqual(api_version, api.version);
}
