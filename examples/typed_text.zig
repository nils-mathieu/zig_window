//! This examples creates a window, and dumps all text input related events.

const zw = @import("zig_window");
const std = @import("std");

const App = struct {
    window: *zw.Window,
};

fn onEvent(app: *App, event_loop: *zw.EventLoop, event: zw.Event) void {
    switch (event) {
        .started => {
            const window = zw.Window.create(event_loop, .{}) catch @panic("error");
            app.* = App{ .window = window };
        },
        .stopped => app.window.destroy(),
        .close_requested => event_loop.exit(),
        .text_typed => |ev| {
            switch (ev.ime) {
                .enabled => std.debug.print("IME enabled\n", .{}),
                .disabled => std.debug.print("IME disabled\n", .{}),
                .commit => |text| std.debug.print("'{s}'\n", .{text}),
                .preedit => |preedit| std.debug.print("preedit: '{s}' ({}..{})\n", .{ preedit.text, preedit.cursor_start, preedit.cursor_end }),
            }
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
