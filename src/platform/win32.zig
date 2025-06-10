//! The implementation of the `zig_window` library for the win32 API.
//!
//! This module is not expected to be used directly, but it is still documented for users needing
//! to interact with internals.

const zw = @import("zig_window");
const std = @import("std");
const win32 = @import("win32");
const log = @import("../utility.zig").log;
const builtin = @import("builtin");

const impl = @This();

// =================================================================================================
// INTERFACE
// =================================================================================================

/// The consistent interface for the win32 API implementation.
///
/// The documentation for the functions in this module can be accessed by reading the public
/// interface of the `zig_window` library.
pub const interface = struct {
    pub const EventLoop = impl.EventLoop;
    pub const Window = impl.Window;

    pub fn run(config: zw.RunConfig) zw.Error!void {
        //
        // Initialize the event loop.
        //
        var zw_el = try config.allocator.create(zw.EventLoop);
        defer config.allocator.destroy(zw_el);
        const el = &zw_el.platform_specific;
        try impl.EventLoop.initAt(config, el);
        defer el.deinit();

        // Send the initial start event and enqueue the stopped event.
        el.sendEvent(.started);
        defer el.sendEvent(.stopped);

        //
        // Start the message loop.
        //
        while (!el.exiting) {
            el.runEventLoopIteration();
        }
    }

    pub const event_loop = struct {
        pub inline fn allocator(self: *zw.EventLoop) std.mem.Allocator {
            return self.platform_specific.allocator;
        }

        pub inline fn exit(self: *zw.EventLoop) void {
            self.platform_specific.exiting = true;
        }

        pub inline fn wakeUp(self: *zw.EventLoop) void {
            setEvent(self.platform_specific.wake_up_event);
        }
    };

    pub const window = struct {
        pub fn create(el: *zw.EventLoop, config: zw.Window.Config) zw.Error!*zw.Window {
            const ret = try el.platform_specific.allocator.create(zw.Window);
            try impl.Window.initAt(&ret.platform_specific, &el.platform_specific, config);
            return ret;
        }

        pub fn destroy(self: *zw.Window) void {
            const gpa = self.platform_specific.event_loop.allocator;
            self.platform_specific.deinit();
            gpa.destroy(self);
        }

        pub inline fn surfaceRect(self: *zw.Window) zw.Rect {
            return self.platform_specific.getClientRect();
        }

        pub inline fn surfaceSize(self: *zw.Window) zw.Size {
            return self.platform_specific.getClientRect().size();
        }

        pub inline fn surfacePosition(self: *zw.Window) zw.Position {
            return self.platform_specific.getClientRect().position();
        }

        pub inline fn outerRect(self: *zw.Window) zw.Rect {
            return self.platform_specific.getWindowRect();
        }

        pub inline fn outerSize(self: *zw.Window) zw.Size {
            return self.platform_specific.getWindowRect().size();
        }

        pub inline fn outerPosition(self: *zw.Window) zw.Position {
            return self.platform_specific.getWindowRect().position();
        }

        pub inline fn requestSurfaceSize(self: *zw.Window, size: zw.Size) void {
            self.platform_specific.setClientSize(size);
        }

        pub fn setMinSurfaceSize(self: *zw.Window, size: zw.Size) void {
            self.platform_specific.min_surface_size = size;
            const current_size = self.platform_specific.getClientRect().size();
            self.platform_specific.setClientSize(current_size);
        }

        pub fn setMaxSurfaceSize(self: *zw.Window, size: zw.Size) void {
            self.platform_specific.max_surface_size = size;
            const current_size = self.platform_specific.getClientRect().size();
            self.platform_specific.setClientSize(current_size);
        }

        pub inline fn presentNotify(self: *zw.Window) void {
            _ = self;
        }

        pub inline fn requestRedraw(self: *zw.Window) void {
            self.platform_specific.redrawWindow();
        }

        pub inline fn isVisible(self: *zw.Window) bool {
            const IsWindowVisible = win32.ui.windows_and_messaging.IsWindowVisible;
            return IsWindowVisible(self.platform_specific.hwnd) != 0;
        }

        pub fn show(self: *zw.Window, take_focus: bool) void {
            const ShowWindow = win32.ui.windows_and_messaging.ShowWindow;
            const cmd = if (take_focus)
                win32.ui.windows_and_messaging.SW_SHOW
            else
                win32.ui.windows_and_messaging.SW_SHOWNOACTIVATE;
            _ = ShowWindow(self.platform_specific.hwnd, cmd);
        }

        pub inline fn hide(self: *zw.Window) void {
            const ShowWindow = win32.ui.windows_and_messaging.ShowWindow;
            _ = ShowWindow(self.platform_specific.hwnd, win32.ui.windows_and_messaging.SW_HIDE);
        }
    };
};

// =================================================================================================
// SUPPORT TYPES
// =================================================================================================

/// A type with custom formating that writes a Windows error.
pub const FormatError = struct {
    /// The error code to format.
    err: win32.foundation.WIN32_ERROR,

    pub fn format(
        self: FormatError,
        comptime fmt: []const u8,
        opts: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = opts;

        // TODO: Write the error message and stuff.
        if (std.enums.tagName(win32.foundation.WIN32_ERROR, self.err)) |name| {
            try writer.print("{s} (error code {})", .{ name, @intFromEnum(self.err) });
        } else {
            try writer.print("error code {}", .{@intFromEnum(self.err)});
        }
    }
};

/// Creates a new `FormatError` from the provided Windows error.
pub fn fmtError(err: win32.foundation.WIN32_ERROR) FormatError {
    return FormatError{ .err = err };
}

/// Returns a type which, when formatted, writes the a message containing the current thread's
/// last error code.
pub fn fmtLastError() FormatError {
    return fmtError(win32.foundation.GetLastError());
}

/// Combines both a `WINDOW_EX_STYLE` and a `WINDOW_STYLE`.
pub const WindowStyles = struct {
    ex_style: win32.ui.windows_and_messaging.WINDOW_EX_STYLE = .{},
    style: win32.ui.windows_and_messaging.WINDOW_STYLE = .{},
};

extern fn RtlGetVersion(info: *win32.system.system_information.OSVERSIONINFOW) win32.foundation.NTSTATUS;

/// Represents a version of windows.
pub const OsVersion = struct {
    major: usize,
    minor: usize,
    build: usize,

    /// Creates a new `OsVersion` with the provided numbers.
    pub fn new(major: usize, minor: usize, build: usize) OsVersion {
        return OsVersion{
            .major = major,
            .minor = minor,
            .build = build,
        };
    }

    /// Gets the current OS version.
    pub fn get() OsVersion {
        const OSVERSIONINFOW = win32.system.system_information.OSVERSIONINFOW;

        var inner: OSVERSIONINFOW = undefined;
        inner.dwOSVersionInfoSize = @sizeOf(OSVERSIONINFOW);

        const ret = RtlGetVersion(&inner);

        // `RtlGetVersion` should always return success.
        std.debug.assert(ret == win32.foundation.STATUS_SUCCESS);

        return OsVersion{
            .major = inner.dwMajorVersion,
            .minor = inner.dwMinorVersion,
            .build = inner.dwBuildNumber,
        };
    }

    /// Returns whether `self` is at least `other`.
    pub fn isAtLeast(self: OsVersion, other: OsVersion) bool {
        if (self.major > other.major) return true;
        if (self.major < other.major) return false;
        if (self.minor > other.minor) return true;
        if (self.minor < other.minor) return false;
        return self.build >= other.build;
    }

    pub fn format(self: OsVersion, comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opts;

        return writer.print(
            "{}.{}.{}",
            .{
                self.major,
                self.minor,
                self.build,
            },
        );
    }
};

/// How aware the current process is aware of DPI changes.
pub const DpiAwareness = enum {
    // https://learn.microsoft.com/en-us/windows/win32/hidpi/dpi-awareness-context

    unaware,
    per_monitor_v2,
    per_monitor,
};

// =================================================================================================
// EVENT LOOP
// =================================================================================================

