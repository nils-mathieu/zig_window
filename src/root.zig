//! `zig_window` is a Windowing library for the Zig programming language.
//!
//! It aims to provide a consistent API for as many backends as possible.
//!
//! # First Steps
//!
//! The first thing to do in order to run application with the `zig_window` library is
//! to call the `run` function.
//!
//! This function is responsible for firing up an event loop to which all events directed
//! to all windows will be received.
//!
//! # Platform-specific behaviors
//!
//! Because `zig_window` attempts to abstract a lot of windowing implementations all at the same
//! time, while still being able to use as much of the underlying platform's functionality, there's
//! bound to be some inconsistencies.
//!
//! Those inconsistencies are as documented as possible. See the documentation for individual
//! functions when in doupt.
//!
//! # Thread Safety
//!
//! Most of the functions in this library are *not* thread-safe. They expect to be used from
//! the main thread.
//!
//! When in a multi-threaded environment, the `EventLoop.wakeUp()` function may be used to force the
//! main thread to wake up. The user can use external synchronization to enqueue arbitrary routines
//! onto that thread using that mechanism.

const std = @import("std");

pub const platform = @import("platform.zig");

/// An error that might occur when using the `zig_window` library.
pub const Error = error{
    /// The system ran out of memory and cannot carry the requested operation
    /// to completion because of it.
    OutOfMemory,

    /// The underlying operating system or window manager returned an error that could not
    /// be recovered from.
    PlatformError,
};

/// Contains the state of a user-defined application, associated with a function to call when a
/// new event is sent to the event loop.
pub const UserApp = struct {
    /// A pointer to the custom data provided by the user.
    ///
    /// This will be passed to the first parameter of the `on_event` function.
    self: *anyopaque,

    /// A function pointer to the function that will be called when a new event must be handled
    /// by the application,
    on_event: *const fn (self: *anyopaque, event_loop: *EventLoop, event: Event) void,

    /// Initializes a new `UserApp` object from the provided pointer and function.
    ///
    /// # Examples
    ///
    /// ```zig
    /// const App = struct {};
    ///
    /// fn onEvent(self: *App, event_loop: *EventLoop, event: Event) void {
    ///     // ...
    /// }
    ///
    /// var app_state: App = .{};
    ///
    /// const user_app: UserApp = .init(App, &app_state, onEvent);
    /// ```
    ///
    /// # Returns
    ///
    /// This function returns a `UserApp` object with the provided pointer a function.
    pub fn init(
        comptime T: type,
        self: *T,
        comptime on_event_fn: fn (self: *T, event_loop: *EventLoop, event: Event) void,
    ) UserApp {
        // Create an "adaptor" function that simply converts the `*anyopaque` argument to the user's
        // requested pointer type.
        const Fns = struct {
            pub fn onEvent(user_data: *anyopaque, event_loop: *EventLoop, event: Event) void {
                on_event_fn(@ptrCast(@alignCast(user_data)), event_loop, event);
            }
        };

        return UserApp{
            .self = self,
            .on_event = Fns.onEvent,
        };
    }

    /// Invokes the user-defined event handler function with the provided parameters.
    pub inline fn sendEvent(self: UserApp, event_loop: *EventLoop, event: Event) void {
        (self.on_event)(self.self, event_loop, event);
    }
};

/// The configuration passed to the `run` function.
pub const RunConfig = struct {
    /// The allocator that will be used by the `zig_window` platform implementation when it needs
    /// to allocate more memory.
    ///
    /// This allocator should be general purpose and support free operations (the standard
    /// library's `GeneralPurposeAllocator` or anything equivalent would works perfectly).
    ///
    /// # Remarks
    ///
    /// This allocator can be accessed again once the event loop has started by calling
    /// `EventLoop.allocator()` for easy access.
    allocator: std.mem.Allocator,

    /// Contains the state of the user-defined application responsible for handling the events
    /// sent to the application's event loop.
    user_app: UserApp,
};

