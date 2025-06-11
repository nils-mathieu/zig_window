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
        timeout_ns: *u64,
    },

    /// A window has been requested to close by the user.
    ///
    /// Note that the application is free to choose what to do as a result of this event. They may
    /// choose to show an error message asking the user to save their work, or they may close
    /// the window by calling `Window.close()`, or they may completely stop the event loop by
    /// calling `EventLoop.exit()`.
    close_requested: struct {
        /// The window that has been requested to close.
        window: *Window,
    },

    /// Indicates that a window should redraw its content.
    ///
    /// Rendering may be done on any thread, but presenting the rendered frame to the window should be done
    /// in this event callback.
    redraw_requested: *Window,

    /// The size of a window's surface has changed.
    ///
    /// Note that this corrsepond to the window's "surface" area (as opposed to the outer window
    /// size which includes its title bar and other OS-specific decorations).
    surface_resized: struct {
        /// The window whose size has changed.
        window: *Window,

        /// The new width of the window's surface area, measured in physical pixels.
        width: u32,
        /// The new height of the window's surface area, measured in physical pixels.
        height: u32,
    },

    /// A window's keyboard focus state has changed.
    focus_changed: struct {
        /// The window whose focus state has changed.
        window: *Window,
        /// Whether the window is now in focus.
        focused: bool,
    },

    /// A window's scale factor has changed.
    scale_factor_changed: struct {
        /// The window whose scale factor has changed.
        window: *Window,
        /// The new scale factor of the window.
        scale_factor: f64,
    },

    /// A keyboard event has been received.
    keyboard: Keyboard,

    /// Some text was typed.
    text_typed: TextTyped,

    /// Indicates that a pointing device has moved over a window.
    pointer_moved: struct {
        /// The window that received the event.
        window: *Window,
        /// The ID of the keyboard device that produced the event.
        ///
        /// If `null`, the device could not be determined.
        device: ?DeviceId,

        /// The X position of the pointing device, relative to the top-left corner of the
        /// window's surface area.
        x: f64,
        /// The Y position of the pointing device, relative to the top-left corner of the
        /// window's surface area.
        y: f64,

        /// The ID of the finger that produced the event, if a multi-touch device
        /// is being used.
        ///
        /// If no finger is associated with the event, this will be zero.
        finger_id: u32,

        /// The force associated with the event.
        ///
        /// For mouse events, this will always be one. For touch-screen events, this may contain
        /// the force associated with the touch.
        force: f64,
    },

    /// Indicates that a pointing device has entered a window's surface area.
    pointer_entered: struct {
        /// The window that received the event.
        window: *Window,
        /// The ID of the keyboard device that produced the event.
        ///
        /// If `null`, the device could not be determined.
        device: ?DeviceId,

        /// The X position of the pointing device, relative to the top-left corner of the
        /// window's surface area.
        x: f64,
        /// The Y position of the pointing device, relative to the top-left corner of the
        /// window's surface area.
        y: f64,

        /// The ID of the finger that produced the event, if a multi-touch device
        /// is being used.
        ///
        /// If no finger is associated with the event, this will be zero.
        finger_id: u32,
    },

    /// Indicates that a pointing device has left a window's surface area.
    pointer_left: struct {
        /// The window that received the event.
        window: *Window,
        /// The ID of the keyboard device that produced the event.
        ///
        /// If `null`, the device could not be determined.
        device: ?DeviceId,

        /// The X position of the pointing device, relative to the top-left corner of the
        /// window's surface area.
        x: f64,
        /// The Y position of the pointing device, relative to the top-left corner of the
        /// window's surface area.
        y: f64,

        /// The ID of the finger that produced the event, if a multi-touch device
        /// is being used.
        ///
        /// If no finger is associated with the event, this will be zero.
        finger_id: u32,
    },

    /// A pointing device button has been pressed or released.
    pointer_button: struct {
        /// The window that received the event.
        window: *Window,
        /// The ID of the device that produced the event, if available.
        device: ?DeviceId,

        /// The X position of the pointing device, relative to the top-left corner of the
        /// window's surface area.
        x: f64,
        /// The Y position of the pointing device, relative to the top-left corner of the
        /// window's surface area.
        y: f64,

        /// Whether the button was pressed.
        ///
        /// If `false`, it has been released.
        pressed: bool,

        /// The button that was pressed or released.
        button: PointerButton,

        /// The ID of the finger that produced the event, if a multi-touch device
        /// is being used.
        ///
        /// If no finger is associated with the event, this will be zero.
        finger_id: u32,

        /// The force associated with the event.
        ///
        /// For mouse events, this will always be one. For touch-screen events, this may contain
        /// the force associated with the touch.
        force: f64,
    },

    /// Indicates that a mouse device has moved.
    ///
    /// Note that this event is distinct from the `.pointer_moved` event. This is specifically
    /// related to mouse motion and may or may not be correlated to any cursor movement.
    ///
    /// Specifically, this event is not subject to cursor acceleration and other platform-specific
    /// transformations.
    mouse_moved: struct {
        /// The ID of the device that produced the event, if available.
        device: ?DeviceId,

        /// The amount of motion in the X direction.
        ///
        /// The exact unit of this field is unspecified and may vary between
        /// input devices.
        delta_x: f64,

        /// The amount of motion in the Y direction.
        ///
        /// The exact unit of this field is unspecified and may vary between
        /// input devices.
        delta_y: f64,
    },

    /// A pointer button.
    pub const PointerButton = enum(u8) {
        /// The primary pointer button.
        ///
        /// If the user hasn't inverted their primary and secondary buttons, this will be the
        /// left button.
        primary,

        /// The secondary pointer button.
        ///
        /// If the user hasn't inverted their primary and secondary buttons, this will be the
        /// right button.
        secondary,

        /// The middle pointer button.
        ///
        /// This is usually used when the mouse wheel is pressed.
        middle,

        /// The "back" pointer button.
        back,

        /// The "forward" pointer button.
        forward,

        // Other pointer buttons are possible.
        _,

        /// Creates a new `PointerButton` from the provided code.
        ///
        /// # Remarks
        ///
        /// This function assumes that the code is less or equal to `250`.
        pub fn other(code: u8) @This() {
            return @enumFromInt(code + 5);
        }

        /// Formats the pointer button as a string.
        pub fn format(self: @This(), comptime fmt: []const u8, opts: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = opts;

            if (std.enums.tagName(@This(), self)) |name| {
                return writer.print("{s}", .{name});
            } else {
                return writer.print("other({d})", .{@intFromEnum(self)});
            }
        }
    };

    /// A keyboard event.
    pub const Keyboard = struct {
        /// The window that received the event.
        window: *Window,
        /// The ID of the keyboard device that produced the event.
        ///
        /// If `null`, the device could not be determined.
        device: ?DeviceId,

        /// The physical key-code of the key that produced the event.
        ///
        /// Note that this field is not *not* dependent on the user's keyboard layout or input
        /// locale. Use it when the location of the key is more important than its actual meaning
        /// to the user.
        ///
        /// More information in the documentation for `Key`.
        key: Key,

        /// The raw scan-code associated with the event.
        ///
        /// This scan-code is platform-dependent and cannot be assumed to hold any meaning. They
        /// might not even be consistent across input devices.
        ///
        /// This field is intended to be used when the `Key` enumeration is unable to represent
        /// the keystroke (see `.unidentified`).
        scan_code: u32,

        /// The characters associated with the key.
        ///
        /// Use this field to determine the logical meaning of the key, taking into account
        /// eventual modifiers (like CTRL or SHIFT), and the user's keyboard layout and input
        /// locale.
        ///
        /// # Remarks
        ///
        /// This field *cannot* be used to determine the text produced by the keystroke. It will
        /// include any dead-key associated with the key, even if no text has been produced.
        characters: []const u8,

        /// The characters associated with the key, ignoring all modifiers that might apply.
        ///
        /// This field contains the same thing as `characters`, but ignoring modifiers like
        /// SHIFT or CTRL.
        ///
        /// For example, on a standard 101-key US keyboard, pressing SHIFT and A will produce an
        /// event with:
        ///
        /// * `characters`: `"A"`
        /// * `characters_without_modifiers`: `"a"`
        characters_without_modifiers: []const u8,

        /// The state transition associated with the event.
        ///
        /// This is used to determine if the key was pressed, released, or repeated.
        state: StateTransition,

        /// The state transition of a keyboard key.
        pub const StateTransition = enum {
            /// The key has been pressed, and it was previously released.
            pressed,

            /// The key has been released, and it was previously pressed.
            released,

            /// The key has been repeated. This means that the key was already considered pressed,
            /// but the keyboard sent its code again. This usually happens when the key is held
            /// down.
            repeated,
        };
    };

    /// A text event.
    ///
    /// See `.text_typed` for more information.
    pub const TextTyped = struct {
        /// The window that received the event.
        window: *Window,
        /// The ID of the keyboard device that produced the event.
        ///
        /// If `null`, the device could not be determined.
        device: ?DeviceId,

        /// The IME event that occured.
        ime: ImeEvent,
    };

    /// The state of an IME event sent to through a `.text_typed` event.
    pub const ImeEvent = union(enum) {
        /// IME was just enabled.
        enabled,

        /// IME was just disabled.
        disabled,

        /// Some text was commited.
        ///
        /// If you only care about the typed text, you can just check this variant.
        ///
        /// # Remarks
        ///
        /// It's possible (and expected) to get `commit` and `preedit` events when IMEs are
        /// disabled (when no `.enabled` or `.disabled` events have been received).
        ///
        /// This happens when input is received while IMEs have not been enabled manually
        /// by the application.
        commit: []const u8,

        /// Some text is being pre-edited.
        ///
        /// Those events don't indicate actual textual content written, but an indication of
        /// what is going to be commited.
        preedit: struct {
            /// The pre-edited text.
            text: []const u8,

            /// The start of the current cursor position.
            ///
            /// There is always: `0 <= cursor_start <= cursor_end <= text.len`.
            cursor_start: usize,
            /// The end of the current cursor position.
            ///
            /// There is always: `0 <= cursor_start <= cursor_end <= text.len`.
            cursor_end: usize,
        },
    };
};