/// The implementation of an `EventLoop` on the Windows platform.
pub const EventLoop = struct {
    /// The allocator that was used when calling the `run` function originally.
    allocator: std.mem.Allocator,
    /// The user application handler function that will be called when new events
    /// are received.
    user_app: zw.UserApp,

    /// The current version of Windows we are running on.
    windows_version: OsVersion,
    /// The current DPI awareness state of the process.
    dpi_awareness: DpiAwareness,

    /// The handle to a high-resolution waitable timer.
    ///
    /// This handle may be null if:
    ///
    /// 1. High-resolution timers are not supported on the current operation system (which happens
    ///    if we are running on older version of Windows).
    ///
    /// 2. An error occurred while creating the timer.
    high_rez_timer: ?win32.foundation.HANDLE,
    /// An event that will be signaled when the event loop needs to wake up.
    wake_up_event: win32.foundation.HANDLE,

    /// The module handle of the current process.
    hinstance: win32.foundation.HINSTANCE,

    /// The list of windows that are managed by this event loop.
    windows: std.ArrayListUnmanaged(*Window) = .empty,
    /// Whether the event loop has been requested to exit.
    exiting: bool = false,

    /// Initializes an instance of `EventLoop` at the provided location.
    ///
    /// **Note:** the provided `EventLoop` pointer must point inside of a `zw.EventLoop` such that
    /// it is possible to find the original allocated pointer through `@fieldParentPtr`.
    pub fn initAt(config: zw.RunConfig, self: *EventLoop) zw.Error!void {
        // Get the current process's module handle.
        const hinstance = try getCurrentModuleHandle();

        // Query the current windows version. This is used to determine what features we can and
        // cannot use.
        const windows_version = OsVersion.get();
        log.debug("detected Windows version: {}", .{windows_version});

        const dpi_awareness = becomeDpiAware();

        // Register the window class that will be used by all windows created on this
        // event loop.
        try registerClass(Window.class_name, hinstance, &wndProc);
        errdefer unregisterClass(Window.class_name, hinstance);

        // Create a high-resolution timer which will be used when handling time-outs (when waiting
        // for messages).
        //
        // This operation is actually allowed to fail because we have a fallback mechanism in case
        // we can't use a high-resolution timer. The issue is that that fallback mechanism is
        // ~10000 less precise because it has only millisecond granularity.
        //
        // See more in `waitForMoreMessages`.
        const high_rez_timer = createWaitableTimer() catch null;
        errdefer if (high_rez_timer) |h| closeHandle(h);

        // Create the wake-up event which will be used to wake up the message loop thread from
        // anywhere in the process.
        const wake_up_event = try createEvent();
        errdefer closeHandle(wake_up_event);

        // Register the application's raw input devices.
        setupRawInput();

        self.* = EventLoop{
            .allocator = config.allocator,
            .user_app = config.user_app,
            .windows_version = windows_version,
            .dpi_awareness = dpi_awareness,
            .high_rez_timer = high_rez_timer,
            .wake_up_event = wake_up_event,
            .hinstance = hinstance,
        };
    }

    /// Releases the resources associated with the event loop.
    ///
    /// **Note:** this function does *not* free the pointer.
    pub fn deinit(self: *EventLoop) void {
        if (std.debug.runtime_safety and self.windows.items.len > 0) {
            const err =
                \\
                \\Exiting the event loop while there still are live windows.
                \\
                \\You must `.destroy()` all windows before the event loop
                \\exits (the `.stopped` event is a good place to do it).
                \\
            ;

            std.debug.panic(err, .{});
        }
        self.windows.deinit(self.allocator);

        unregisterClass(Window.class_name, self.hinstance);
        if (self.high_rez_timer) |h| closeHandle(h);
        closeHandle(self.wake_up_event);
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

    /// Blocks the calling thread until more events are available on the thread's message
    /// queue.
    ///
    /// This function takes care of calling the user's `.about_to_wait` event to determine
    /// the timeout amount.
    ///
    /// This function wraps a call to `MsgWaitForMultipleObjectsEx`.
    pub fn waitForMoreMessages(self: *EventLoop) void {
        const MsgWaitForMultipleObjectsEx = win32.ui.windows_and_messaging.MsgWaitForMultipleObjectsEx;
        const QS_ALLINPUT = win32.ui.windows_and_messaging.QS_ALLINPUT;
        const MWMO_INPUTAVAILABLE = win32.ui.windows_and_messaging.MWMO_INPUTAVAILABLE;
        const WAIT_FAILED = win32.foundation.WAIT_FAILED;
        const HANDLE = win32.foundation.HANDLE;

        const infinite_timeout = std.math.maxInt(u64);

        var objects_to_wait_on = std.BoundedArray(HANDLE, 2){};
        objects_to_wait_on.appendAssumeCapacity(self.wake_up_event);

        // Invoke the `.about_to_wait` event and ask the user to provide the timeout that should
        // be used for this wait. Once the event has returned, we can use the new `timeout_ns`
        // value.
        var timeout_ns: u64 = infinite_timeout;
        self.sendEvent(.{ .about_to_wait = .{ .timeout_ns = &timeout_ns } });

        // The `.about_to_wait` event might have requested the event loop to exit.
        if (self.exiting) return;

        // NOTE:
        //  There's two ways for this function to wait for the requested time-out.
        //
        //  1. We can use the regular `timeout` parameter of `MsgWaitForMultipleObjectsEx`
        //     function. The issue with that method is that the granularity is only a millisecond.
        //
        //  2. When the `high_rez_timer` handle is non-null, we can use the timer. That method
        //     has a 100 nanosecond granularity, which is way better.
        //
        //  In consequence, if the high resolution timer is present, and that the operation that
        //  sets it up here do not fail, then we use it. Otherwise, we fall back to using the
        //  timeout parameter.
        var use_timeout_parameter = true;
        var timeout_parameter_value: u32 = std.math.maxInt(u32);

        if (timeout_ns != infinite_timeout) {
            if (self.high_rez_timer) |high_rez_timer| {
                const duration_100ns = timeout_ns / 100;
                const set_timer_value =
                    if (duration_100ns >= -std.math.minInt(i64))
                        std.math.minInt(i64)
                    else
                        -@as(i64, @intCast(duration_100ns));

                if (setWaitableTimer(high_rez_timer, set_timer_value)) {
                    use_timeout_parameter = false;
                    objects_to_wait_on.appendAssumeCapacity(high_rez_timer);
                } else |_| {}
            }

            if (use_timeout_parameter) {
                // We were not able to set up the high resolution timer. We need to use the
                // fallback method of using the timeout parameter.
                timeout_parameter_value = std.math.lossyCast(u32, timeout_ns / std.time.ns_per_ms);
            }
        }

        // NOTE:
        //  `QS_ALLINPUT` and `MWMO_INPUTAVAILABLE` ensure that the function will wake up the
        //  thread when new messages are available in the message queue. Those messages will
        //  not be removed from the queue and we still need to invoke `PeekMessageW` a bunch of
        //  times to handle the events.
        const ret = MsgWaitForMultipleObjectsEx(
            @intCast(objects_to_wait_on.slice().len),
            objects_to_wait_on.slice().ptr,
            timeout_parameter_value,
            QS_ALLINPUT,
            MWMO_INPUTAVAILABLE,
        );

        // There isn't a lot of reasons for this function to fail. If it does, then
        // we can just treat this as a spurious wake up.
        if (ret == @intFromEnum(WAIT_FAILED)) {
            log.warn("`MsgWaitForMultipleObjectsEx` failed: {}", .{fmtLastError()});
        }
    }

    /// Dispatches all pending messages until none are left in the message queue for this
    /// thread.
    ///
    /// This function dispatches messages to the user's event handling function.
    ///
    /// # Remarks
    ///
    /// If the event loop is exiting, remaining events will be ignored and the function will
    /// return immediately.
    pub fn dispatchPendingMessages(self: *EventLoop) void {
        const PeekMessage = win32.ui.windows_and_messaging.PeekMessageW;
        const DispatchMessage = win32.ui.windows_and_messaging.DispatchMessageW;
        const TranslateMessage = win32.ui.windows_and_messaging.TranslateMessage;
        const MSG = win32.ui.windows_and_messaging.MSG;
        const PM_REMOVE = win32.ui.windows_and_messaging.PM_REMOVE;

        // This is the regular translate-dispatch message loop. During this loop, the window
        // procedure registered for our window will be invoked multiple times with a bunch of
        // events.
        //
        // Note that this is not one-to-one. Sometimes zero events will be emitted, sometimes
        // multiple events will be emitted.

        var msg: MSG = undefined;
        while (PeekMessage(&msg, null, 0, 0, PM_REMOVE) != 0 and !self.exiting) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessage(&msg);
        }
    }

    /// Runs a complete event loop iteration to completion.
    ///
    /// This includes:
    ///
    /// 1. Waiting until more events are available. This causes the `.about_to_wait` event
    ///    to be invoked.
    ///
    /// 2. Poll all events available in the message queue.
    ///
    /// 3. Clean up the state for the iteration.
    pub fn runEventLoopIteration(self: *EventLoop) void {
        self.waitForMoreMessages();
        self.dispatchPendingMessages();
    }
};

/// Contains data that will be made available in the window procedure during window initialization.
const InitData = struct {
    /// A pointer to the event loop on which the window is running.
    event_loop: *EventLoop,

    /// The initial configuration of the window.
    config: *const zw.Window.Config,

    /// The not-yet-initialized window pointer to store in the userdata field of the created
    /// window.
    ///
    /// # Remarks
    ///
    /// By the time `CreateWindowExW` returns, the `Window` object must be fully populated.
    window: *Window,
};

