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

//! IPC (Inter-Process Communication) module for the Lightpanda Plugin System.
//!
//! The IPC module provides communication between the Core and plugins
//! when running in sandboxed mode (separate processes).
//!
//! This enables:
//! - Process isolation for plugins
//! - Crash containment
//! - Security boundaries
//!
//! Future: Will support WASM plugin execution.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.ipc);

/// Message types for IPC communication
pub const MessageType = enum(u8) {
    /// Initialize plugin
    init = 1,
    /// Shutdown plugin
    shutdown = 2,
    /// API call request
    api_call = 3,
    /// API call response
    api_response = 4,
    /// Hook trigger
    hook_trigger = 5,
    /// Hook response
    hook_response = 6,
    /// Event notification
    event = 7,
    /// Log message
    log = 8,
    /// Error notification
    error = 9,
};

/// IPC Message header
pub const MessageHeader = packed struct {
    /// Message type
    message_type: MessageType,
    /// Message ID for correlation
    message_id: u32,
    /// Payload size in bytes
    payload_size: u32,
    /// Sender ID (plugin ID or core)
    sender_id: u8,
    /// Reserved for alignment
    _reserved: u8 = 0,
};

/// IPC Channel configuration
pub const ChannelConfig = struct {
    /// Buffer size for messages
    buffer_size: usize = 4096,
    /// Timeout for operations (milliseconds)
    timeout_ms: u32 = 5000,
    /// Whether to use async I/O
    async_io: bool = true,
};

/// IPC Channel for communication
pub const Channel = struct {
    allocator: Allocator,
    config: ChannelConfig,
    read_fd: std.fs.File,
    write_fd: std.fs.File,
    message_counter: u32,

    /// Create a new IPC channel
    pub fn init(allocator: Allocator, config: ChannelConfig, read_fd: std.fs.File, write_fd: std.fs.File) Channel {
        return .{
            .allocator = allocator,
            .config = config,
            .read_fd = read_fd,
            .write_fd = write_fd,
            .message_counter = 0,
        };
    }

    /// Send a message
    pub fn send(self: *Channel, message_type: MessageType, payload: []const u8) !void {
        self.message_counter += 1;

        const header = MessageHeader{
            .message_type = message_type,
            .message_id = self.message_counter,
            .payload_size = @intCast(payload.len),
            .sender_id = 0,
        };

        // Write header
        var header_bytes = std.mem.asBytes(&header);
        _ = try self.write_fd.write(header_bytes);

        // Write payload
        if (payload.len > 0) {
            _ = try self.write_fd.write(payload);
        }
    }

    /// Receive a message
    pub fn receive(self: *Channel, buffer: []u8) !Message {
        // Read header
        var header: MessageHeader = undefined;
        var header_bytes = std.mem.asBytes(&header);
        
        const header_read = try self.read_fd.read(header_bytes);
        if (header_read == 0) {
            return error.ConnectionClosed;
        }

        if (header_read != header_bytes.len) {
            return error.InvalidMessage;
        }

        // Read payload
        var payload: []u8 = &.{};
        if (header.payload_size > 0) {
            if (header.payload_size > buffer.len) {
                return error.BufferTooSmall;
            }
            const payload_read = try self.read_fd.read(buffer[0..header.payload_size]);
            if (payload_read != header.payload_size) {
                return error.InvalidMessage;
            }
            payload = buffer[0..header.payload_size];
        }

        return .{
            .header = header,
            .payload = payload,
        };
    }

    /// Send API call and wait for response
    pub fn callApi(self: *Channel, api_name: []const u8, args: []const u8) ![]const u8 {
        _ = self;
        _ = api_name;
        _ = args;
        // TODO: Implement RPC-style call
        return error.NotImplemented;
    }

    /// Close the channel
    pub fn close(self: *Channel) void {
        self.read_fd.close();
        self.write_fd.close();
    }
};

/// IPC Message structure
pub const Message = struct {
    header: MessageHeader,
    payload: []const u8,

    /// Get message type
    pub fn getType(self: Message) MessageType {
        return self.header.message_type;
    }

    /// Get message ID
    pub fn getId(self: Message) u32 {
        return self.header.message_id;
    }

    /// Check if message has payload
    pub fn hasPayload(self: Message) bool {
        return self.payload.len > 0;
    }
};

/// Plugin Host process manager
pub const PluginHost = struct {
    allocator: Allocator,
    plugin_id: []const u8,
    process: ?std.process.Child,
    channel: ?Channel,
    running: bool,

    /// Create a new plugin host
    pub fn init(allocator: Allocator, plugin_id: []const u8) PluginHost {
        return .{
            .allocator = allocator,
            .plugin_id = plugin_id,
            .process = null,
            .channel = null,
            .running = false,
        };
    }

    /// Start the plugin host process
    pub fn start(self: *PluginHost, plugin_path: []const u8) !void {
        if (self.running) {
            return error.AlreadyRunning;
        }

        // Create pipes for IPC
        var pipe_in: [2]std.os.fd_t = undefined;
        var pipe_out: [2]std.os.fd_t = undefined;

        std.os.pipe(&pipe_in) catch |err| {
            log.err("Failed to create input pipe: {}", .{err});
            return err;
        };

        std.os.pipe(&pipe_out) catch |err| {
            log.err("Failed to create output pipe: {}", .{err});
            return err;
        };

        // Spawn plugin host process
        const argv = [_][]const u8{ "plugin-host", plugin_path };
        
        self.process = std.process.Child.init(&argv, self.allocator);
        self.process.?.stdin_behavior = .Pipe;
        self.process.?.stdout_behavior = .Pipe;
        
        try self.process.?.spawn();

        // Create IPC channel
        self.channel = Channel.init(
            self.allocator,
            .{},
            std.fs.File{ .handle = pipe_out[0] },
            std.fs.File{ .handle = pipe_in[1] },
        );

        self.running = true;
        log.info("Started plugin host for {s}", .{self.plugin_id});
    }

    /// Stop the plugin host process
    pub fn stop(self: *PluginHost) void {
        if (!self.running) {
            return;
        }

        if (self.channel) |*ch| {
            ch.close();
        }

        if (self.process) |*proc| {
            proc.terminate() catch {};
            proc.wait() catch {};
            proc.deinit();
        }

        self.running = false;
        log.info("Stopped plugin host for {s}", .{self.plugin_id});
    }

    /// Send message to plugin
    pub fn send(self: *PluginHost, message_type: MessageType, payload: []const u8) !void {
        if (!self.running or self.channel == null) {
            return error.NotRunning;
        }

        try self.channel.?.send(message_type, payload);
    }

    /// Receive message from plugin
    pub fn receive(self: *PluginHost, buffer: []u8) !Message {
        if (!self.running or self.channel == null) {
            return error.NotRunning;
        }

        return try self.channel.?.receive(buffer);
    }

    /// Deinitialize the plugin host
    pub fn deinit(self: *PluginHost) void {
        self.stop();
    }
};

/// Create a pair of connected channels (for testing)
pub fn createConnectedChannels(allocator: Allocator) ![2]Channel {
    _ = allocator;
    // TODO: Implement for testing
    return error.NotImplemented;
}

test "MessageHeader size" {
    // Header should be exactly 12 bytes
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(MessageHeader));
}

test "MessageType enum values" {
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(MessageType.init));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(MessageType.shutdown));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(MessageType.api_call));
}