/// The ID of an input device.
pub const DeviceId = *opaque {};

/// Represents a physical key code.
///
/// Physical key codes are *not* dependent on the user's keyboard layout and input locale. Use this
/// type when the physical location of the key matters more than it's actual meaning for the user.
///
/// For example, the key `.key_a` is emitted when pressing "A" on a standard 101-key US keyboard,
/// but also when pressing "Q" on a standard AZERTY keyboard.
///
/// The names and meaning of this enumeration are taken from the `code` field of the
/// `KeyboardEvent` type specified by the W3C.
///
/// https://www.w3.org/TR/uievents-code/
///
/// You can refer to their specification for more information.
pub const Key = enum {
    backquote,
    backslash,
    bracket_left,
    bracket_right,
    comma,
    digit0,
    digit1,
    digit2,
    digit3,
    digit4,
    digit5,
    digit6,
    digit7,
    digit8,
    digit9,
    equal,
    intl_backslash,
    intl_ro,
    intl_yen,
    key_a,
    key_b,
    key_c,
    key_d,
    key_e,
    key_f,
    key_g,
    key_h,
    key_i,
    key_j,
    key_k,
    key_l,
    key_m,
    key_n,
    key_o,
    key_p,
    key_q,
    key_r,
    key_s,
    key_t,
    key_u,
    key_v,
    key_w,
    key_x,
    key_y,
    key_z,
    minus,
    period,
    quote,
    semicolon,
    slash,
    alt_left,
    alt_right,
    backspace,
    caps_lock,
    context_menu,
    control_left,
    control_right,
    enter,
    meta_left,
    meta_right,
    shift_left,
    shift_right,
    space,
    tab,
    convert,
    kana_mode,
    lang1,
    lang2,
    lang3,
    lang4,
    lang5,
    non_convert,
    delete,
    end,
    help,
    home,
    insert,
    page_down,
    page_up,
    arrow_down,
    arrow_left,
    arrow_right,
    arrow_up,
    num_lock,
    numpad0,
    numpad1,
    numpad2,
    numpad3,
    numpad4,
    numpad5,
    numpad6,
    numpad7,
    numpad8,
    numpad9,
    numpad_add,
    numpad_backspace,
    numpad_clear,
    numpad_clear_entry,
    numpad_comma,
    numpad_decimal,
    numpad_divide,
    numpad_enter,
    numpad_equal,
    numpad_hash,
    numpad_memory_add,
    numpad_memory_clear,
    numpad_memory_recall,
    numpad_memory_store,
    numpad_memory_subtract,
    numpad_multiply,
    numpad_paren_left,
    numpad_paren_right,
    numpad_star,
    numpad_subtract,
    escape,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    f25,
    f26,
    f27,
    f28,
    f29,
    f30,
    f31,
    f32,
    @"fn",
    fn_lock,
    print_screen,
    scroll_lock,
    pause,
    browser_back,
    browser_favorites,
    browser_forward,
    browser_home,
    browser_refresh,
    browser_search,
    browser_stop,
    eject,
    launch_app1,
    launch_app2,
    launch_mail,
    media_play_pause,
    media_select,
    media_stop,
    media_track_next,
    media_track_previous,
    power,
    sleep,
    audio_volume_down,
    audio_volume_mute,
    audio_volume_up,
    wake_up,
    hyper,
    super,
    turbo,
    abort,
    @"resume",
    @"suspend",
    again,
    copy,
    cut,
    find,
    open,
    paste,
    props,
    select,
    undo,
    hiragana,
    katakana,

    /// The key could not be identified to any tag of the `Key` enum.
    ///
    /// Consider using the `scan_code` field of the `Event.Keyboard` to represent this key.
    /// Alternatively, you can submit an issue at:
    ///
    ///     https://github.com/nils-mathieu/zig_window
    unidentified,
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
    pub inline fn allocator(self: *EventLoop) std.mem.Allocator {
        return platform.interface.event_loop.allocator(self);
    }

    /// Request the event loop to exit.
    ///
    /// # Remarks
    ///
    /// This function will not cause the event loop to exit *instantly*. Instead, it is still
    /// possible for events to be received.
    pub inline fn exit(self: *EventLoop) void {
        return platform.interface.event_loop.exit(self);
    }

    /// Wakes the event loop thread.
    ///
    /// If the message loop is currently waiting for more messages to become available, then
    /// calling this function will wake it up, causing the `.about_to_wait` event to be
    /// invoked again.
    ///
    /// # Thread Safety
    ///
    /// Unlike most methods of `EventLoop`, this method is thread safe. It might be called
    /// from any thread to wake up the main message loop.
    pub inline fn wakeUp(self: *EventLoop) void {
        return platform.interface.event_loop.wakeUp(self);
    }
};