/// The implementation of a `Window` on the Windows platform.
pub const Window = struct {
    /// A reference to the event loop that this window is managed by.
    event_loop: *EventLoop,

    /// The minimum size that the window is allowed to take.
    min_surface_size: zw.Size,
    /// The maximum size that the window is allowed to take.
    max_surface_size: zw.Size,

    /// The raw window handle of the window.
    ///
    /// **Note:** You can access the HINSTANCE handle associated with this window by calling
    /// `getHinstance()`.
    hwnd: win32.foundation.HWND,

    /// The handle of the last device event received.
    ///
    /// This is populated when a raw input event is received.
    last_device_id: ?win32.foundation.HANDLE = null,
    /// The last keyboard event received on the message loop.
    ///
    /// This is populated whenever a `WM_KEYDOWN`, `WM_KEYUP`, or similar event is received, and
    /// cleared when:
    ///
    /// 1. Another event replaces it.
    /// 2. The end of the current message-loop iteration is reached.
    last_keyboard_event: ?KeyboardEvent = null,

    /// The UTF-16 characters that the user is currently typing.
    ///
    /// This array is flushed when:
    ///
    /// 1. The end of the current message-loop iteration has been reached.
    /// 2. A new keyboard event has been received.
    /// 3. The dead-char state associated with this array changes
    ///    (see `are_typed_utf16_chars_dead`).
    typed_utf16_chars: std.ArrayListUnmanaged(u16) = .empty,
    /// Whether the current key combination is part of a dead-char sequence.
    ///
    /// Is is set when a `WM_DEADCHAR` or `WM_SYSDEADCHAR` event is received, and cleared
    /// when a `WM_CHAR` or `WM_SYSCHAR` is received.
    in_dead_char_sequence: bool = false,

    /// A temporary buffer that will be used when converting UTF-16 data to UTF-8.
    utf8_buf: std.ArrayListUnmanaged(u8) = .empty,

    /// The last reported mouse position over the window.
    current_mouse_position: zw.Position = .invalid,
    /// Whether the mouse is currently in the window.
    is_mouse_hover: bool = false,

    /// Whether the window was requested to redraw itself manually by the user.
    ///
    /// This is done to prevent confirming window invalidations during the `WM_PAINT` event
    /// when a new event has been requested.
    manual_redraw_requested: bool = false,

    /// The buffer that is used to allocate the memory necessary to store instances
    /// of `RAWINPUT`.
    rawinput_buffer: []align(@alignOf(win32.ui.input.RAWINPUT)) u8 = &.{},

    /// The name of the window class used when creating windows.
    pub const class_name = std.unicode.utf8ToUtf16LeStringLiteral("zig_window_class_name");

    /// Initializes a new window at the provided position.
    ///
    /// **Note:** this function expects the provided window to exist as the field of a
    /// platform agnostic `zw.Window`.
    pub fn initAt(self: *Window, el: *EventLoop, config: zw.Window.Config) zw.Error!void {
        const gpa = el.allocator;

        //
        // Convert the user's title from UTF-8 to UTF-16.
        //

        const title_utf16 = std.unicode.utf8ToUtf16LeAllocZ(gpa, config.title) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => unreachable,
        };
        defer gpa.free(title_utf16);

        //
        // Initialize the window styles from the configuration.
        //

        var styles = WindowStyles{};

        styles.ex_style.ACCEPTFILES = 1;
        styles.ex_style.APPWINDOW = 1;

        if (config.decorations) {
            styles.ex_style.WINDOWEDGE = 1;
            styles.style.SYSMENU = 1;
            styles.style.BORDER = 1;
            styles.style.DLGFRAME = 1;
            styles.style.GROUP = 1; // MINIMIZEBOX
            styles.style.TABSTOP = @intFromBool(config.resizable); // MAXIMIZEBOX
        }

        styles.style.THICKFRAME = @intFromBool(config.resizable); // SIZEBOX
        styles.ex_style.TOPMOST = @intFromBool(config.level == .always_on_top);

        // Some styles must be set once the window is done being created.

        // if (config.minimized) {
        //     styles.style.MINIMIZE = 1;
        // }
        // if (config.maximized) {
        //     styles.style.MAXIMIZE = 1;
        // }
        // if (config.visible) {
        //     styles.style.VISIBLE = 1;
        // }

        // NOTE:
        //  A pointer to this value will be made available in the window procedure which will be
        //  called during the `CreateWindowExW` call bellow. It will be used to finish initializing
        //  the window.
        var init_data = InitData{
            .event_loop = el,
            .config = &config,
            .window = self,
        };

        const hwnd = try createWindow(
            title_utf16,
            class_name,
            styles,
            el.hinstance,
            &init_data,
        );
        errdefer destroyWindow(hwnd);
        std.debug.assert(hwnd == self.hwnd);

        // Re-apply window styles because some of theme are overwritten for some reasons. This
        // should not produce any flickering because the window is not yet visible.
        setWindowLong(hwnd, win32.ui.windows_and_messaging.GWL_STYLE, @bitCast(styles.style));
        setWindowLong(hwnd, win32.ui.windows_and_messaging.GWL_EXSTYLE, @bitCast(styles.ex_style));

        if (config.visible) {
            var show_command: win32.ui.windows_and_messaging.SHOW_WINDOW_CMD = .{};
            show_command.SHOWNORMAL = @intFromBool(!config.minimized);
            show_command.SHOWMINIMIZED = @intFromBool(config.maximized or config.minimized);
            show_command.SHOWNOACTIVATE = @intFromBool(!config.auto_focus);
            self.showWindow(show_command);
        }

        try self.event_loop.windows.append(self.event_loop.allocator, self);
    }

    /// Releases the resources associated with the window.
    ///
    /// **Note:** this function does not destroys the memory.
    pub fn deinit(self: *Window) void {
        const gpa = self.event_loop.allocator;

        gpa.free(self.rawinput_buffer);
        self.typed_utf16_chars.deinit(gpa);
        self.utf8_buf.deinit(gpa);

        const idx = std.mem.indexOfScalar(*Window, self.event_loop.windows.items, self).?;
        _ = self.event_loop.windows.swapRemove(idx);

        destroyWindow(self.hwnd);
    }

    /// Returns a pointer to the platform agnostic `zw.Window` in which this
    /// `Window` object lives.
    pub inline fn toPlatformAgnostic(self: *Window) *zw.Window {
        return @fieldParentPtr("platform_specific", self);
    }

    /// Returns the HINSTANCE handle of the module that owns the window.
    pub fn getHinstance(self: *Window) win32.foundation.HINSTANCE {
        const GWLP_HINSTANCE = win32.ui.windows_and_messaging.GWLP_HINSTANCE;
        return @ptrFromInt(getWindowLongPtr(self.hwnd, GWLP_HINSTANCE));
    }

    /// Returns the window styles of the window.
    pub fn getWindowStyles(self: *Window) WindowStyles {
        const GWL_STYLE = win32.ui.windows_and_messaging.GWL_STYLE;
        const GWL_EXSTYLE = win32.ui.windows_and_messaging.GWL_EXSTYLE;

        return WindowStyles{
            .style = @bitCast(getWindowLong(self.hwnd, GWL_STYLE)),
            .ex_style = @bitCast(getWindowLong(self.hwnd, GWL_EXSTYLE)),
        };
    }

    /// Adjusts the provided client rect to the "outer" rectangle that the window will have.
    pub fn clientToWindowRect(self: *Window, rect: *win32.foundation.RECT) error{PlatformError}!void {
        const GetMenu = win32.ui.windows_and_messaging.GetMenu;

        // TODO(nils):
        //  Use GetDpiForWindow and AdjustWindowRectExForDpi once we support DPI awareness and
        //  those functions are available.

        const styles = self.getWindowStyles();
        const has_menu = GetMenu(self.hwnd) != null;
        try adjustWindowRectEx(rect, has_menu, styles);
    }

    /// Adjusts the provided client size to the "outer" size that the window will have.
    pub fn clientToWindowSize(self: *Window, size: zw.Size) error{PlatformError}!zw.Size {
        var rect: win32.foundation.RECT = .{
            .left = 0,
            .top = 0,
            .bottom = std.math.lossyCast(i32, size.height),
            .right = std.math.lossyCast(i32, size.width),
        };

        try self.clientToWindowRect(&rect);

        return zw.Size{
            .width = @abs(rect.right - rect.left),
            .height = @abs(rect.bottom - rect.top),
        };
    }

    /// Sets the window's size.
    ///
    /// # Remarks
    ///
    /// This function takes the "outer" width and height of the window as opposed to the window's
    /// client size.
    pub fn setWindowSize(self: *Window, new_size: zw.Size) void {
        self.setWindowPos(null, null, new_size, false, null);
    }

    /// Returns the current client rect of the window.
    pub fn getClientRect(self: *Window) zw.Rect {
        const GetClientRect = win32.ui.windows_and_messaging.GetClientRect;
        const RECT = win32.foundation.RECT;

        var rect: RECT = undefined;
        const ret = GetClientRect(self.hwnd, &rect);

        if (std.debug.runtime_safety and ret == 0) {
            std.debug.panic("`GetClientRect` failed: {}", .{fmtLastError()});
        }

        return zw.Rect{
            .x = rect.left,
            .y = rect.top,
            .width = @intCast(rect.right - rect.left),
            .height = @intCast(rect.bottom - rect.top),
        };
    }

    /// Gets the current outer rect of the window.
    pub fn getWindowRect(self: *Window) zw.Rect {
        const GetWindowRect = win32.ui.windows_and_messaging.GetWindowRect;
        const RECT = win32.foundation.RECT;

        var rect: RECT = undefined;
        const ret = GetWindowRect(self.hwnd, &rect);

        if (std.debug.runtime_safety and ret == 0) {
            std.debug.panic("`GetWindowRect` failed: {}", .{fmtLastError()});
        }

        return zw.Rect{
            .x = rect.left,
            .y = rect.top,
            .width = @intCast(rect.right - rect.left),
            .height = @intCast(rect.bottom - rect.top),
        };
    }

    /// Requests the provided client size for the window.
    pub fn setClientSize(self: *Window, size: zw.Size) void {
        const SW_RESTORE = win32.ui.windows_and_messaging.SW_RESTORE;

        const window_size = self.clientToWindowSize(size) catch size;
        self.setWindowSize(window_size);

        const actual_size = self.getClientRect().size();
        if (actual_size.width != size.width or actual_size.height != size.height) {
            // We're likely maximized. Let's unmaximize the window.
            self.showWindow(SW_RESTORE);
        }
    }

    /// Invokes the `ShowWindow` function on the underlying window.
    pub fn showWindow(self: *Window, cmd: win32.ui.windows_and_messaging.SHOW_WINDOW_CMD) void {
        const ShowWindow = win32.ui.windows_and_messaging.ShowWindow;
        _ = ShowWindow(self.hwnd, cmd);
    }

    /// Updates the window's position and other parameters as one action.
    ///
    /// # Parameters
    ///
    /// * `level`: The new level of the window, relative to other windows.
    ///
    /// * `position`: The new position of the window, if any.
    ///
    /// * `size`: The new size of the window, if any.
    ///
    /// * `activate`: Whether to activate the window during the operation.
    ///
    /// * `show`: Whether to show or hide the window.
    ///
    /// # Remarks
    ///
    /// This function will *not* permanently change the window's position relative to other
    /// windows. This will merly reposition the window.
    pub fn setWindowPos(
        self: *Window,
        level: ?zw.Window.Config.Level,
        position: ?zw.Position,
        size: ?zw.Size,
        activate: bool,
        show: ?bool,
    ) void {
        const HWND_TOPMOST = win32.ui.windows_and_messaging.HWND_TOPMOST;
        const HWND_NOTOPMOST = win32.ui.windows_and_messaging.HWND_NOTOPMOST;
        const HWND_BOTTOM = win32.ui.windows_and_messaging.HWND_BOTTOM;
        const HWND = win32.foundation.HWND;
        const InvalidateRgn = win32.graphics.gdi.InvalidateRgn;

        var flags = win32.ui.windows_and_messaging.SET_WINDOW_POS_FLAGS{};
        var insert_after: ?HWND = null;
        var x: i32 = 0;
        var y: i32 = 0;
        var w: i32 = 0;
        var h: i32 = 0;

        if (level) |lvl| {
            insert_after = switch (lvl) {
                .always_on_bottom => HWND_BOTTOM,
                .normal => HWND_NOTOPMOST,
                .always_on_top => HWND_TOPMOST,
            };
        } else {
            flags.NOZORDER = 1;
        }

        flags.ASYNCWINDOWPOS = 1;

        if (position) |pos| {
            x = pos.x;
            y = pos.y;
        } else {
            flags.NOMOVE = 1;
        }

        if (size) |sz| {
            w = @intCast(sz.width);
            h = @intCast(sz.height);
        } else {
            flags.NOSIZE = 1;
        }

        if (!activate) {
            flags.NOACTIVATE = 1;
        }

        if (show) |s| {
            if (s) {
                flags.SHOWWINDOW = 1;
            } else {
                flags.HIDEWINDOW = 1;
            }
        }

        rawSetWindowPos(self.hwnd, insert_after, x, y, w, h, flags);
        _ = InvalidateRgn(self.hwnd, null, 0);
    }

    /// Uses the window's internal UTF-8 buffer to decode the provided UTF-16 string.
    ///
    /// The resulting pointer is valid as long as the internal UTF-8 buffer is not used
    /// again.
    ///
    /// In case of error, the function returns an empty string.
    pub fn decodeUtf16(self: *Window, utf16: []const u16) []u8 {
        self.utf8_buf.clearRetainingCapacity();
        var buf = self.utf8_buf.toManaged(self.event_loop.allocator);
        defer self.utf8_buf = buf.moveToUnmanaged();
        std.unicode.utf16LeToUtf8ArrayList(&buf, utf16) catch {
            log.warn("failed to decode UTF-16 data: {any}", .{utf16});
            buf.clearRetainingCapacity();
        };
        return buf.items;
    }

    /// Reads the provided raw input event and returns a pointer to the raw input data.
    ///
    /// The data is stored in the window's internal temporary buffer and will remain
    /// valid until the next call to `readRawInput`.
    pub fn readRawInput(self: *Window, hrawinput: win32.ui.input.HRAWINPUT) error{ PlatformError, OutOfMemory }!*win32.ui.input.RAWINPUT {
        const GetRawInputData = win32.ui.input.GetRawInputData;

        var event_size: u32 = undefined;

        while (true) {
            event_size = @intCast(self.rawinput_buffer.len);

            // Attempt to store the rawinput structure in the current buffer.
            const ret = GetRawInputData(
                hrawinput,
                .INPUT,
                self.rawinput_buffer.ptr,
                &event_size,
                @sizeOf(win32.ui.input.RAWINPUTHEADER),
            );

            if (ret != std.math.maxInt(u32)) {
                break;
            }

            const code = win32.foundation.GetLastError();
            if (code != .ERROR_INSUFFICIENT_BUFFER) {
                std.log.err("`GetRawInputData` failed: {}", .{fmtError(code)});
                return error.PlatformError;
            }

            // If the buffer is too small, we need to allocate a new one.
            self.rawinput_buffer = try self.event_loop.allocator.realloc(self.rawinput_buffer, event_size);
        }

        return @ptrCast(self.rawinput_buffer.ptr);
    }

    /// Flushes the currently pending keyboard state to the user's event handler.
    ///
    /// If there is no pending keyboard state, this function does nothing.
    ///
    /// The pending keyboard state includes:
    ///
    /// 1. Pending keyboard input (keystrokes).
    /// 2. Text written through the keyboard.
    pub fn flushPendingKeyboardState(self: *Window) void {
        const VIRTUAL_KEY = win32.ui.input.keyboard_and_mouse.VIRTUAL_KEY;

        // Skip all processing when there is nothing to do.
        if (self.typed_utf16_chars.items.len == 0 and self.last_keyboard_event == null) return;

        defer self.last_keyboard_event = null;
        defer self.typed_utf16_chars.clearRetainingCapacity();

        const typed_characters = self.decodeUtf16(self.typed_utf16_chars.items);

        // =========================================================================================
        // Keyboard events
        // =========================================================================================

        if (self.last_keyboard_event) |last_ev| {
            var keyboard_state: [256]KeyState8 = undefined;

            getKeyboardState(&keyboard_state);

            var characters_buf: [16]u8 = undefined;
            var characters: []const u8 = typed_characters;
            if (characters.len == 0) {
                characters = resolveCharacter(
                    last_ev.virtual_key_code,
                    last_ev.scan_code,
                    self.event_loop.windows_version,
                    self.in_dead_char_sequence,
                    &keyboard_state,
                    &characters_buf,
                );
            }

            // Remove modifiers from the keyboard state in order to determine what the keystroke
            // would look like without modifiers.
            keyboard_state[@intFromEnum(VIRTUAL_KEY.SHIFT)].pressed = false;
            keyboard_state[@intFromEnum(VIRTUAL_KEY.LSHIFT)].pressed = false;
            keyboard_state[@intFromEnum(VIRTUAL_KEY.RSHIFT)].pressed = false;
            keyboard_state[@intFromEnum(VIRTUAL_KEY.CONTROL)].pressed = false;
            keyboard_state[@intFromEnum(VIRTUAL_KEY.LCONTROL)].pressed = false;
            keyboard_state[@intFromEnum(VIRTUAL_KEY.RCONTROL)].pressed = false;
            keyboard_state[@intFromEnum(VIRTUAL_KEY.MENU)].pressed = false;
            keyboard_state[@intFromEnum(VIRTUAL_KEY.LMENU)].pressed = false;
            keyboard_state[@intFromEnum(VIRTUAL_KEY.RMENU)].pressed = false;
            keyboard_state[@intFromEnum(VIRTUAL_KEY.CAPITAL)].pressed = false;
            keyboard_state[@intFromEnum(VIRTUAL_KEY.CAPITAL)].toggled = false;
            keyboard_state[@intFromEnum(VIRTUAL_KEY.NUMLOCK)].pressed = false;
            keyboard_state[@intFromEnum(VIRTUAL_KEY.NUMLOCK)].toggled = false;

            var characters_ignoring_modifiers_buf: [16]u8 = undefined;
            const characters_ignoring_modifiers = resolveCharacter(
                last_ev.virtual_key_code,
                last_ev.scan_code,
                self.event_loop.windows_version,
                self.in_dead_char_sequence,
                &keyboard_state,
                &characters_ignoring_modifiers_buf,
            );

            self.event_loop.sendEvent(.{ .keyboard = .{
                .window = self.toPlatformAgnostic(),
                .device = @ptrCast(self.last_device_id),
                .key = scanCodeToKey(last_ev.scan_code),
                .scan_code = last_ev.scan_code,
                .state = last_ev.state,
                .characters = characters,
                .characters_without_modifiers = characters_ignoring_modifiers,
            } });
        }

        // =========================================================================================
        // Text typed events
        // =========================================================================================

        if (typed_characters.len > 0) {
            if (self.in_dead_char_sequence) {
                self.event_loop.sendEvent(.{
                    .text_typed = .{
                        .window = self.toPlatformAgnostic(),
                        .device = @ptrCast(self.last_device_id),
                        .ime = .{ .preedit = .{
                            .text = typed_characters,
                            .cursor_start = 0,
                            .cursor_end = typed_characters.len,
                        } },
                    },
                });
            } else {
                self.event_loop.sendEvent(.{
                    .text_typed = .{
                        .window = self.toPlatformAgnostic(),
                        .device = @ptrCast(self.last_device_id),
                        .ime = .{ .commit = typed_characters },
                    },
                });
            }
        }
    }

    /// Requests a `WM_PAINT` event to be posted on the window's message queue.
    pub fn redrawWindow(self: *Window) void {
        rawRedrawWindow(self.hwnd);
        self.manual_redraw_requested = true;
    }
};

