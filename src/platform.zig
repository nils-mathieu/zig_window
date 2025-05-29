//! Exposes:
//!
//! 1. The individual module defining the platform-specific implementations of the `zig_window`
//!    library.
//!
//! 2. The `interface` module, which provides the consistent part of the interface and is available
//!    on all platforms.

const builtin = @import("builtin");

pub const win32 = @import("platform/win32.zig");

pub const interface = switch (builtin.os.tag) {
    .windows => win32.interface,
    else => {
        const err =
            \\The current platform "{}" is not supported by the `zig_window` library.
            \\
            \\Consider filing an issue at:
            \\    https://github.com/nils-mathieu/zig_window
            \\
            \\Alternatively, you can compile the library with the `.{ .use_dummy_platform = true }`
            \\and you will be provided with a working event loop but no windowing-related features.
            \\
        ;
        @compileError(err);
    },
};
