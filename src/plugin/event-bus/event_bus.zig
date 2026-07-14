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

//! Event Bus module for the Lightpanda Plugin System.
//!
//! The Event Bus provides a publish-subscribe mechanism for communication between
//! the Core and plugins. Plugins never communicate directly - all messages flow
//! through the Event Bus, ensuring loose coupling and proper isolation.
//!
//! Features:
//! - Synchronous and asynchronous event dispatching
//! - Event priorities
//! - Type-safe event payloads
//! - Subscription filtering

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.event_bus);

/// Maximum number of subscribers per event type
pub const max_subscribers_per_event = 256;

/// Event priority levels
pub const Priority = enum(u8) {
    highest = 0,
    high = 50,
    normal = 100,
    low = 150,
    lowest = 200,
};

/// Event delivery mode
pub const DeliveryMode = enum {
    /// Event is delivered immediately on the caller's thread
    synchronous,
    /// Event is queued for later delivery
    asynchronous,
};

/// Unique identifier for subscriptions
pub const SubscriptionId = u64;

/// Base event structure
pub const Event = struct {
    /// Event name/type
    name: []const u8,
    /// Timestamp when the event was created
    timestamp: u64,
    /// Priority of this event instance
    priority: Priority = .normal,
    /// Whether this event can be cancelled by handlers
    cancellable: bool = false,
    /// Whether the event has been cancelled
    cancelled: bool = false,
    /// Opaque payload data
    payload: ?*anyopaque = null,
    /// Payload size
    payload_size: usize = 0,

    /// Cancel this event (if cancellable)
    pub fn cancel(self: *Event) void {
        if (self.cancellable) {
            self.cancelled = true;
        }
    }
};

/// Event handler function signature
pub const EventHandler = *const fn (*Event) callconv(.C) void;

/// Subscriber entry
const Subscriber = struct {
    id: SubscriptionId,
    handler: EventHandler,
    priority: Priority,
    context: ?*anyopaque,
};

/// Event type registration
const EventType = struct {
    name: []const u8,
    subscribers: std.ArrayList(Subscriber),
    async_queue: std.ArrayList(Event),
};

/// Event Bus configuration
pub const Config = struct {
    /// Maximum number of event types
    max_event_types: usize = 64,
    /// Default queue size for async events
    async_queue_size: usize = 1024,
    /// Whether to enable debug logging
    debug_logging: bool = false,
};

