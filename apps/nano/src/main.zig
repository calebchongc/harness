//! harness-nano: Harness's desktop app on nanoui. A window of its own,
//! drawn in Zig, over the same engine the GPUI app runs: the daemon (or
//! `harness headless`) on `HARNESS_IPC_PORT`. Nothing here holds workspace
//! state; the engine does, so both apps can be open on one engine at once.
const std = @import("std");
const nanoui = @import("nanoui");
const App = @import("app.zig").App;
const Engine = @import("engine.zig").Engine;
const theme = @import("theme.zig");

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Harness" });
    defer app.destroy();
    var a: App = .init(init.gpa, init.io, Engine.portFrom(init.environ_map));
    defer a.deinit();
    if (init.environ_map.get("HARNESS_NANO_HARNESS")) |h| a.new_chat_harness = h;
    a.window = try app.newWindow(.{
        .title = "Harness",
        .width = 1200,
        .height = 780,
        .min_width = 760,
        .min_height = 480,
        .title_bar = .hidden,
        .theme = theme.ui(nanoui.isDark()),
        .content = .{ .view = .init(&a, @import("view.zig").view) },
    });
    try a.start();
    a.release.done = .{ .ctx = &a, .func = App.releaseCame };
    a.release.start();
    try app.run();
}