/// Contains information about a keyboard received by a window.
///
/// This contains only the information available in `WM_KEYDOWN` and other similar messages.
pub const KeyboardEvent = struct {
    /// The scan-code associated with the event.
    scan_code: u16,
    /// The state transition of the key.
    state: zw.Event.Keyboard.StateTransition,
    /// The virtual-key code of the key.
    virtual_key_code: win32.ui.input.keyboard_and_mouse.VIRTUAL_KEY,
};

// =================================================================================================
// WNDPROC FUNCTION
// =================================================================================================

fn wndProc(
    hwnd: win32.foundation.HWND,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) callconv(.winapi) win32.foundation.LRESULT {
    const GWLP_USERDATA = win32.ui.windows_and_messaging.GWLP_USERDATA;
    const WM_NCCREATE = win32.ui.windows_and_messaging.WM_NCCREATE;
    const WM_CREATE = win32.ui.windows_and_messaging.WM_CREATE;
    const CREATESTRUCTW = win32.ui.windows_and_messaging.CREATESTRUCTW;
    const DefWindowProcW = win32.ui.windows_and_messaging.DefWindowProcW;

    const userdata = getWindowLongPtr(hwnd, GWLP_USERDATA);

    // NOTE:
    //  We're putting a bunch of `.cold` directives here because window creation should
    //  normally be fairly rare compared to regular events.

    switch (msg) {
        WM_NCCREATE => {
            @branchHint(.cold);

            if (userdata != 0) {
                // The `WM_NCCREATE` event should never be called multiple times.
                log.err("`WM_NCCREATE` called twice", .{});
                return -1;
            }

            const createstruct: *CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const init_data: *InitData = @ptrCast(@alignCast(createstruct.lpCreateParams.?));

            // If we were not able to get the `PER_MONITOR_V2` awareness state, we need to call
            // `EnableNonClientDpiScaling`.
            if (init_data.event_loop.dpi_awareness == .per_monitor) {
                enableNonClientDpiScaling(hwnd);
            }

            init_data.window.* = Window{
                .min_surface_size = init_data.config.min_surface_size,
                .max_surface_size = init_data.config.max_surface_size,
                .event_loop = init_data.event_loop,
                .hwnd = hwnd,
            };

            setWindowLongPtr(
                hwnd,
                GWLP_USERDATA,
                @intFromPtr(init_data.window),
            );

            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_CREATE => {
            @branchHint(.cold);

            if (userdata == 0) {
                // The `WM_CREATE` event should never be called *after* the `WM_NCCREATE`
                // event. If that happens, we just fail as a sanity check.
                log.err("`WM_CREATE` called before `WM_NCCREATE` during initialization sequence", .{});
                return -1;
            }

            const createstruct: *CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const init_data: *InitData = @ptrCast(@alignCast(createstruct.lpCreateParams.?));

            const window: *Window = @ptrFromInt(userdata);

            // All post-creation initialization should go here, except window visibility
            // modifications through `ShowWindow`.

            var requested_window_size: ?zw.Size = null;
            if (init_data.config.surface_size) |sz| {
                requested_window_size = window.clientToWindowSize(sz) catch sz;
                requested_window_size = requested_window_size.?.clamp(window.min_surface_size, window.max_surface_size);
            }
            window.setWindowPos(
                init_data.config.level,
                init_data.config.position,
                requested_window_size,
                init_data.config.auto_focus,
                null,
            );

            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => {
            if (userdata == 0) {
                @branchHint(.unlikely);

                // The window is not yet initialized, and the event is not part of the ones we know
                // of to initialize the window. Just call the default window procedure.
                return DefWindowProcW(hwnd, msg, wparam, lparam);
            } else {
                const window: *Window = @ptrFromInt(userdata);

                std.debug.assert(window.hwnd == hwnd);

                // The window is initialized. We're receiving regular events for the window.
                return handleMessage(window, msg, wparam, lparam);
            }
        },
    }
}

/// Handles a regular message for the provided window.
///
/// This function expects to be called outside of the initialization sequence.
fn handleMessage(
    window: *Window,
    msg: u32,
    wparam: win32.foundation.WPARAM,
    lparam: win32.foundation.LPARAM,
) win32.foundation.LRESULT {
    const DefWindowProcW = win32.ui.windows_and_messaging.DefWindowProcW;
    const WM_CLOSE = win32.ui.windows_and_messaging.WM_CLOSE;
    const WM_SIZE = win32.ui.windows_and_messaging.WM_SIZE;
    const WM_GETMINMAXINFO = win32.ui.windows_and_messaging.WM_GETMINMAXINFO;
    const WM_KEYDOWN = win32.ui.windows_and_messaging.WM_KEYDOWN;
    const WM_KEYUP = win32.ui.windows_and_messaging.WM_KEYUP;
    const WM_SYSKEYDOWN = win32.ui.windows_and_messaging.WM_SYSKEYDOWN;
    const WM_SYSKEYUP = win32.ui.windows_and_messaging.WM_SYSKEYUP;
    const WM_CHAR = win32.ui.windows_and_messaging.WM_CHAR;
    const WM_DEADCHAR = win32.ui.windows_and_messaging.WM_DEADCHAR;
    const WM_SYSCHAR = win32.ui.windows_and_messaging.WM_SYSCHAR;
    const WM_SYSDEADCHAR = win32.ui.windows_and_messaging.WM_SYSDEADCHAR;
    const WM_MOUSEMOVE = win32.ui.windows_and_messaging.WM_MOUSEMOVE;
    const WM_MOUSELEAVE = 0x02A3;
    const WM_SETFOCUS = win32.ui.windows_and_messaging.WM_SETFOCUS;
    const WM_KILLFOCUS = win32.ui.windows_and_messaging.WM_KILLFOCUS;
    const WM_DPICHANGED = win32.ui.windows_and_messaging.WM_DPICHANGED;
    const WM_PAINT = win32.ui.windows_and_messaging.WM_PAINT;
    const WM_INPUT = win32.ui.windows_and_messaging.WM_INPUT;
    const WM_LBUTTONDOWN = win32.ui.windows_and_messaging.WM_LBUTTONDOWN;
    const WM_LBUTTONUP = win32.ui.windows_and_messaging.WM_LBUTTONUP;
    const WM_RBUTTONDOWN = win32.ui.windows_and_messaging.WM_RBUTTONDOWN;
    const WM_RBUTTONUP = win32.ui.windows_and_messaging.WM_RBUTTONUP;
    const WM_MBUTTONDOWN = win32.ui.windows_and_messaging.WM_MBUTTONDOWN;
    const WM_MBUTTONUP = win32.ui.windows_and_messaging.WM_MBUTTONUP;
    const WM_XBUTTONDOWN = win32.ui.windows_and_messaging.WM_XBUTTONDOWN;
    const WM_XBUTTONUP = win32.ui.windows_and_messaging.WM_XBUTTONUP;

    switch (msg) {

        // https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-close
        WM_CLOSE => {
            window.event_loop.sendEvent(.{ .close_requested = .{ .window = window.toPlatformAgnostic() } });
            return 0;
        },

        // https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-size
        WM_SIZE => {
            const width: u16 = @truncate(@as(usize, @bitCast(lparam)));
            const height: u16 = @truncate(@as(usize, @bitCast(lparam)) >> 16);

            // Update whether the window is currently maximized or not.
            window.event_loop.sendEvent(.{ .surface_resized = .{
                .window = window.toPlatformAgnostic(),
                .width = width,
                .height = height,
            } });
            return 0;
        },

        // https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-getminmaxinfo
        WM_GETMINMAXINFO => {
            const MINMAXINFO = win32.ui.windows_and_messaging.MINMAXINFO;

            const min_max_info: *MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));

            const window_min = window.clientToWindowSize(window.min_surface_size) catch window.min_surface_size;
            const window_max = window.clientToWindowSize(window.max_surface_size) catch window.max_surface_size;

            min_max_info.ptMinTrackSize = .{
                .x = @intCast(window_min.width),
                .y = @intCast(window_min.height),
            };
            min_max_info.ptMaxTrackSize = .{
                .x = @intCast(window_max.width),
                .y = @intCast(window_max.height),
            };

            return 0;
        },

        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-char
        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-deadchar
        // https://learn.microsoft.com/en-us/windows/win32/menurc/wm-syschar
        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-sysdeadchar
        WM_CHAR, WM_DEADCHAR, WM_SYSCHAR, WM_SYSDEADCHAR => {
            const is_dead = msg == WM_DEADCHAR or msg == WM_SYSDEADCHAR;

            if (window.typed_utf16_chars.items.len > 0 and window.in_dead_char_sequence != is_dead)
                window.flushPendingKeyboardState();
            window.in_dead_char_sequence = is_dead;
            window.typed_utf16_chars.append(window.event_loop.allocator, @truncate(wparam)) catch {
                log.warn("ran out of memory while appending written UTF-16 data to buffer", .{});
            };

            // Check whether the queue contains other keyboard events. If it doesn't, then flush
            // the keyboard state now.
            if (!hasKeyboardEvents(window.hwnd))
                window.flushPendingKeyboardState();

            return 0;
        },

        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-keydown
        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-keyup
        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-syskeydown
        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-syskeyup
        WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP => {
            const VIRTUAL_KEY = win32.ui.input.keyboard_and_mouse.VIRTUAL_KEY;
            const MapVirtualKeyExW = win32.ui.input.keyboard_and_mouse.MapVirtualKeyExW;
            const MAPVK_VK_TO_VSC_EX = win32.ui.windows_and_messaging.MAPVK_VK_TO_VSC_EX;

            const KeystrokeMessageFlags = packed struct(u32) {
                /// The number of times the event should be executed. This happens when the message queue
                /// lags behind the event handler.
                repeat_count: u16,
                /// The scan code.
                scan_code: u8,
                /// Whether the key is an extended key.
                extended: bool,

                _reserved: u4,

                /// The context code associated with the key.
                context_code: u1,

                /// Whether the key was previously down.
                was_down: bool,
                /// The transition state. This determines whether the key is currently up.
                is_up: bool,
            };

            const keystroke_flags: KeystrokeMessageFlags = @bitCast(@as(u32, @truncate(@as(usize, @bitCast(lparam)))));
            const virtual_key_code: VIRTUAL_KEY = @enumFromInt(@as(u16, @truncate(wparam)));

            var scan_code: u16 = keystroke_flags.scan_code;

            // Sometimes, the scan-code is not received. But it's possible to retrieve it anyway
            // using the `MapVirtualKeyExW` function.
            if (scan_code == 0) {
                scan_code = @intCast(MapVirtualKeyExW(@intFromEnum(virtual_key_code), MAPVK_VK_TO_VSC_EX, null));
            } else {
                // Append the extended bit to the scan-code. This is the format used by the rest
                // of the Windows API.
                if (keystroke_flags.extended) {
                    scan_code |= 0xE000;
                }
            }

            const state =
                if (keystroke_flags.is_up)
                    zw.Event.Keyboard.StateTransition.released
                else if (keystroke_flags.was_down)
                    zw.Event.Keyboard.StateTransition.repeated
                else
                    zw.Event.Keyboard.StateTransition.pressed;

            window.flushPendingKeyboardState();
            window.last_keyboard_event = KeyboardEvent{
                .scan_code = scan_code,
                .state = state,
                .virtual_key_code = virtual_key_code,
            };

            // Check whether the queue contains other keyboard events. If it doesn't, then flush
            // the keyboard state now.
            if (!hasKeyboardEvents(window.hwnd))
                window.flushPendingKeyboardState();

            return 0;
        },

        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mousemove
        WM_MOUSEMOVE => {
            const TME_LEAVE = win32.ui.input.keyboard_and_mouse.TME_LEAVE;

            const x = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam))))));
            const y = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16))));

            window.current_mouse_position = .{ .x = x, .y = y };

            if (!window.is_mouse_hover) {
                window.is_mouse_hover = true;

                window.event_loop.sendEvent(.{ .pointer_entered = .{
                    .window = window.toPlatformAgnostic(),
                    .device = null,
                    .x = @floatFromInt(x),
                    .y = @floatFromInt(y),
                    .finger_id = 0,
                } });

                trackMouseEvent(window.hwnd, TME_LEAVE);
            }

            window.event_loop.sendEvent(.{ .pointer_moved = .{
                .window = window.toPlatformAgnostic(),
                .device = null,
                .x = @floatFromInt(x),
                .y = @floatFromInt(y),
                .finger_id = 0,
                .force = 1.0,
            } });

            return 0;
        },

        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mouseleave
        WM_MOUSELEAVE => {
            window.is_mouse_hover = false;

            window.event_loop.sendEvent(.{ .pointer_left = .{
                .window = window.toPlatformAgnostic(),
                .device = null,
                .x = @floatFromInt(window.current_mouse_position.x),
                .y = @floatFromInt(window.current_mouse_position.y),
                .finger_id = 0,
            } });

            return 0;
        },

        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-killfocus
        WM_KILLFOCUS => {
            window.event_loop.sendEvent(.{ .focus_changed = .{
                .window = window.toPlatformAgnostic(),
                .focused = false,
            } });

            return 0;
        },

        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-setfocus
        WM_SETFOCUS => {
            window.event_loop.sendEvent(.{ .focus_changed = .{
                .window = window.toPlatformAgnostic(),
                .focused = true,
            } });

            return 0;
        },

        // https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged
        WM_DPICHANGED => {
            // The Windows API provide the horizontal AND vertical values for the DPI scaling
            // in the high and low words of `wparam`.
            // However, the documentation for `WM_DPICHANGED` indicates that they are always the
            // same.
            const dpi_x = @as(u16, @truncate(wparam));
            const dpi_y = @as(u16, @truncate(wparam >> 16));
            if (std.debug.runtime_safety and dpi_x != dpi_y) {
                std.debug.panic("different X and Y DPI values: {}, {}", .{ dpi_x, dpi_y });
            }

            const base_dpi = 96.0;

            window.event_loop.sendEvent(.{ .scale_factor_changed = .{
                .window = window.toPlatformAgnostic(),
                .scale_factor = @as(f64, @floatFromInt(dpi_x)) / base_dpi,
            } });

            return 0;
        },

        // https://learn.microsoft.com/en-us/windows/win32/gdi/wm-paint
        WM_PAINT => {
            window.event_loop.sendEvent(.{ .redraw_requested = window.toPlatformAgnostic() });

            _ = DefWindowProcW(window.hwnd, msg, wparam, lparam);

            // It's possible for the user to request a redraw manually during the
            // `WM_PAINT` event. In this case, calling `RedrawWindow` will do nothing.
            // We need to call the function again *after* the event has been confirmed by
            // calling `DefWindowProcW`.
            if (window.manual_redraw_requested) {
                rawRedrawWindow(window.hwnd);
                window.manual_redraw_requested = false;
            }

            return 0;
        },

        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-input
        WM_INPUT => {
            const HRAWINPUT = win32.ui.input.HRAWINPUT;
            const RIM_TYPEMOUSE = @intFromEnum(win32.ui.input.RIM_TYPEMOUSE);
            const RIM_TYPEKEYBOARD = @intFromEnum(win32.ui.input.RIM_TYPEKEYBOARD);
            const RIM_TYPEHID = @intFromEnum(win32.ui.input.RIM_TYPEHID);
            const MOUSE_MOVE_ABSOLUTE = win32.devices.human_interface_device.MOUSE_MOVE_ABSOLUTE;

            const hrawinput: HRAWINPUT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const rawinput = window.readRawInput(hrawinput) catch return 0;

            window.last_device_id = rawinput.header.hDevice;

            switch (rawinput.header.dwType) {
                RIM_TYPEMOUSE => {
                    const mouse = rawinput.data.mouse;

                    if (mouse.usFlags & MOUSE_MOVE_ABSOLUTE == 0) {
                        window.event_loop.sendEvent(.{
                            .mouse_moved = .{
                                .device = @ptrCast(rawinput.header.hDevice),
                                .delta_x = @floatFromInt(mouse.lLastX),
                                .delta_y = @floatFromInt(mouse.lLastY),
                            },
                        });
                    }
                },
                RIM_TYPEKEYBOARD => {},
                RIM_TYPEHID => {},
                else => {},
            }

            return 0;
        },

        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-lbuttondown
        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-lbuttonup
        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-rbuttondown
        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-rbuttonup
        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mbuttondown
        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mbuttonup
        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-xbuttondown
        // https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-xbuttonup
        WM_LBUTTONDOWN,
        WM_LBUTTONUP,
        WM_RBUTTONDOWN,
        WM_RBUTTONUP,
        WM_MBUTTONDOWN,
        WM_MBUTTONUP,
        WM_XBUTTONDOWN,
        WM_XBUTTONUP,
        => {
            const x = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam))))));
            const y = @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lparam)) >> 16))));

            var button: zw.Event.PointerButton = undefined;
            switch (msg) {
                WM_LBUTTONDOWN, WM_LBUTTONUP => button = .primary,
                WM_RBUTTONDOWN, WM_RBUTTONUP => button = .secondary,
                WM_MBUTTONDOWN, WM_MBUTTONUP => button = .middle,
                WM_XBUTTONDOWN, WM_XBUTTONUP => {
                    switch (@as(u16, @truncate(wparam >> 16))) {
                        0x0000 => button = .other(0),
                        0x0001 => button = .back,
                        0x0002 => button = .forward,
                        else => |btn| {
                            if (btn - 2 <= 250) {
                                button = .other(@intCast(btn - 2));
                            } else {
                                return 0;
                            }
                        },
                    }
                },
                else => unreachable,
            }

            const pressed = switch (msg) {
                WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN, WM_XBUTTONDOWN => true,
                WM_LBUTTONUP, WM_RBUTTONUP, WM_MBUTTONUP, WM_XBUTTONUP => false,
                else => unreachable,
            };

            window.event_loop.sendEvent(.{ .pointer_button = .{
                .window = window.toPlatformAgnostic(),
                .device = @ptrCast(window.last_device_id),
                .button = button,
                .finger_id = 0,
                .pressed = pressed,
                .force = 1.0,
                .x = @floatFromInt(x),
                .y = @floatFromInt(y),
            } });

            return 0;
        },

        else => return DefWindowProcW(window.hwnd, msg, wparam, lparam),
    }
}