/// Main Event Bus structure
pub const EventBus = struct {
    allocator: Allocator,
    config: Config,
    event_types: std.StringHashMap(EventType),
    subscription_counter: u64,
    async_mutex: std.Thread.Mutex,
    async_cond: std.Thread.Condition,
    running: bool,
    async_thread: ?std.Thread,

    /// Initialize the Event Bus
    pub fn init(allocator: Allocator, config: Config) !EventBus {
        return .{
            .allocator = allocator,
            .config = config,
            .event_types = std.StringHashMap(EventType).init(allocator),
            .subscription_counter = 0,
            .async_mutex = .{},
            .async_cond = .{},
            .running = true,
            .async_thread = null,
        };
    }

    /// Deinitialize the Event Bus
    pub fn deinit(self: *EventBus) void {
        self.running = false;
        self.async_cond.signal();

        if (self.async_thread) |thread| {
            thread.join();
        }

        // Clean up all event types
        var it = self.event_types.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.subscribers.deinit();
            entry.value_ptr.async_queue.deinit();
        }
        self.event_types.deinit();
    }

    /// Start the async event processing thread
    pub fn start(self: *EventBus) !void {
        self.async_thread = try std.Thread.spawn(.{}, asyncEventProcessor, .{self});
    }

    /// Stop the async event processing thread
    pub fn stop(self: *EventBus) void {
        self.running = false;
        self.async_cond.signal();
    }

    /// Register a new event type
    pub fn registerEventType(self: *EventBus, name: []const u8) !void {
        if (self.event_types.count() >= self.config.max_event_types) {
            log.err("Maximum event types reached", .{});
            return error.EventTypesExhausted;
        }

        const entry = try self.event_types.getOrPut(name);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .name = name,
                .subscribers = std.ArrayList(Subscriber).init(self.allocator),
                .async_queue = std.ArrayList(Event).init(self.allocator),
            };
            log.debug("Registered event type: {s}", .{name});
        }
    }

    /// Subscribe to an event
    pub fn subscribe(
        self: *EventBus,
        event_name: []const u8,
        handler: EventHandler,
        priority: Priority,
        context: ?*anyopaque,
    ) !SubscriptionId {
        const entry = self.event_types.get(event_name) orelse {
            // Auto-register event type
            try self.registerEventType(event_name);
            self.event_types.get(event_name).?
        };

        self.subscription_counter += 1;
        const sub_id = self.subscription_counter;

        try entry.subscribers.append(.{
            .id = sub_id,
            .handler = handler,
            .priority = priority,
            .context = context,
        });

        // Sort subscribers by priority
        sortSubscribers(entry.subscribers.items);

        log.debug("Subscription {d} registered for event {s}", .{ sub_id, event_name });
        return sub_id;
    }

    /// Unsubscribe from an event
    pub fn unsubscribe(self: *EventBus, event_name: []const u8, subscription_id: SubscriptionId) bool {
        const entry = self.event_types.get(event_name) orelse return false;

        for (entry.subscribers.items, 0..) |sub, i| {
            if (sub.id == subscription_id) {
                _ = entry.subscribers.orderedRemove(i);
                log.debug("Subscription {d} removed from event {s}", .{ subscription_id, event_name });
                return true;
            }
        }
        return false;
    }

    /// Publish an event synchronously
    pub fn publishSync(self: *EventBus, event: *Event) void {
        const entry = self.event_types.get(event.name) orelse return;

        // Deliver to subscribers in priority order
        for (entry.subscribers.items) |sub| {
            if (event.cancelled) break;
            sub.handler(event);
        }

        log.debug("Sync event {s} delivered to {d} subscribers", .{ event.name, entry.subscribers.items.len });
    }

    /// Publish an event asynchronously
    pub fn publishAsync(self: *EventBus, event: Event) !void {
        const entry = self.event_types.get(event.name) orelse return;

        self.async_mutex.lock();
        defer self.async_mutex.unlock();

        try entry.async_queue.append(event);
        self.async_cond.signal();

        log.debug("Async event {s} queued", .{event.name});
    }

    /// Broadcast an event to all event types
    pub fn broadcast(self: *EventBus, event: *Event) void {
        var it = self.event_types.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.subscribers.items) |sub| {
                if (event.cancelled) break;
                sub.handler(event);
            }
        }
    }

    /// Get the number of subscribers for an event
    pub fn getSubscriberCount(self: *EventBus, event_name: []const u8) usize {
        const entry = self.event_types.get(event_name) orelse return 0;
        return entry.subscribers.items.len;
    }

    /// Internal async event processor thread
    fn asyncEventProcessor(self: *EventBus) void {
        while (self.running) {
            self.async_mutex.lock();

            // Wait for events or shutdown signal
            while (self.running and self.allQueuesEmpty()) {
                self.async_cond.wait(&self.async_mutex);
            }

            if (!self.running) {
                self.async_mutex.unlock();
                break;
            }

            // Process one event from each queue
            var it = self.event_types.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.async_queue.items.len > 0) {
                    const event = entry.value_ptr.async_queue.orderedRemove(0);
                    self.async_mutex.unlock();

                    // Deliver the event
                    for (entry.value_ptr.subscribers.items) |sub| {
                        if (event.cancelled) break;
                        sub.handler(@constCast(&event));
                    }

                    self.async_mutex.lock();
                }
            }

            self.async_mutex.unlock();
        }
    }

    /// Check if all async queues are empty
    fn allQueuesEmpty(self: *EventBus) bool {
        var it = self.event_types.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.async_queue.items.len > 0) {
                return false;
            }
        }
        return true;
    }
};

/// Sort subscribers by priority (lower value = higher priority)
fn sortSubscribers(subscribers: []Subscriber) void {
    std.mem.sort(Subscriber, subscribers, {}, struct {
        fn lessThan(_: void, a: Subscriber, b: Subscriber) bool {
            return @intFromEnum(a.priority) < @intFromEnum(b.priority);
        }
    }.lessThan);
}

test "EventBus basic operations" {
    const allocator = std.testing.allocator;
    var bus = try EventBus.init(allocator, .{});
    defer bus.deinit();

    // Register event type
    try bus.registerEventType("test.event");

    // Subscribe
    var call_count: usize = 0;
    const handler: EventHandler = struct {
        fn handle(e: *Event) void {
            _ = e;
        }
    }.handle;

    const sub_id = try bus.subscribe("test.event", handler, .normal, null);
    try std.testing.expectEqual(@as(SubscriptionId, 1), sub_id);

    // Publish
    var event = Event{
        .name = "test.event",
        .timestamp = 0,
    };
    bus.publishSync(&event);

    // Unsubscribe
    try std.testing.expect(bus.unsubscribe("test.event", sub_id));
    try std.testing.expect(!bus.unsubscribe("test.event", sub_id)); // Already removed
}
