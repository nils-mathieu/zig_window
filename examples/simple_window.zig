//! This examples shows how to create a simple window and receive the events that are sent
//! to it.
//!
//! This includes:
//!
//! 1. Creating an application with `App.init()`.
//!
//! 2. Running the application to completion using `App.run()`.

const zw = @import("zig_window");
const std = @import("std");

const App = struct {};

fn onEvent(app: *App, event_loop: *zw.EventLoop, event: zw.Event) void {
    _ = app;
    _ = event_loop;

    switch (event) {
        else => {},
    }
}

pub fn main() zw.Error!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var app = App{};

    try zw.run(.{
        .allocator = gpa.allocator(),
        .user_app = .init(App, &app, onEvent),
    });
}