/// Runs the application to completion.
///
/// # Examples
///
/// Run a simple application:
///
/// ```zig
/// const zw = @import("zig_window");
/// const std = @import("std");
///
/// const App = struct {};
///
/// fn onEvent(app: *App, event_loop: *zw.EventLoop, event: zw.Event) void {
///     // ...
/// }
///
/// pub fn main() zw.Error!void {
///     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
///     defer _ = gpa.deinit();
///
///     var app = App{};
///
///     try zw.run(.{
///         .allocator = gpa.allocator(),
///         .user_app = .init(App, &app, onEvent),
///     });
/// }
/// ```
///
/// # Valid Usage
///
/// - This function **must** be called from the main thread.
///
/// - It **must** not be called re-entrantly (from within the event loop itself).
///
/// # Platform-specifics
///
/// On most platforms, this function will block the current thread until the application's event
/// loop has completed its execution (usually because of call to `EventLoop.exit()`).
///
/// Notable exceptions:
///
/// * **iOS** - The function never returns. Even in case of error, once the event loop has started,
///   there is no way to return control to the caller.
///
/// * **web** - The function returns instantly and the event loop runs in the background.
pub fn run(config: RunConfig) Error!void {
    return platform.interface.run(config);
}

/// An event that can be sent to the user application.
pub const Event = union(enum) {
    /// This is always the first event to fire.
    ///
    /// It indicates to an application that the event loop has successfully started and that it can
    /// start creating windows.
    ///
    /// This is good place to initialize your application.
    started,
    /// This is always the last event to fire.
    ///
    /// This is good place to deallocate your application's state. Note that by the time this
    /// event completes, all windows created by your application must have been closed.
    stopped,
    /// Indicates that the event loop is about to wait for more events to become available.
    ///
    /// Just after this event is fired, the thread enters a sleeping state and will only wake up if:
    ///
    /// 1. A spurious wake up occurs, which means that nothing actually happened. In that case, this
    ///    event will fire again without anything having changed.
    ///
    /// 2. A new event has been received, in which case the event will be handled and the
    ///    `.about_to_wait` event will be invoked again.
    ///
    /// 3. Another thread has called the `EventLoop.wakeUp()` function.
    ///
    /// 4. The `timeout` parameter associated with this event has been written to. See the
    ///    documentation for `timeout` for more information.
    about_to_wait: struct {
        /// A timeout, measured in nanoseconds, indicating how much time the thread is allowed to
        /// sleep for before waking up again automatically even if no events have been received
        /// by that time.
        ///
        /// If an event is received before the timeout expires, the thread will wake up and handle
        /// the event normally.
        ///
        /// If no event is received, the thread will only wake up *after* the timeout duration
        /// has ellapsed (or if a spurious wake up occured, but they are unlikely).
        ///
        /// # Remarks
        ///
        /// If the thread wakes up for *any* reason, this timeout will be reset and must be written
        /// to again.
        ///
        /// In other words, every time `about_to_wait` is called, one must write the timeout
        /// value again.
        timeout_ns: u64,
    },
};

/// Contains the global state of the event loop while it is executing.
///
/// A pointer to an `EventLoop` is made available to the user defined `onEvent` function and
/// can be used to interact with the application on a global level (as opposed to an individual
/// window's level).
pub const EventLoop = struct {
    /// The platform-specific object backing this `EventLoop`.
    ///
    /// You can access this field if you need to access any of the underlying object's state,
    /// but make sure to gate this access behind the appropriate compile-time checks.
    platform_specific: platform.interface.EventLoop,

    /// Returns the `std.mem.Allocator` that was originally used to start the event loop
    /// (through the `run()` function).
    ///
    /// Whatever you pass in `RunConfig.allocator` is returned from this function.
    ///
    /// # Thread Safety
    ///
    /// This function is thread safe. You can call it from any thread without fear.
    pub inline fn allocate(self: *EventLoop) std.mem.Allocator {
        return platform.interface.event_loop.allocator(self);
    }
};
