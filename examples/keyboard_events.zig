//! This examples creates a window, and dumps all keyboard events to the console.

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
        .keyboard => |ev| {
            std.debug.print(
                "0x{:0>16} {s:<8} {x:0>4} {s:<16} {s:<8} {s:<8}\n",
                .{
                    @intFromPtr(ev.device),
                    @tagName(ev.state),
                    ev.scan_code,
                    @tagName(ev.key),
                    ev.characters,
                    ev.characters_without_modifiers,
                },
            );
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
