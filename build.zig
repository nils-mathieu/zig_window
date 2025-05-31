const std = @import("std");

//
// The following top-level build steps are available:
//
// - `check` - is mostly used by LSPs to force the Zig code analyser to go through as much as the
//   codebase as possible.
//
// - `examples` - will install the binary executable for all available examples in the the
//   `zig-out/examples` directory.
//

/// The list of all examples available for use.
///
/// Examples are:
///
/// - Available for users when they use the `zig build example_{name}` command.
///
/// - Used by LSPs to make sure the project compiles (through the `check` step).
///
/// When new examples are added, the name of the source file must be added here (without the
/// `.zig` extension).
const example_names: []const []const u8 = &.{
    "simple_window",
    "keyboard_events",
};

pub fn build(b: *std.Build) void {
    // =============================================================================================
    // = Build options                                                                             =
    // =============================================================================================
    const target = b.standardTargetOptions(.{});

    // =============================================================================================
    // = Global steps                                                                              =
    // =============================================================================================
    const check_step = b.step("check", "Used by LSPs to cover the codebase");
    const examples_step = b.step("examples", "Installs examples in the `zig-out` directory");

    // =============================================================================================
    // = Main `zig_window` module                                                                  =
    // =============================================================================================
    const zig_window_module = b.addModule("zig_window", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    zig_window_module.addImport("zig_window", zig_window_module);

    switch (target.result.os.tag) {
        .windows => {
            if (b.lazyDependency("zigwin32", .{})) |zigwin32| {
                zig_window_module.addImport("win32", zigwin32.module("win32"));
            }
        },
        else => {},
    }

    // =============================================================================================
    // = Examples                                                                                  =
    // =============================================================================================
    // The following code simply creates a step named `example_{name}` for every
    // example listed in the `example_names` above.
    //
    for (example_names) |name| {
        // Add a step that builds the example's
        const module_root_path = b.fmt("examples/{s}.zig", .{name});
        const example_exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(module_root_path),
                .optimize = .Debug,
                .target = target,
            }),
        });

        // The `zig_window` module must be available in all examples.
        example_exe.root_module.addImport("zig_window", zig_window_module);

        // Add building the example's executable to the check step.
        check_step.dependOn(&example_exe.step);

        // Add a step to run the example.
        const run_step_name = b.fmt("example_{s}", .{name});
        const run_step_desc = b.fmt("Run the `{s}` example", .{name});
        const run_example = b.addRunArtifact(example_exe);
        b.step(run_step_name, run_step_desc).dependOn(&run_example.step);

        // Add the example to the list of artifacts to installs.
        const install_example = b.addInstallArtifact(example_exe, .{ .dest_dir = .{ .override = .{ .custom = "examples" } } });
        examples_step.dependOn(&install_example.step);
    }
}