/// Represents an open window.
pub const Window = struct {
    /// The platform-specific object backing this `Window`.
    ///
    /// You can access this field if you need to access any of the underlying object's state,
    /// but make sure to gate this access behind the appropriate compile-time checks.
    platform_specific: platform.interface.Window,

    /// Represents the configuration of a window.
    ///
    /// An instance of this type is passed to the `Window.create()` function in order to
    /// dictate how to create the window.
    ///
    /// This includes things like appearance, behavior, and other platform-specific window-related
    /// flags.
    pub const Config = struct {
        /// The initial size of the window's surface.
        ///
        /// The "surface" of a window corresponds to the window's drawable area, excluding eventual
        /// platform-specific decorations such as the title bar or the border.
        ///
        /// When not present, a default, platform-specific size is used instead.
        ///
        /// This size can be either logical or physical, meaning that you can choose when you
        /// want your value to take the window's scale factor into account when computing the
        /// size.
        ///
        /// # Modifying the value
        ///
        /// Once the window has been created, you can modify the window's size using the
        /// `Window.requestSurfaceSize()` method.
        ///
        /// # Platform-specifics
        ///
        /// If the provided size is not supported, the closest supported size is used instead.
        surface_size: ?Size = null,

        /// The minimum size of the window's surface.
        ///
        /// The "surface" of a window corresponds to the window's drawable area, excluding eventual
        /// platform-specific decorations such as the title bar or the border.
        ///
        /// # Modifying the value
        ///
        /// Once the window has been created, you can modify the window's minimum size using the
        /// `Window.setMinSurfaceSize()` method.
        ///
        /// # Platform-specifics
        ///
        /// If the provided size is not supported, the closest supported size is used instead.
        min_surface_size: Size = .zero,

        /// The maximum size of the window's surface.
        ///
        /// The "surface" of a window corresponds to the window's drawable area, excluding eventual
        /// platform-specific decorations such as the title bar or the border.
        ///
        /// # Modifying the value
        ///
        /// Once the window has been created, you can modify the window's maximum size using the
        /// `Window.setMaxSurfaceSize()` method.
        ///
        /// # Platform-specifics
        ///
        /// If the provided size is not supported, the closest supported size is used instead.
        max_surface_size: Size = .max,

        /// The initial "outer" position of the window.
        ///
        /// The outer position corresponds to the window's position, *including* the window's
        /// platform-specific decorations like the title bar and border
        ///
        /// # Modifying the value
        ///
        /// Once the window has been created, you can modify the window's position using the
        /// `Window.setPosition()` method..
        position: ?Position = null,

        /// Whether the user should be able to manually resize the window (for example by resizing
        /// its borders).
        ///
        /// # Modifying the value
        ///
        /// Once the window has been created, you can modify whether users can resize the window
        /// using the `Window.setResizable()`.
        resizable: bool = true,

        /// Whether the window should have the platform's default decorations (like a title bar
        /// and a border).
        ///
        /// # Modifying the value
        ///
        /// Once the window has been created, you can modify whether the window has decorations
        /// using the `Window.setDecorations()` function.
        decorations: bool = true,

        /// The title of the window.
        ///
        /// This field must contain a valid UTF-8 string.
        ///
        /// # Modifying the value
        ///
        /// Once the window has been created, you can modify the title of the window using the
        /// `Window.setTitle()` method.
        title: []const u8 = "Zig Window",

        /// Whether the window should initially be maximized.
        ///
        /// # Modifying the value
        ///
        /// Once the window has been created, you can use the `Window.setMaximized()` function
        /// to update whether the window is maximized or not.
        maximized: bool = false,

        /// Whether the window should initially be minimized.
        ///
        /// # Modifying the value
        ///
        /// Once the window has been created, you can use the `Window.setMinimized()` function
        /// to update whether the window is minimized or not.
        minimized: bool = false,

        /// Whether the window should be initially visible.
        ///
        /// # Modifying the value
        ///
        /// Once the window has been created, you can modify whether the window is visible or not
        /// using the `Window.setVisible()`.
        visible: bool = true,

        /// The "level" of the window.
        ///
        /// This determines whether the window should always appear on top or behind other
        /// windows.
        ///
        /// # Modifying the value
        ///
        /// Once the window has been created, you can modify the window level by calling the
        /// `Window.setLevel()` method.
        level: Level = .normal,

        /// Whether the content of the window should be protected from things like screen sharing
        /// and similar mechanisms.
        ///
        /// # Modifying the value
        ///
        /// Once the window has been created, you can modify whether the window's content is
        /// protected using `Window.setContentProtected()`.
        content_protected: bool = false,

        /// Whether the window should support transparent (values with an alpha channel different
        /// from 1.0) rendering.
        ///
        /// When `false`, the alpha channel of anything rendered to the window will be ignored and
        /// the window will be assumed to be completely opaque.
        ///
        /// # Modiftying the value
        ///
        /// Once the window has been created, you can modify whethr the window supports transparent
        /// rendering using `Window.setTransparent()`.
        ///
        /// # Notes
        ///
        /// Disabled transparent rendering allows the window manager and operating system to be
        /// able to assume anything under the window is not visible, and therefore does not need
        /// to be rendered.
        ///
        /// This allows some optimizations for things like video players which can skip decoding
        /// the video entirely if they know not to be in view.
        transparent: bool = false,

        /// Whether the window should take the focus automatically when it is opened.
        auto_focus: bool = true,

        /// The level of a window.
        pub const Level = enum {
            /// The window should always appear behind other windows.
            always_on_bottom,
            /// The window should behave normally.
            normal,
            /// The window should always appear on top of other windows.
            always_on_top,
        };
    };

    /// Creates a new window on the provided event loop.
    ///
    /// # Valid Usage
    ///
    /// The created window must outlive the event loop.
    pub inline fn create(el: *EventLoop, config: Config) Error!*Window {
        return platform.interface.window.create(el, config);
    }

    /// Closes the window and releases any resources that it owns.
    ///
    /// # Valid Usage
    ///
    /// After this function has returned, the window must no longer be used.
    pub inline fn destroy(self: *Window) void {
        return platform.interface.window.destroy(self);
    }

    // =============================================================================================
    // GETTERS
    // =============================================================================================

    /// Returns the rectangle of the window's surface area.
    ///
    /// The surface area of a window is the part that can be drawn to, excluding things like the
    /// title bar and other OS-specific decorations.
    pub inline fn surfaceRect(self: *Window) Rect {
        return platform.interface.window.surfaceRect(self);
    }

    /// Returns the current position of the window's surface area over the desktop.
    ///
    /// The surface area of a window is the part that can be drawn to, excluding things like the
    /// title bar and other OS-specific decorations.
    pub inline fn surfacePosition(self: *Window) Position {
        return platform.interface.window.surfacePosition(self);
    }

    /// Returns the size of the window's surface area.
    ///
    /// The surface area of a window is the part that can be drawn to, excluding things like the
    /// title bar and other OS-specific decorations.
    pub inline fn surfaceSize(self: *Window) Size {
        return platform.interface.window.surfaceSize(self);
    }

    /// Returns a rectangle over the window's outer area.
    ///
    /// The outer area corresponds to the complete size of the window, including OS-specific
    /// decorations like the title bar.
    pub inline fn outerRect(self: *Window) Rect {
        return platform.interface.window.outerRect(self);
    }

    /// Returns the "outer" size of the window.
    ///
    /// The outer size corresponds to the complete area of the window, including OS-specific
    /// decorations like the title bar.
    pub inline fn outerSize(self: *Window) Size {
        return platform.interface.window.outerSize(self);
    }

    /// Returns the outer position of the window.
    ///
    /// The outer size corresponds to the complete area of the window, including OS-specific
    /// decorations like the title bar.
    pub inline fn outerPosition(self: *Window) Position {
        return platform.interface.window.outerPosition(self);
    }

    /// Returns whether the window is visible or not.
    pub inline fn isVisible(self: *Window) bool {
        return platform.interface.window.isVisible(self);
    }

    /// Returns whether the window has focus or not.
    pub inline fn isFocused(self: *Window) bool {
        return platform.interface.window.isFocused(self);
    }

    // =============================================================================================
    // OTHER
    // =============================================================================================

    /// Notifies the window manager that presentation to the window is about to happen.
    ///
    /// This function should be called right before presenting a rendered frame to the window,
    /// for example with `glSwapBuffers()` on OpenGL-based systems, or with `vkQueuePresentKHR()`
    /// on Vulkan-based systems.
    pub inline fn presentNotify(self: *Window) void {
        return platform.interface.window.presentNotify(self);
    }

    /// Requests the window to be redrawn.
    pub inline fn requestRedraw(self: *Window) void {
        return platform.interface.window.requestRedraw(self);
    }

    // =============================================================================================
    // SETTERS
    // =============================================================================================

    /// Requests the provided new size for the surface.
    ///
    /// On platforms that allow the size of the window to change, this may either take effect
    /// instantly, or when the request is served by the display server (depending on the
    /// underlying platform).
    ///
    /// On platforms that do not allow the size of the window to change (most mobile platforms),
    /// this function does nothing.
    pub inline fn requestSurfaceSize(self: *Window, new_size: Size) void {
        return platform.interface.window.requestSurfaceSize(self, new_size);
    }

    /// Sets the minimum surface size of the window.
    ///
    /// On platforms that do not support changing the size of the window, this function
    /// does nothing.
    pub inline fn setMinSurfaceSize(self: *Window, new_min_size: Size) void {
        return platform.interface.window.setMinSurfaceSize(self, new_min_size);
    }

    /// Sets the maximum surface size of the window.
    ///
    /// On paltforms that do not support changing the size of the window, this function
    /// does nothing.
    pub inline fn setMaxSurfaceSize(self: *Window, new_max_size: Size) void {
        return platform.interface.window.setMaxSurfaceSize(self, new_max_size);
    }

    /// Shows the window.
    ///
    /// # Parameters
    ///
    /// - `take_focus`: Whether the window should take the keyboard focus when it is shown.
    pub inline fn show(self: *Window, take_focus: bool) void {
        return platform.interface.window.show(self, take_focus);
    }

    /// Hides the window.
    pub inline fn hide(self: *Window) void {
        return platform.interface.window.hide(self);
    }

    /// Sets whether the cursor should be visible or not.
    ///
    /// Note that this only takes effect while the cursor is hovering the window.
    ///
    /// # Parameters
    ///
    /// - `visible`: Whether the cursor should be visible or not.
    pub inline fn setCursorVisible(self: *Window, visible: bool) void {
        return platform.interface.window.setCursorVisible(self, visible);
    }

    /// Shows the cursor.
    ///
    /// Note that this only takes effect while the cursor is hovering the window.
    pub inline fn showCursor(self: *Window) void {
        return platform.interface.window.showCursor(self);
    }

    /// Hides the cursor.
    ///
    /// Note that this only takes effect while the cursor is hovering the window.
    pub inline fn hideCursor(self: *Window) void {
        return platform.interface.window.hideCursor(self);
    }

    /// Sets whether the cursor should be confined to the window's surface area.
    ///
    /// The surface area of a window corresponds to the drawable area of the window, not including
    /// its eventual title bar and other OS-specific decorations.
    ///
    /// Note that this only takes effect while the window has focus.
    ///
    /// # Parameters
    ///
    /// - `locked`: Whether the cursor should be locked or not.
    pub inline fn setCursorConfined(self: *Window, locked: bool) void {
        return platform.interface.window.setCursorConfined(self, locked);
    }

    /// Prevents the cursor from leaving the window's surface area.
    ///
    /// The surface area of a window corresponds to the drawable area of the window, not including
    /// its eventual title bar and other OS-specific decorations.
    ///
    /// Note that this only takes effect while the window has focus.
    pub inline fn confineCursor(self: *Window, locked: bool) void {
        return platform.interface.window.confineCursor(self, locked);
    }

    /// Releases the cursor and allows it to move freely within the window's surface area.
    pub inline fn releaseCursor(self: *Window) void {
        return platform.interface.window.releaseCursor(self);
    }
};

