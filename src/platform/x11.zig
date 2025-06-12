//! The implementation of `zig_window` for the X11 server.

const zm = @import("zig_window");
const std = @import("std");
const log = @import("../utility.zig").log;

const c = @cImport({
    @cInclude("X11/Xlib.h");
});

const impl = @This();

/// The stable interface for the X11 implementation.
pub const interface = struct {
    pub const Window = impl.Window;
    pub const EventLoop = impl.EventLoop;

    pub fn run(config: zm.RunConfig) zm.Error!void {
        const prevHandler = c.XSetErrorHandler(errorHandler);
        defer _ = c.XSetErrorHandler(prevHandler);

        var el_zw: zm.EventLoop = undefined;
        const el = &el_zw.platform_specific;
        try el.initInPlace(config);
        defer el.deinit();

        el.sendEvent(.started);
        defer el.sendEvent(.stopped);

        while (!el.exiting) {
            // NOTE: `XNextEvent` doesn't seem to have any meaningful return value.
            var event: c.XEvent = undefined;
            _ = c.XNextEvent(el.display, &event);

            switch (event.type) {
                c.ClientMessage => {
                    if (event.xclient.message_type == el.wm_protocols) {
                        if (event.xclient.data.l[0] == el.wm_delete_window) {
                            const w = el.x11WindowToWindow(event.xclient.window);
                            el.sendEvent(.{ .close_requested = .{ .window = w.toParent() } });
                        }
                    }
                },
                else => {},
            }
        }
    }

    pub const event_loop = struct {
        pub inline fn allocator(self: *zm.EventLoop) std.mem.Allocator {
            return self.platform_specific.allocator;
        }

        pub inline fn exit(self: *zm.EventLoop) void {
            self.platform_specific.exiting = true;
        }
    };

    pub const window = struct {
        pub fn create(el: *zm.EventLoop, config: zm.Window.Config) zm.Error!*zm.Window {
            const gpa = el.platform_specific.allocator;
            const result = try gpa.create(zm.Window);
            errdefer gpa.destroy(result);
            try result.platform_specific.initInPlace(&el.platform_specific, config);
            return result;
        }

        pub fn destroy(self: *zm.Window) void {
            const gpa = self.platform_specific.event_loop.allocator;
            self.platform_specific.deinit();
            gpa.destroy(self);
        }
    };
};

/// Contains the last `XErrorEvent` received by the error handler.
var last_error_event: c.XErrorEvent = undefined;

/// This function will be called when an error occurs in the X11 library.
fn errorHandler(display: ?*c.Display, err_arg: [*c]c.XErrorEvent) callconv(.c) c_int {
    _ = display;
    last_error_event = @as(*c.XErrorEvent, @ptrCast(err_arg)).*;
    log.debug("x11: received error event {}", .{last_error_event.error_code});
    return 0;
}

/// Handles an error that has been propagated through the X11 error handler.
fn handleLastError(name: []const u8) zm.Error {
    @branchHint(.cold);
    log.err("`{s}` failed: {}", .{ name, last_error_event.error_code });
    if (last_error_event.error_code == c.BadAlloc) {
        return error.OutOfMemory;
    } else {
        return error.PlatformError;
    }
}

/// The X11 event loop implementation.
pub const EventLoop = struct {
    /// The display connection object.
    display: *c.Display,

    /// The allocator responsible for handling the memory needed by the event loop.
    allocator: std.mem.Allocator,
    /// The user-defined app responsible for handling events.
    user_app: zm.UserApp,

    /// The `__ZIG_WINDOW` atom.
    zig_window_atom: c.Atom,
    /// The `WM_PROTOCOLS` atom.
    wm_protocols: c.Atom,
    /// The `WM_DELETE_WINDOW` atom.
    wm_delete_window: c.Atom,

    /// Whether the event loop has been requested to exit.
    exiting: bool = false,

    /// The list of windows managed by the event loop.
    windows: std.ArrayListUnmanaged(*Window) = .empty,

    /// Initializes the event loop in-place at the provided address.
    pub fn initInPlace(self: *EventLoop, config: zm.RunConfig) zm.Error!void {
        const display = try openDisplay();
        errdefer closeDisplay(display);

        const zig_window_atom, const wm_protocols, const wm_delete_window =
            try internAtoms(display, 3, .{ "__ZIG_WINDOW", "WM_PROTOCOLS", "WM_DELETE_WINDOW" }, false);

        self.* = EventLoop{
            .display = display,
            .allocator = config.allocator,
            .user_app = config.user_app,
            .zig_window_atom = zig_window_atom,
            .wm_protocols = wm_protocols,
            .wm_delete_window = wm_delete_window,
        };
    }

    /// Deinitializes the event loop.
    pub fn deinit(self: *EventLoop) void {
        closeDisplay(self.display);
        self.windows.deinit(self.allocator);
    }

    /// Converts this `EventLoop` pointer to its parent `zm.EventLoop` object.
    pub inline fn toParent(self: *EventLoop) *zm.EventLoop {
        return @fieldParentPtr("platform_specific", self);
    }

    /// Sends an event to the user-defined app.
    pub inline fn sendEvent(self: *EventLoop, event: zm.Event) void {
        self.user_app.sendEvent(self.toParent(), event);
    }

    /// Gets the `*Window` pointer from an X11 window ID.
    ///
    /// # Valid Usage
    ///
    /// The caller must ensure that the provided window ID is valid for this event loop.
    pub inline fn x11WindowToWindow(self: *EventLoop, w: c.Window) *Window {
        for (self.windows.items) |win| {
            if (win.window == w) return win;
        }
        unreachable;
    }
};

