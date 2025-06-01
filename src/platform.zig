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

pub const interface = @field(@This(), build_options.current_platform).interface;