/// A size.
///
/// The components of this struct are measured in *physical pixels*, meaning that they do not
/// take DPI scaling into account and measure an exact amount of pixels on the screen.
pub const Size = struct {
    /// The width.
    width: u32,
    /// The height.
    height: u32,

    /// A size of zero.
    pub const zero = Size{ .width = 0, .height = 0 };

    /// A size of the maximum size.
    pub const max = Size{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) };

    /// Clamps te component of the size between `lower` and `upper`.
    pub fn clamp(self: Size, lower: Size, upper: Size) Size {
        return Size{
            .width = std.math.clamp(self.width, lower.width, upper.width),
            .height = std.math.clamp(self.height, lower.height, upper.height),
        };
    }
};

/// A position.
///
/// The components in this struct are measured in *physical pixels*, meaning that they do not
/// take DPI scaling into account and measure an exact amount of pixels on the screen.
pub const Position = struct {
    /// The horizontal component.
    x: i32,
    /// The vertical component.
    y: i32,

    /// The origin.
    pub const origin = Position{ .x = 0, .y = 0 };

    /// A likely invalid position.
    pub const invalid = Position{ .x = std.math.minInt(i32), .y = std.math.minInt(i32) };
};

/// Represents a rectangle.
///
/// The components in this struct are measured in *physical pixels*, meaning that they do not
/// take DPI scaling into account and measure an exact amount of pixels on the screen.
pub const Rect = struct {
    /// The X position of the top-left corner of the rectangle.
    x: i32,
    /// The Y position of the top-left corner of the rectangle.
    y: i32,
    /// The width of the rectangle.
    width: u32,
    /// The height of the rectangle.
    height: u32,

    /// Returns the size of the rectangle.
    pub inline fn size(self: Rect) Size {
        return Size{ .width = self.width, .height = self.height };
    }

    /// Returns the position of the rectangle's top-left corner.
    pub inline fn position(self: Rect) Position {
        return Position{ .x = self.x, .y = self.y };
    }
};