/// Converts the provided scan-code to a `zw.Key`.
fn scanCodeToKey(scan_code: u16) zw.Key {
    // Chromimum conversion table:
    // https://source.chromium.org/chromium/chromium/src/+/main:ui/events/keycodes/dom/dom_code_data.inc

    return switch (scan_code) {
        0xe05f => zw.Key.sleep,
        0xe063 => zw.Key.wake_up,
        0x001e => zw.Key.key_a,
        0x0030 => zw.Key.key_b,
        0x002e => zw.Key.key_c,
        0x0020 => zw.Key.key_d,
        0x0012 => zw.Key.key_e,
        0x0021 => zw.Key.key_f,
        0x0022 => zw.Key.key_g,
        0x0023 => zw.Key.key_h,
        0x0017 => zw.Key.key_i,
        0x0024 => zw.Key.key_j,
        0x0025 => zw.Key.key_k,
        0x0026 => zw.Key.key_l,
        0x0032 => zw.Key.key_m,
        0x0031 => zw.Key.key_n,
        0x0018 => zw.Key.key_o,
        0x0019 => zw.Key.key_p,
        0x0010 => zw.Key.key_q,
        0x0013 => zw.Key.key_r,
        0x001f => zw.Key.key_s,
        0x0014 => zw.Key.key_t,
        0x0016 => zw.Key.key_u,
        0x002f => zw.Key.key_v,
        0x0011 => zw.Key.key_w,
        0x002d => zw.Key.key_x,
        0x0015 => zw.Key.key_y,
        0x002c => zw.Key.key_z,
        0x0002 => zw.Key.digit1,
        0x0003 => zw.Key.digit2,
        0x0004 => zw.Key.digit3,
        0x0005 => zw.Key.digit4,
        0x0006 => zw.Key.digit5,
        0x0007 => zw.Key.digit6,
        0x0008 => zw.Key.digit7,
        0x0009 => zw.Key.digit8,
        0x000a => zw.Key.digit9,
        0x000b => zw.Key.digit0,
        0x001c => zw.Key.enter,
        0x0001 => zw.Key.escape,
        0x000e => zw.Key.backspace,
        0x000f => zw.Key.tab,
        0x0039 => zw.Key.space,
        0x000c => zw.Key.minus,
        0x000d => zw.Key.equal,
        0x001a => zw.Key.bracket_left,
        0x001b => zw.Key.bracket_right,
        0x002b => zw.Key.backslash,
        0x0027 => zw.Key.semicolon,
        0x0028 => zw.Key.quote,
        0x0029 => zw.Key.backquote,
        0x0033 => zw.Key.comma,
        0x0034 => zw.Key.period,
        0x0035 => zw.Key.slash,
        0x003a => zw.Key.caps_lock,
        0x003b => zw.Key.f1,
        0x003c => zw.Key.f2,
        0x003d => zw.Key.f3,
        0x003e => zw.Key.f4,
        0x003f => zw.Key.f5,
        0x0040 => zw.Key.f6,
        0x0041 => zw.Key.f7,
        0x0042 => zw.Key.f8,
        0x0043 => zw.Key.f9,
        0x0044 => zw.Key.f10,
        0x0057 => zw.Key.f11,
        0x0058 => zw.Key.f12,
        0xe037 => zw.Key.print_screen,
        0x0046 => zw.Key.scroll_lock,
        0x0045 => zw.Key.pause,
        0xe052 => zw.Key.insert,
        0xe047 => zw.Key.home,
        0xe049 => zw.Key.page_up,
        0xe053 => zw.Key.delete,
        0xe04f => zw.Key.end,
        0xe051 => zw.Key.page_down,
        0xe04d => zw.Key.arrow_right,
        0xe04b => zw.Key.arrow_left,
        0xe050 => zw.Key.arrow_down,
        0xe048 => zw.Key.arrow_up,
        0xe045 => zw.Key.num_lock,
        0xe035 => zw.Key.numpad_divide,
        0x0037 => zw.Key.numpad_multiply,
        0x004a => zw.Key.numpad_subtract,
        0x004e => zw.Key.numpad_add,
        0xe01c => zw.Key.numpad_enter,
        0x004f => zw.Key.numpad1,
        0x0050 => zw.Key.numpad2,
        0x0051 => zw.Key.numpad3,
        0x004b => zw.Key.numpad4,
        0x004c => zw.Key.numpad5,
        0x004d => zw.Key.numpad6,
        0x0047 => zw.Key.numpad7,
        0x0048 => zw.Key.numpad8,
        0x0049 => zw.Key.numpad9,
        0x0052 => zw.Key.numpad0,
        0x0053 => zw.Key.numpad_decimal,
        0x0056 => zw.Key.intl_backslash,
        0xe05d => zw.Key.context_menu,
        0xe05e => zw.Key.power,
        0x0059 => zw.Key.numpad_equal,
        0x0064 => zw.Key.f13,
        0x0065 => zw.Key.f14,
        0x0066 => zw.Key.f15,
        0x0067 => zw.Key.f16,
        0x0068 => zw.Key.f17,
        0x0069 => zw.Key.f18,
        0x006a => zw.Key.f19,
        0x006b => zw.Key.f20,
        0x006c => zw.Key.f21,
        0x006d => zw.Key.f22,
        0x006e => zw.Key.f23,
        0x0076 => zw.Key.f24,
        0xe03b => zw.Key.help,
        0xe008 => zw.Key.undo,
        0xe017 => zw.Key.cut,
        0xe018 => zw.Key.copy,
        0xe00a => zw.Key.paste,
        0xe020 => zw.Key.audio_volume_mute,
        0xe030 => zw.Key.audio_volume_up,
        0xe02e => zw.Key.audio_volume_down,
        0x007e => zw.Key.numpad_comma,
        0x0073 => zw.Key.intl_ro,
        0x0070 => zw.Key.kana_mode,
        0x007d => zw.Key.intl_yen,
        0x0079 => zw.Key.convert,
        0x007b => zw.Key.non_convert,
        0x0072 => zw.Key.lang1,
        0x0071 => zw.Key.lang2,
        0x0078 => zw.Key.lang3,
        0x0077 => zw.Key.lang4,
        0x001d => zw.Key.control_left,
        0x002a => zw.Key.shift_left,
        0x0038 => zw.Key.alt_left,
        0xe05b => zw.Key.meta_left,
        0xe01d => zw.Key.control_right,
        0x0036 => zw.Key.shift_right,
        0xe038 => zw.Key.alt_right,
        0xe05c => zw.Key.meta_right,
        0xe019 => zw.Key.media_track_next,
        0xe010 => zw.Key.media_track_previous,
        0xe024 => zw.Key.media_stop,
        0xe02c => zw.Key.eject,
        0xe022 => zw.Key.media_play_pause,
        0xe06d => zw.Key.media_select,
        0xe06c => zw.Key.launch_mail,
        0xe021 => zw.Key.launch_app1,
        0xe06b => zw.Key.launch_app2,
        0xe065 => zw.Key.browser_search,
        0xe032 => zw.Key.browser_home,
        0xe06a => zw.Key.browser_back,
        0xe069 => zw.Key.browser_forward,
        0xe068 => zw.Key.browser_stop,
        0xe067 => zw.Key.browser_refresh,
        0xe066 => zw.Key.browser_favorites,
        else => zw.Key.unidentified,
    };
}