/// The X11 window implementation.
pub const Window = struct {
    /// The created X11 window.
    window: c.Window,

    /// A pointer to the event loop responsible for managing this window.
    event_loop: *EventLoop,

    /// Initializes a new window at the provided memory location, using the provided configuration.
    pub fn initInPlace(self: *Window, el: *EventLoop, config: zm.Window.Config) zm.Error!void {
        var x: c_int = 0;
        var y: c_int = 0;
        if (config.position) |pos| {
            x = std.math.lossyCast(c_int, pos.x);
            y = std.math.lossyCast(c_int, pos.y);
        }

        var width: c_uint = 1280;
        var height: c_uint = 720;
        if (config.surface_size) |size| {
            width = std.math.lossyCast(c_uint, size.width);
            height = std.math.lossyCast(c_uint, size.height);
        }

        const window = c.XCreateWindow(
            el.display,
            c.XDefaultRootWindow(el.display),
            x,
            y,
            width,
            height,
            0,
            c.CopyFromParent,
            c.InputOutput,
            null,
            0,
            null,
        );
        if (window == 0) return handleLastError("XCreateWindow");
        errdefer destroyWindow(el.display, window);

        // Configure the created window.

        if (c.XSelectInput(el.display, window, c.ClientMessage) == 0) {
            return handleLastError("XSelectInput");
        }

        if (c.XMapWindow(el.display, window) == 0) {
            return handleLastError("XMapWindow");
        }

        const protocols = [_]c.Atom{
            el.wm_delete_window,
        };

        if (c.XSetWMProtocols(el.display, window, @constCast(&protocols), protocols.len) == 0) {
            return handleLastError("XSetWMProtocols");
        }

        try el.windows.append(el.allocator, self);

        self.* = Window{
            .window = window,
            .event_loop = el,
        };
    }

    /// De-initializes the window.
    pub fn deinit(self: *Window) void {
        const index = std.mem.indexOfScalar(*Window, self.event_loop.windows.items, self).?;
        _ = self.event_loop.windows.swapRemove(index);

        destroyWindow(self.event_loop.display, self.window);
    }

    /// Converts the provided `*Window` pointer to its platform-agnostic parent
    /// structure.
    pub inline fn toParent(self: *Window) *zm.Window {
        return @fieldParentPtr("platform_specific", self);
    }
};

/// Invokes the `XOpenDisplay` function.
fn openDisplay() zm.Error!*c.Display {
    const ret = c.XOpenDisplay(null);
    if (ret == null) return handleLastError("XOpenDisplay");
    return ret.?;
}

/// Invokes the `XCloseDisplay` function.
fn closeDisplay(display: *c.Display) void {
    // This function always returns zero even in case of error. We can still check for errors by
    // clearing the last error code and checking it again.

    if (std.debug.runtime_safety) {
        last_error_event.error_code = 0;
    }

    _ = c.XCloseDisplay(display);

    if (std.debug.runtime_safety and last_error_event.error_code != 0) {
        @branchHint(.cold);
        log.warn("`XCloseDisplay` failed: {}", .{last_error_event.error_code});
    }
}

/// Destroys the provided window.
fn destroyWindow(display: *c.Display, window: c.Window) void {
    const ret = c.XDestroyWindow(display, window);
    if (std.debug.runtime_safety and ret == 0) {
        @branchHint(.cold);
        log.warn("`XDestroyWindow` failed: {}", .{last_error_event.error_code});
    }
}

/// Creatse new atoms.
fn internAtoms(display: *c.Display, comptime count: usize, names: [count][*:0]const u8, only_if_exists: bool) zm.Error![count]c.Atom {
    var result: [count]c.Atom = undefined;

    const ret = c.XInternAtoms(display, @constCast(@ptrCast(&names)), @intCast(count), @intFromBool(only_if_exists), &result);

    if (ret == 0) {
        return handleLastError("XInternAtoms");
    }

    return result;
}
