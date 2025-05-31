//! This examples shows how to create a simple window and receive the events that are sent
//! to it.

const zw = @import("zig_window");
const std = @import("std");

const App = struct {
    window: *zw.Window,
};

fn onEvent(app: *App, event_loop: *zw.EventLoop, event: zw.Event) void {
    switch (event) {
        .started => {
            const window = zw.Window.create(event_loop, .{
                .title = "test",
            }) catch err();
            app.* = App{ .window = window };
        },
        .stopped => {
            app.window.destroy();
        },
        .close_requested => {
            event_loop.exit();
        },
        else => {},
    }
}

pub fn main() zw.Error!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app: App = undefined;

    try zw.run(.{
        .allocator = gpa.allocator(),
        .user_app = .init(App, &app, onEvent),
    });
}

fn err() noreturn {
    std.debug.panic("failed to initialize the application", .{});
}