// =================================================================================================
// MISC ROUTINES
// =================================================================================================

/// Ensures that the current process is DPI aware.
///
/// # Returns
///
/// This function returns whether the operation was successful.
pub fn becomeDpiAware() DpiAwareness {
    const SetProcessDpiAwarenessContext = win32.ui.hi_dpi.SetProcessDpiAwarenessContext;
    const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = win32.ui.hi_dpi.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2;
    const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE = win32.ui.hi_dpi.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE;

    var ret: win32.foundation.BOOL = undefined;

    ret = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (ret != 0) return .per_monitor_v2;
    log.warn("`SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)` failed: {}", .{fmtLastError()});

    ret = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE);
    if (ret != 0) return .per_monitor;
    log.warn("`SetProcessDpiAwarenessContext(PER_MONITOR_AWARE)` failed: {}", .{fmtLastError()});

    return .unaware;
}

// =================================================================================================
// FUNCTION WRAPPERS
// =================================================================================================

/// Invokes the function `f`.
///
/// If it returns the value zero, then its return type is checked and the function panics with
/// an appropriate error message.
///
/// This behavior is common to functions like `GetWindowLongPtrW` or `SetWindowLongPtrW`.
fn checkZeroReturnType(
    f_name: []const u8,
    f: anytype,
    params: anytype,
) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    const SetLastError = win32.foundation.SetLastError;
    const GetLastError = win32.foundation.GetLastError;

    // The function might return zero if:
    //
    // 1. The operation failed.
    //
    // 2. The success value of the function was actually zero. For `Get*` functions, it means that
    //    the requested vale was equal to zero. For `Set*` functions, it means that the previous
    //    value of the modified field was zero.
    //
    // In case of success, the function will *not* override the thread's error code. This means that
    // we can detect errors by first clearing the thread's error code, then checking the code again
    // if the function returns zero. If the code has changed, then it means that an error occured.

    if (std.debug.runtime_safety) {
        SetLastError(.NO_ERROR);
    }

    const ret = @call(.auto, f, params);

    if (std.debug.runtime_safety and ret == 0) {
        const code = GetLastError();
        if (code != .NO_ERROR) {
            @branchHint(.cold);
            std.debug.panic("`{s}` failed unexpectedly: {}", .{ f_name, fmtError(code) });
        }
    }

    return ret;
}

