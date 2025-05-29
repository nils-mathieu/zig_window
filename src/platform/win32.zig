//! The implementation of the `zig_window` library for the win32 API.
//!
//! This module is not expected to be used directly, but it is still documented for users needing
//! to interact with internals.

const zw = @import("zig_window");
const std = @import("std");

const impl = @This();

/// The consistent interface for the win32 API implementation.
///
/// The documentation for the functions in this module can be accessed by reading the public
/// interface of the `zig_window` library.
pub const interface = struct {
    pub const EventLoop = impl.EventLoop;

    pub fn run(config: zw.RunConfig) zw.Error!void {
        //
        // Initialize the event loop.
        //
        var zw_el = try config.allocator.create(zw.EventLoop);
        defer config.allocator.destroy(zw_el);
        const el = &zw_el.platform_specific;
        try impl.EventLoop.initAt(config, el);
        defer el.deinit();

        //
        // Start the message loop.
        //

    }

    pub const event_loop = struct {
        pub inline fn allocator(self: *impl.EventLoop) std.mem.Allocator {
            return self.allocator;
        }
    };
};

/// The implementation of an `EventLoop` on the Windows platform.
pub const EventLoop = struct {
    /// The allocator that was used when calling the `run` function originally.
    allocator: std.mem.Allocator,

    /// The user application handler function that will be called when new events
    /// are received.
    user_app: zw.UserApp,

    /// Initializes an instance of `EventLoop` at the provided location.
    ///
    /// **Note:** the provided `EventLoop` pointer must point inside of a `zw.EventLoop` such that
    /// it is possible to find the original allocated pointer through `@fieldParentPtr`.
    pub fn initAt(config: zw.RunConfig, self: *EventLoop) zw.Error!void {
        self.* = EventLoop{
            .allocator = config.allocator,
            .user_app = config.user_app,
        };
    }

    /// Releases the resources associated with the event loop.
    ///
    /// **Note:** this function does *not* free the pointer.
    pub fn deinit(self: *EventLoop) void {
        _ = self;
    }

    /// Returns a pointer to the platform agnostic `zw.EventLoop` in which this
    /// `EventLoop` object lives.
    pub inline fn toPlatformAgnostic(self: *EventLoop) *zw.EventLoop {
        return @fieldParentPtr("platform_specific", self);
    }

    /// Sends an event to the user-defined event handler.
    pub inline fn sendEvent(self: *EventLoop, event: zw.Event) void {
        self.user_app.sendEvent(self.toPlatformAgnostic(), event);
    }
};
