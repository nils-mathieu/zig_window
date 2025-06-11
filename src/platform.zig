//! Exposes:
//!
//! 1. The individual module defining the platform-specific implementations of the `zig_window`
//!    library.
//!
//! 2. The `interface` module, which provides the consistent part of the interface and is available
//!    on all platforms.

const builtin = @import("builtin");
const build_options = @import("build_options");

pub const win32 = @import("platform/win32.zig");
pub const x11 = @import("platform/x11.zig");

/// An enumeration of the supported platforms implementations available.
pub const Platform = enum {
    /// The Win32 API implementation.
    win32,
    /// The X11 server implementation.
    x11,

    /// The current platform that has been selected in the build script.
    pub const current = @field(@This(), build_options.current_platform);
};

/// The interface module for the current platform.
///
/// This interface module is expected to always declare the same set of functions
/// and types regardless of the platform.
pub const interface = switch (Platform.current) {
    .win32 => win32.interface,
    .x11 => x11.interface,
};