/// Invokes the `GetWindowLongPtrW` function.
///
/// When runtime safety is enabled, this function checks for errors. I don't actually know in what
/// case the function can fail. The only way I know for this function to fail is invalid input. But
/// just in case, we do check.
fn getWindowLongPtr(hwnd: win32.foundation.HWND, id: win32.ui.windows_and_messaging.WINDOW_LONG_PTR_INDEX) usize {
    const GetWindowLongPtrW = win32.ui.windows_and_messaging.GetWindowLongPtrW;
    return @bitCast(checkZeroReturnType("GetWindowLongPtrW", GetWindowLongPtrW, .{ hwnd, id }));
}

/// Invokes the `SetWindowLongPtrW` function.
///
/// When runtime safety is enabled, this function checks for errors. I don't actually know in what
/// case the function can fail. The only way I know for this function to fail is invalid input. But
/// just in case, we do check.
fn setWindowLongPtr(hwnd: win32.foundation.HWND, id: win32.ui.windows_and_messaging.WINDOW_LONG_PTR_INDEX, value: usize) void {
    const SetWindowLongPtrW = win32.ui.windows_and_messaging.SetWindowLongPtrW;
    _ = checkZeroReturnType("SetWindowLongPtrW", SetWindowLongPtrW, .{ hwnd, id, @as(isize, @bitCast(value)) });
}

/// Invokes the `GetWindowLongW` function.
///
/// When runtime safety is enabled, this function checks for errors. I don't actually know in what
/// case the function can fail. The only way I know for this function to fail is invalid input. But
/// just in case, we do check.
fn getWindowLong(hwnd: win32.foundation.HWND, id: win32.ui.windows_and_messaging.WINDOW_LONG_PTR_INDEX) u32 {
    const GetWindowLongW = win32.ui.windows_and_messaging.GetWindowLongW;
    return @bitCast(checkZeroReturnType("GetWindowLongW", GetWindowLongW, .{ hwnd, id }));
}

/// Invokes the `SetWindowLongW` function.
///
/// When runtime safety is enabled, this function checks for errors. I don't actually know in what
/// case the function can fail. The only way I know for this function to fail is invalid input. But
/// just in case, we do check.
fn setWindowLong(hwnd: win32.foundation.HWND, id: win32.ui.windows_and_messaging.WINDOW_LONG_PTR_INDEX, value: u32) void {
    const SetWindowLongW = win32.ui.windows_and_messaging.SetWindowLongW;
    _ = checkZeroReturnType("SetWindowLongW", SetWindowLongW, .{ hwnd, id, @as(i32, @bitCast(value)) });
}

/// Returns the module handle of the calling process.
fn getCurrentModuleHandle() zw.Error!win32.foundation.HINSTANCE {
    const GetModuleHandleW = win32.system.library_loader.GetModuleHandleW;

    const hinstance = GetModuleHandleW(null);
    if (hinstance == null) {
        @branchHint(.cold);
        log.err("`GetModuleHandleW` failed: {}", .{fmtLastError()});
        return zw.Error.PlatformError;
    }
    return hinstance.?;
}

/// Registers a new window class with the parameters that our library needs.
fn registerClass(
    class_name: [*:0]const u16,
    hinstance: win32.foundation.HINSTANCE,
    wndproc: win32.ui.windows_and_messaging.WNDPROC,
) zw.Error!void {
    const RegisterClassExW = win32.ui.windows_and_messaging.RegisterClassExW;
    const WNDCLASSEXW = win32.ui.windows_and_messaging.WNDCLASSEXW;

    const class_atom = RegisterClassExW(&WNDCLASSEXW{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = .{ .HREDRAW = 1, .VREDRAW = 1 },
        .lpfnWndProc = wndproc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    });
    if (class_atom == 0) {
        @branchHint(.cold);
        log.err("`RegisterClassExW` failed: {}", .{fmtLastError()});
        return zw.Error.PlatformError;
    }
}

/// Unregisters the provided window class.
///
/// Logs an error message if the function fails if runtime safety is enabled.
fn unregisterClass(class_name: [*:0]align(1) const u16, hinstance: win32.foundation.HINSTANCE) void {
    const UnregisterClassW = win32.ui.windows_and_messaging.UnregisterClassW;

    const ret = UnregisterClassW(class_name, hinstance);
    if (std.debug.runtime_safety and ret == 0) {
        @branchHint(.cold);
        log.warn("`UnregisterClassW` failed: {}", .{fmtLastError()});
    }
}

/// Creates a new window with the provided title.
///
/// Most of the parameters of the created window will use the default values, except for:
///
/// * `title` - will contain the title of the created window.
///
/// * `window_class` - the name of the window class associated with the window.
///
/// * `styles` - The window styles of the created window.
///
/// * `hinstance` - The HINSTANCE that will own the window.
///
/// * `init_data` - The data that will be made available to the window procedure associated
///   with the provided window class.
fn createWindow(
    title: [*:0]const u16,
    window_class: [*:0]const u16,
    styles: WindowStyles,
    hinstance: win32.foundation.HINSTANCE,
    init_data: *anyopaque,
) zw.Error!win32.foundation.HWND {
    const CreateWindowEx = win32.ui.windows_and_messaging.CreateWindowExW;
    const CW_USEDEFAULT = win32.ui.windows_and_messaging.CW_USEDEFAULT;

    const hwnd = CreateWindowEx(
        styles.ex_style,
        window_class,
        title,
        styles.style,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        null,
        null,
        hinstance,
        init_data,
    );
    if (hwnd == null) {
        @branchHint(.cold);
        log.err("`CreateWindowExW` failed: {}", .{fmtLastError()});
        return zw.Error.PlatformError;
    }
    return hwnd.?;
}

/// Destroys the provided window.
///
/// Logs an error message if the function fails if runtime safety is enabled.
fn destroyWindow(hwnd: win32.foundation.HWND) void {
    const DestroyWindow = win32.ui.windows_and_messaging.DestroyWindow;

    const ret = DestroyWindow(hwnd);
    if (std.debug.runtime_safety and ret == 0) {
        @branchHint(.cold);
        log.warn("`DestroyWindow` failed: {}", .{fmtLastError()});
    }
}

/// Invokes the `SetWindowPos` function.
fn rawSetWindowPos(
    hwnd: win32.foundation.HWND,
    insert_after: ?win32.foundation.HWND,
    x: i32,
    y: i32,
    cx: i32,
    cy: i32,
    flags: win32.ui.windows_and_messaging.SET_WINDOW_POS_FLAGS,
) void {
    const SetWindowPos = win32.ui.windows_and_messaging.SetWindowPos;

    const ret = SetWindowPos(hwnd, insert_after, x, y, cx, cy, flags);
    if (std.debug.runtime_safety and ret == 0) {
        @branchHint(.cold);
        log.warn("`SetWindowPos` failed: {}", .{fmtLastError()});
    }
}

/// Invokes the `EnableMenuItem` function.
fn enableMenuItem(
    hmenu: ?win32.ui.windows_and_messaging.HMENU,
    id: u32,
    flags: win32.ui.windows_and_messaging.MENU_ITEM_FLAGS,
) void {
    const EnableMenuItem = win32.ui.windows_and_messaging.EnableMenuItem;

    const ret = EnableMenuItem(hmenu, id, flags);
    if (std.debug.runtime_safety and ret == -1) {
        @branchHint(.cold);
        log.warn("`EnableMenuItem` failed: menu item does not exist", .{});
    }
}

/// Invokes the `AdjustWindowRectEx
fn adjustWindowRectEx(
    rect: *win32.foundation.RECT,
    has_menu: bool,
    styles: WindowStyles,
) error{PlatformError}!void {
    const AdjustWindowRectEx = win32.ui.windows_and_messaging.AdjustWindowRectEx;

    if (AdjustWindowRectEx(rect, styles.style, @intFromBool(has_menu), styles.ex_style) == 0) {
        @branchHint(.cold);
        log.warn("`AdjustWindowRectEx` failed: {}", .{fmtLastError()});
        return error.PlatformError;
    }
}

/// Creates a new high-resolution waitable timer.
fn createWaitableTimer() error{PlatformError}!win32.foundation.HANDLE {
    const CreateWaitableTimerExW = win32.system.threading.CreateWaitableTimerExW;
    const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION = win32.system.threading.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION;
    const TIMER_ALL_ACCESS = win32.system.threading.TIMER_ALL_ACCESS;

    const ret = CreateWaitableTimerExW(null, null, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, @bitCast(TIMER_ALL_ACCESS));

    if (ret == null) {
        @branchHint(.cold);
        log.err("`CreateWaitableTimerExW` failed: {}", .{fmtLastError()});
        return error.PlatformError;
    }

    return ret.?;
}

/// Configures a waitable timer to use the provided value.
///
/// # Remarks
///
/// Positive durations mean that the timer uses an absolute number of 100-nanoseconds since
/// 1970-01-01.
///
/// Negative durations mean that the duration is relative to the time of calling the function,
/// also measured in 100-nanoseconds.
fn setWaitableTimer(timer: win32.foundation.HANDLE, duration: i64) error{PlatformError}!void {
    const SetWaitableTimer = win32.system.threading.SetWaitableTimer;
    const LARGE_INTEGER = win32.foundation.LARGE_INTEGER;

    const ret = SetWaitableTimer(
        timer,
        &LARGE_INTEGER{ .QuadPart = duration },
        0,
        null,
        null,
        0,
    );

    if (ret == 0) {
        @branchHint(.cold);
        log.err("`SetWaitableTimer` failed: {}", .{fmtLastError()});
        return error.PlatformError;
    }
}

/// Closes the provided handle.
///
/// Prints an error message if the operation fail when runtime safety is on.
fn closeHandle(handle: win32.foundation.HANDLE) void {
    const CloseHandle = win32.foundation.CloseHandle;

    const ret = CloseHandle(handle);
    if (std.debug.runtime_safety and ret == 0) {
        @branchHint(.cold);
        log.warn("`CloseHandle` failed: {}", .{fmtLastError()});
    }
}

