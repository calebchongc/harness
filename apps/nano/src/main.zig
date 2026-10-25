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
    theme.registerFonts();
    const app = try nanoui.App.create(init, .{ .name = "Harness" });
    defer app.destroy();
    var a: App = .init(init.gpa, init.io, Engine.portFrom(init.environ_map));
    defer a.deinit();
    a.new_harness = try init.gpa.dupe(u8, init.environ_map.get("HARNESS_NANO_HARNESS") orelse "graff");
    a.settings = .open(init.gpa, init.io, init.environ_map);
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
    // A chat to open at launch, for checks that render the window offscreen.
    if (init.environ_map.get("HARNESS_NANO_OPEN_CHAT")) |id| a.openChat(id, null);
    // Panels to open with it: "diffs", "files", or both.
    if (init.environ_map.get("HARNESS_NANO_PANELS")) |list| {
        a.panels.files_open = std.mem.indexOf(u8, list, "files") != null;
        if (std.mem.indexOf(u8, list, "diffs") != null) a.panels.tabs.append(a.gpa, .{ .kind = .diffs }) catch {};
        a.panels.host_open = a.panels.tabs.items.len > 0;
    }
    a.release.done = .{ .ctx = &a, .func = App.releaseCame };
    a.release.start();
    try app.run();
}
