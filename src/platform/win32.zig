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
            return self.allocator;
        }

        pub inline fn exit(self: *zw.EventLoop) void {
            self.platform_specific.exiting = true;
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

        pub inline fn setMinSurfaceSize(self: *zw.Window, size: zw.Size) void {
            self.platform_specific.min_surface_size = size;
            const current_size = self.platform_specific.getClientRect().size();
            self.platform_specific.setClientSize(current_size);
        }

        pub inline fn setMaxSurfaceSize(self: *zw.Window, size: zw.Size) void {
            self.platform_specific.max_surface_size = size;
            const current_size = self.platform_specific.getClientRect().size();
            self.platform_specific.setClientSize(current_size);
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
    inner: win32.system.system_information.OSVERSIONINFOW,

    /// Gets the current OS version.
    pub fn get() OsVersion {
        var inner: win32.system.system_information.OSVERSIONINFOW = undefined;

        const ret = RtlGetVersion(&inner);

        // `RtlGetVersion` should always return success.
        std.debug.assert(ret == win32.foundation.STATUS_SUCCESS);

        return OsVersion{ .inner = inner };
    }

    pub fn format(self: OsVersion, comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opts;

        return writer.print(
            "{}.{}.{}",
            .{
                self.inner.dwMajorVersion,
                self.inner.dwMinorVersion,
                self.inner.dwBuildNumber,
            },
        );
    }
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

    /// The module handle of the current process.
    hinstance: win32.foundation.HINSTANCE,

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

        // Register the window class that will be used by all windows created on this
        // event loop.
        try registerClass(Window.class_name, hinstance, &wndProc);
        errdefer unregisterClass(Window.class_name, hinstance);

        self.* = EventLoop{
            .allocator = config.allocator,
            .user_app = config.user_app,
            .windows_version = windows_version,
            .hinstance = hinstance,
        };
    }

    /// Releases the resources associated with the event loop.
    ///
    /// **Note:** this function does *not* free the pointer.
    pub fn deinit(self: *EventLoop) void {
        unregisterClass(Window.class_name, self.hinstance);
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

        const infinite_timeout = std.math.maxInt(u64);

        // Invoke the `.about_to_wait` event and ask the user to provide the timeout that should
        // be used for this wait. Once the event has returned, we can use the new `timeout_ns`
        // value.
        var timeout_ns: u64 = infinite_timeout;
        self.sendEvent(.{ .about_to_wait = .{ .timeout_ns = &timeout_ns } });

        // NOTE:
        //  `QS_ALLINPUT` and `MWMO_INPUTAVAILABLE` ensure that the function will wake up the
        //  thread when new messages are available in the message queue. Those messages will
        //  not be removed from the queue and we still need to invoke `PeekMessageW` a bunch of
        //  times to handle the events.
        const ret = MsgWaitForMultipleObjectsEx(
            0,
            null,
            std.math.lossyCast(u32, timeout_ns / std.time.ns_per_ms),
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
    pub fn dispatchPendingMessages(self: *EventLoop) void {
        const PeekMessage = win32.ui.windows_and_messaging.PeekMessageW;
        const DispatchMessage = win32.ui.windows_and_messaging.DispatchMessageW;
        const TranslateMessage = win32.ui.windows_and_messaging.TranslateMessage;
        const MSG = win32.ui.windows_and_messaging.MSG;
        const PM_REMOVE = win32.ui.windows_and_messaging.PM_REMOVE;

        _ = self;

        // This is the regular translate-dispatch message loop. During this loop, the window
        // procedure registered for our window will be invoked multiple times with a bunch of
        // events.
        //
        // Note that this is not one-to-one. Sometimes zero events will be emitted, sometimes
        // multiple events will be emitted.

        var msg: MSG = undefined;
        while (PeekMessage(&msg, null, 0, 0, PM_REMOVE) != 0) {
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
        _ = setWindowLong(hwnd, win32.ui.windows_and_messaging.GWL_STYLE, @bitCast(styles.style));
        _ = setWindowLong(hwnd, win32.ui.windows_and_messaging.GWL_EXSTYLE, @bitCast(styles.ex_style));

        if (config.visible) {
            var show_command: win32.ui.windows_and_messaging.SHOW_WINDOW_CMD = .{};
            show_command.SHOWNORMAL = @intFromBool(!config.minimized);
            show_command.SHOWMINIMIZED = @intFromBool(config.maximized or config.minimized);
            show_command.SHOWNOACTIVATE = @intFromBool(!config.auto_focus);
            self.showWindow(show_command);
        }
    }

    /// Releases the resources associated with the window.
    ///
    /// **Note:** this function does not destroys the memory.
    pub fn deinit(self: *Window) void {
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

            // All post-creation initialization should go here.
            if (init_data.config.surface_size) |sz| {
                window.setClientSize(sz.clamp(window.min_surface_size, window.max_surface_size));
            }

            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        else => {
            if (userdata == 0) {
                @branchHint(.unlikely);

                // The window is not yet initialized, and the event is not part of the ones we know
                // of to initialize the window. Just call the default window procedure.
                return DefWindowProcW(hwnd, msg, wparam, lparam);
            } else {
                // The window is initialized. We're receiving regular events for the window.
                return handleMessage(@ptrFromInt(userdata), msg, wparam, lparam);
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

        else => return DefWindowProcW(window.hwnd, msg, wparam, lparam),
    }
}

// =================================================================================================
// FUNCTION WRAPPERS
// =================================================================================================

/// Invokes the `GetWindowLongPtrW` function.
///
/// When runtime safety is enabled, this function checks for errors. I don't actually know in what
/// case the function can fail. The only way I know for this function to fail is invalid input. But
/// just in case, we do check.
fn getWindowLongPtr(hwnd: win32.foundation.HWND, id: win32.ui.windows_and_messaging.WINDOW_LONG_PTR_INDEX) usize {
    const SetLastError = win32.foundation.SetLastError;
    const GetLastError = win32.foundation.GetLastError;
    const GetWindowLongPtrW = win32.ui.windows_and_messaging.GetWindowLongPtrW;

    // NOTE:
    //  In case of error, this functions returns zero. However, because the successful value might
    //  also be zero, we need a way to distinguish between two cases.
    //  The way to do this is to set the last error code before calling the function, and then,
    //  if the function returns zero, check the last error code again.

    if (std.debug.runtime_safety) {
        SetLastError(.NO_ERROR);
    }

    const ret = GetWindowLongPtrW(hwnd, id);

    if (std.debug.runtime_safety and ret == 0) {
        const code = GetLastError();
        if (code != .NO_ERROR) {
            @branchHint(.cold);
            std.debug.panic("`GetWindowLongPtrW` failed unexpectedly: {}", .{fmtError(code)});
        }
    }

    return @bitCast(ret);
}

/// Invokes the `SetWindowLongPtrW` function.
///
/// When runtime safety is enabled, this function checks for errors. I don't actually know in what
/// case the function can fail. The only way I know for this function to fail is invalid input. But
/// just in case, we do check.
fn setWindowLongPtr(hwnd: win32.foundation.HWND, id: win32.ui.windows_and_messaging.WINDOW_LONG_PTR_INDEX, value: usize) void {
    const SetLastError = win32.foundation.SetLastError;
    const GetLastError = win32.foundation.GetLastError;
    const SetWindowLongPtrW = win32.ui.windows_and_messaging.SetWindowLongPtrW;

    // NOTE:
    //  In case of error, this functions returns zero. However, because the successful value might
    //  also be zero, we need a way to distinguish between two cases.
    //  The way to do this is to set the last error code before calling the function, and then,
    //  if the function returns zero, check the last error code again.

    if (std.debug.runtime_safety) {
        SetLastError(.NO_ERROR);
    }

    const ret = SetWindowLongPtrW(hwnd, id, @bitCast(value));

    if (std.debug.runtime_safety and ret == 0) {
        const code = GetLastError();
        if (code != .NO_ERROR) {
            @branchHint(.cold);
            std.debug.panic("`SetWindowLongPtrW` failed unexpectedly: {}", .{fmtError(code)});
        }
    }
}

/// Invokes the `GetWindowLongW` function.
///
/// When runtime safety is enabled, this function checks for errors. I don't actually know in what
/// case the function can fail. The only way I know for this function to fail is invalid input. But
/// just in case, we do check.
fn getWindowLong(hwnd: win32.foundation.HWND, id: win32.ui.windows_and_messaging.WINDOW_LONG_PTR_INDEX) u32 {
    const SetLastError = win32.foundation.SetLastError;
    const GetLastError = win32.foundation.GetLastError;
    const GetWindowLongW = win32.ui.windows_and_messaging.GetWindowLongW;

    // NOTE:
    //  In case of error, this functions returns zero. However, because the successful value might
    //  also be zero, we need a way to distinguish between two cases.
    //  The way to do this is to set the last error code before calling the function, and then,
    //  if the function returns zero, check the last error code again.

    if (std.debug.runtime_safety) {
        SetLastError(.NO_ERROR);
    }

    const ret = GetWindowLongW(hwnd, id);

    if (std.debug.runtime_safety and ret == 0) {
        const code = GetLastError();
        if (code != .NO_ERROR) {
            @branchHint(.cold);
            std.debug.panic("`GetWindowLongW` failed unexpectedly: {}", .{fmtError(code)});
        }
    }

    return @bitCast(ret);
}

/// Invokes the `SetWindowLongW` function.
///
/// When runtime safety is enabled, this function checks for errors. I don't actually know in what
/// case the function can fail. The only way I know for this function to fail is invalid input. But
/// just in case, we do check.
fn setWindowLong(hwnd: win32.foundation.HWND, id: win32.ui.windows_and_messaging.WINDOW_LONG_PTR_INDEX, value: u32) u32 {
    const SetLastError = win32.foundation.SetLastError;
    const GetLastError = win32.foundation.GetLastError;
    const SetWindowLongW = win32.ui.windows_and_messaging.SetWindowLongW;

    // NOTE:
    //  In case of error, this functions returns zero. However, because the successful value might
    //  also be zero, we need a way to distinguish between two cases.
    //  The way to do this is to set the last error code before calling the function, and then,
    //  if the function returns zero, check the last error code again.

    if (std.debug.runtime_safety) {
        SetLastError(.NO_ERROR);
    }

    const ret = SetWindowLongW(hwnd, id, @bitCast(value));

    if (std.debug.runtime_safety and ret == 0) {
        const code = GetLastError();
        if (code != .NO_ERROR) {
            @branchHint(.cold);
            std.debug.panic("`GetWindowLongW` failed unexpectedly: {}", .{fmtError(code)});
        }
    }

    return @bitCast(ret);
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
pub fn enableMenuItem(
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
pub fn adjustWindowRectEx(
    rect: *win32.foundation.RECT,
    has_menu: bool,
    styles: WindowStyles,
) error{PlatformError}!void {
    const AdjustWindowRectEx = win32.ui.windows_and_messaging.AdjustWindowRectEx;

    if (AdjustWindowRectEx(rect, styles.style, @intFromBool(has_menu), styles.ex_style) == 0) {
        log.warn("`AdjustWindowRectEx` failed: {}", .{fmtLastError()});
        return error.PlatformError;
    }
}