/// Creates a new event.
fn createEvent() error{PlatformError}!win32.foundation.HANDLE {
    const CreateEventExW = win32.system.threading.CreateEventExW;
    const EVENT_ALL_ACCESS = win32.system.threading.EVENT_ALL_ACCESS;

    const ret = CreateEventExW(null, null, .{}, @bitCast(EVENT_ALL_ACCESS));

    if (ret == null) {
        @branchHint(.cold);
        log.err("`CreateEventExW` failed: {}", .{fmtLastError()});
        return error.PlatformError;
    }

    return ret.?;
}

/// Signals the provided event.
fn setEvent(event: win32.foundation.HANDLE) void {
    const SetEvent = win32.system.threading.SetEvent;

    const ret = SetEvent(event);
    if (std.debug.runtime_safety and ret == 0) {
        @branchHint(.cold);
        log.warn("`SetEvent` failed: {}", .{fmtLastError()});
    }
}

/// Represents the state of a key on 8 bits.
const KeyState8 = packed struct(u8) {
    /// Whether the key is toggled.
    ///
    /// This is only relevent for keys that have two states, like CAPS LOCK or
    /// NUM LOCK.
    toggled: bool,

    _unused: u6 = 0,

    /// Whether the key is down.
    pressed: bool,

    /// An instance of `KeyState8` that is both not toggled and not pressed.
    pub const zero = KeyState8{ .toggled = false, .pressed = false };
};

/// Attempts to read the current state of the keyboard.
///
/// If an error occurs, the function clears the input keyboard state and logs the error.
fn getKeyboardState(out: *[256]KeyState8) void {
    const GetKeyboardState = win32.ui.input.keyboard_and_mouse.GetKeyboardState;

    if (GetKeyboardState(@ptrCast(out)) == 0) {
        log.err("`GetKeyboardState` failed: {}", .{fmtLastError()});
        @memset(out, KeyState8.zero);
    }
}

/// Invokes the `ToUnicode` function with the provided parameters.
///
/// If the keystroke starts a dead-key sequence, the function returns `null`.
///
/// # Parameters
///
/// - `virtual_key_code`: The virtual-key code of the keystroke that must be converted to a
///   character.
///
/// - `scan_code`: The scan-code of the keystroke that must be converted to a character. Note that
///   bit 15 of the scan-code should indicate whether the key is being pressed or released (1 for
///   break-codes, 0 for make-codes).
///
/// - `keyboard_state`: The current state of the keyboard.
///
/// - `dont_modify_keyboard_state`: Whether the keyboard state should not be updated. This is only
///   available since Windows 10, version 1607.
///
/// - `buf`: The buffer that will be used to store the output data.
///
/// # Errors
///
/// If the function fails, or if it produces an invalid UTF-16 sequence, the functions returns
/// an empty string and an error is logged.
fn toUnicode(
    virtual_key_code: win32.ui.input.keyboard_and_mouse.VIRTUAL_KEY,
    scan_code: u16,
    keyboard_state: *[256]KeyState8,
    dont_modify_keyboard_state: bool,
    buf: *[16]u8,
) ?[]const u8 {
    const ToUnicode = win32.ui.input.keyboard_and_mouse.ToUnicode;

    var flags: u32 = 0;
    if (dont_modify_keyboard_state) flags |= 1 << 2;

    var buf_utf16: [8]u16 = undefined;
    const ret = ToUnicode(
        @intFromEnum(virtual_key_code),
        scan_code,
        @ptrCast(keyboard_state),
        @ptrCast(&buf_utf16),
        8,
        flags,
    );

    if (ret < 0) {
        // The keystroke resulted in a dead-character.
        return null;
    }

    const utf16 = buf_utf16[0..@as(usize, @intCast(ret))];

    const len_utf8 = std.unicode.utf16LeToUtf8(buf, utf16) catch {
        log.warn("`ToUnicode` produced invalid UTF-16: {any}", .{utf16});
        return &.{};
    };

    return buf[0..len_utf8];
}

/// Resolves the character associated with the provided keystroke using the provided
/// keyboard state.
fn resolveCharacter(
    virtual_key_code: win32.ui.input.keyboard_and_mouse.VIRTUAL_KEY,
    scan_code: u16,
    windows_version: OsVersion,
    dont_modify_keyboard_state: bool,
    keyboard_state: *[256]KeyState8,
    characters_buf: *[16]u8,
) []const u8 {

    // In order to get character information, we can use the `ToUnicode` function
    // to find a label associated with the keystroke.
    //
    // There is a few caveats with using this function, however:
    //
    // 1. By default, it messes up the kernel's internal keyboard state responsible
    //    for dealing with dead-chars. This means that using `ToUnicode` will actually
    //    simulate a keypress and if they keypress would have started a dead character
    //    sequence, then it return nothing and act as if the user had actually
    //    pressed that key.
    //
    // 2. There is a flag that can be used to prevent this behavior, but it is only
    //    available since Windows 10, Version 1607.
    //
    // For this reason, for versions of Windows prior to that one, we only use
    // `ToUnicode` for non-dead-char sequences.

    const supports_not_modifying_keyboard_state = windows_version.isAtLeast(.new(10, 0, 1607));

    if (dont_modify_keyboard_state and supports_not_modifying_keyboard_state) {
        // We can resolve the dead-char without breaking the keyboard state of the
        // user. Let's do it.

        return toUnicode(
            virtual_key_code,
            scan_code,
            keyboard_state,
            true,
            characters_buf,
        ) orelse &.{};
    }

    if (!dont_modify_keyboard_state) {

        // If we're not in a dead-char sequence, we don't need to worry about breaking
        // anything.
        //
        // We can just call `ToUnicode` inconditionally and attempt to resolve the
        // dead characters if they come up.

        const maybe_char = toUnicode(
            virtual_key_code,
            scan_code,
            keyboard_state,
            false,
            characters_buf,
        );

        if (maybe_char) |c| {
            return c;
        }

        // We encountered a dead-character.
        //
        // Pressing the space key will usually produce the dead-character itself.
        const second_try = toUnicode(
            .SPACE,
            0x0039,
            keyboard_state,
            false,
            characters_buf,
        );

        if (second_try) |c| {
            return c;
        }
    }

    return &.{};
}

/// Invokes the `TrackMouseEvent` function.
///
/// Logs errors if they happen.
fn trackMouseEvent(hwnd: win32.foundation.HWND, flags: win32.ui.input.keyboard_and_mouse.TRACKMOUSEEVENT_FLAGS) void {
    const TrackMouseEvent = win32.ui.input.keyboard_and_mouse.TrackMouseEvent;
    const TRACKMOUSEEVENT = win32.ui.input.keyboard_and_mouse.TRACKMOUSEEVENT;

    var arg = TRACKMOUSEEVENT{
        .cbSize = @sizeOf(TRACKMOUSEEVENT),
        .dwFlags = flags,
        .hwndTrack = hwnd,
        .dwHoverTime = 0,
    };

    const ret = TrackMouseEvent(&arg);

    if (std.debug.runtime_safety and ret == 0) {
        log.warn("`TrackMouseEvent` failed: {}", .{fmtLastError()});
    }
}

/// Invokes the `EnableNonClientDpiScaling` function.
fn enableNonClientDpiScaling(hwnd: win32.foundation.HWND) void {
    const EnableNonClientDpiScaling = win32.ui.hi_dpi.EnableNonClientDpiScaling;

    const ret = EnableNonClientDpiScaling(hwnd);
    if (ret == 0) {
        log.warn("`EnableNonClientDpiScaling` failed: {}", .{fmtLastError()});
    }
}

/// Invokes the `RedrawWindow` function.
fn rawRedrawWindow(hwnd: win32.foundation.HWND) void {
    const RedrawWindow = win32.graphics.gdi.RedrawWindow;
    const RDW_INVALIDATE = win32.graphics.gdi.RDW_INVALIDATE;

    const ret = RedrawWindow(hwnd, null, null, RDW_INVALIDATE);
    if (std.debug.runtime_safety and ret == 0) {
        log.warn("`RedrawWindow` failed: {}", .{fmtLastError()});
    }
}

/// Invokes the `RegisterRawInputDevices` function.
fn registerRawInputDevices(devs: []win32.ui.input.RAWINPUTDEVICE) void {
    const RegisterRawInputDevices = win32.ui.input.RegisterRawInputDevices;
    const RAWINPUTDEVICE = win32.ui.input.RAWINPUTDEVICE;

    const ret = RegisterRawInputDevices(devs.ptr, @intCast(devs.len), @sizeOf(RAWINPUTDEVICE));
    if (std.debug.runtime_safety and ret == 0) {
        log.warn("`RegisterRawInputDevices` failed: {}", .{fmtLastError()});
    }
}

/// Sets up raw input for the application.
fn setupRawInput() void {
    const RAWINPUTDEVICE = win32.ui.input.RAWINPUTDEVICE;
    const HID_USAGE_PAGE_GENERIC = win32.devices.human_interface_device.HID_USAGE_PAGE_GENERIC;
    const HID_USAGE_GENERIC_MOUSE = win32.devices.human_interface_device.HID_USAGE_GENERIC_MOUSE;
    const HID_USAGE_GENERIC_KEYBOARD = win32.devices.human_interface_device.HID_USAGE_GENERIC_KEYBOARD;

    var devices = [_]RAWINPUTDEVICE{
        RAWINPUTDEVICE{
            .dwFlags = .{ .DEVNOTIFY = 1 },
            .hwndTarget = null,
            .usUsagePage = HID_USAGE_PAGE_GENERIC,
            .usUsage = HID_USAGE_GENERIC_MOUSE,
        },
        RAWINPUTDEVICE{
            .dwFlags = .{ .DEVNOTIFY = 1 },
            .hwndTarget = null,
            .usUsagePage = HID_USAGE_PAGE_GENERIC,
            .usUsage = HID_USAGE_GENERIC_KEYBOARD,
        },
    };

    registerRawInputDevices(&devices);
}

/// Returns whether the message queue of the provided window contains
/// any keyboard events.
fn hasKeyboardEvents(hwnd: win32.foundation.HWND) bool {
    const PeekMessageW = win32.ui.windows_and_messaging.PeekMessageW;
    const MSG = win32.ui.windows_and_messaging.MSG;
    const WM_KEYFIRST = win32.ui.windows_and_messaging.WM_KEYFIRST;
    const WM_KEYLAST = win32.ui.windows_and_messaging.WM_KEYLAST;
    const PM_NOREMOVE = win32.ui.windows_and_messaging.PM_NOREMOVE;

    var msg: MSG = undefined;
    return PeekMessageW(&msg, hwnd, WM_KEYFIRST, WM_KEYLAST, PM_NOREMOVE) != 0;
}
