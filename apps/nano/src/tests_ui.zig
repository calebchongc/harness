//! The window driven as a person would, headlessly (nanoui's Tester), on
//! made-up chats and no engine: the GPUI app's split-pane shortcuts.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;

const testing = std.testing;

const chats =
    \\[{"id":"a","deviceId":"d","title":"Alpha","archived":false,"lastMessageAt":"2026-10-03T00:00:00Z"},
    \\ {"id":"b","deviceId":"d","title":"Beta","archived":false,"lastMessageAt":"2026-10-02T00:00:00Z"}]
;

const Harness = struct {
    a: App,
    t: ui.Tester,

    fn init(h: *Harness) !void {
        @import("theme.zig").registerFonts();
        h.a = .init(testing.allocator, testing.io, 1);
        h.a.dark = true;
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, chats, .{});
        defer parsed.deinit();
        try h.a.chats.replace(parsed.value);
        h.a.openChat("a", null);
        try h.t.init(testing.allocator, .init(&h.a, @import("view.zig").view), .{ .width = 1200, .height = 780, .dark = true });
        h.t.settle(1);
    }

    fn deinit(h: *Harness) void {
        h.t.deinit();
        h.a.deinit();
    }

    fn showTab(h: *Harness, i: usize) void {
        h.a.showTab(i);
        h.t.settle(1);
    }

    fn press(h: *Harness, s: ui.Shortcut) void {
        _ = h.t.shortcut(s);
        h.t.settle(1);
    }

    /// `NANO_SNAP_DIR=dir zig build test` saves what the test saw.
    fn snap(h: *Harness, name: []const u8) void {
        const dir = std.c.getenv("NANO_SNAP_DIR") orelse return;
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), name }) catch return;
        h.t.screenshot(path) catch {};
    }
};

test "⌘D splits the chat to the right, the new pane a new chat with focus; ⌘[ goes back; ⌘W closes the pane" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true });
    const s = h.a.tabs.layout().?;
    try testing.expectEqual(@as(usize, 2), s.panes.items.len);
    try testing.expectEqual(@as(f32, 0.5), s.shares.items[0]);
    try testing.expect(h.a.selected == null);
    // Alpha's pane, read only, says what it has.
    try testing.expect(h.t.hasText("Nothing here yet."));
    h.snap("split-right");
    h.press(.{ .key = '[', .cmd = true });
    try testing.expectEqualStrings("a", h.a.selected.?);
    h.press(.{ .key = ']', .cmd = true });
    try testing.expect(h.a.selected == null);
    h.press(.{ .key = 'w', .cmd = true });
    try testing.expect(h.a.tabs.layout() == null);
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqual(@as(usize, 1), h.a.tabs.items.items.len);
}

test "⌘⇧D splits down; ⌥⌘↑ focuses the pane above; ⌘⇧↩ zooms the focused pane" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true, .shift = true });
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
    try testing.expect(h.a.tabs.layout().?.axis == .vertical);
    // Across the split's axis: nothing.
    h.press(.{ .key = 'd', .cmd = true });
    try testing.expectEqual(@as(usize, 2), h.a.tabs.layout().?.panes.items.len);
    h.snap("split-down");
    h.press(.{ .key = ui.Shortcut.up, .cmd = true, .alt = true });
    try testing.expectEqualStrings("a", h.a.selected.?);
    h.press(.{ .key = ui.Shortcut.enter, .cmd = true, .shift = true });
    try testing.expect(h.a.tabs.layout().?.zoomed);
    try testing.expect(!h.t.hasText("Empty pane"));
    h.press(.{ .key = ui.Shortcut.enter, .cmd = true, .shift = true });
    try testing.expect(h.t.hasText("Empty pane"));
}

test "clicking the other pane focuses it" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.press(.{ .key = 'd', .cmd = true });
    try h.t.clickText("Nothing here yet.");
    h.t.settle(1);
    try testing.expectEqualStrings("a", h.a.selected.?);
    try testing.expectEqual(@as(usize, 0), h.a.tabs.layout().?.focus);
}

test "a new pane starts with an empty prompt; each pane and tab keeps its own" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    // A new chat with a prompt typed, split: the new pane's is empty, on
    // the same agent; going back finds the prompt as it was left.
    h.press(.{ .key = 't', .cmd = true });
    h.a.composer.set("hey there");
    const harness = try testing.allocator.dupe(u8, h.a.new_harness);
    defer testing.allocator.free(harness);
    h.press(.{ .key = 'd', .cmd = true });
    try testing.expectEqualStrings("", h.a.composer.text());
    try testing.expectEqualStrings(harness, h.a.new_harness);
    h.a.composer.set("the right pane's");
    h.press(.{ .key = '[', .cmd = true });
    try testing.expectEqualStrings("hey there", h.a.composer.text());
    h.press(.{ .key = ']', .cmd = true });
    try testing.expectEqualStrings("the right pane's", h.a.composer.text());
    // ⌘W: the left pane's prompt comes back with it.
    h.press(.{ .key = 'w', .cmd = true });
    try testing.expectEqualStrings("hey there", h.a.composer.text());
    // Alpha's own tab, with its own prompt; the new chat's tab keeps its.
    h.showTab(0);
    try testing.expectEqualStrings("", h.a.composer.text());
    h.a.composer.set("about alpha");
    h.showTab(1);
    try testing.expectEqualStrings("hey there", h.a.composer.text());
    h.showTab(0);
    try testing.expectEqualStrings("about alpha", h.a.composer.text());
}

test "in a narrow pane the starter chips wrap inside it, each with its icon's room" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.resize(1100, 760);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"s","deviceId":"d","path":"/work/fieldnotes"}]
    , .{});
    defer parsed.deinit();
    try h.a.spaces.replace(parsed.value);
    h.a.select(null, "s");
    for (0..3) |_| h.press(.{ .key = 'd', .cmd = true });
    h.snap("narrow-chips");
    const titles = [_][]const u8{ "Build something new", "Research a topic", "Plan a launch", "Tour this project" };
    const pane_left = 1100 - h.a.tabs.layout().?.shares.items[3] * @import("view_transcript.zig").mainWidth(&h.t.ctx, &h.a);
    for (titles) |title| {
        const r = h.t.findText(title) orelse return error.ChipMissing;
        // 10 points of padding, the 13-point icon and 6 between, inside the pane.
        try testing.expect(r.x - 29 >= pane_left);
        try testing.expect(r.x + r.w + 10 <= 1100);
    }
}

/// Types `s` as AppKit's input system hands it over: an insert per key,
/// a frame each.
fn typeKeys(h: *Harness, s: []const u8) void {
    for (0..s.len) |i| h.t.textOps(&.{.{ .insert = s[i .. i + 1] }});
    h.t.settle(1);
}

test "the composer has the keys after ⌘D, ⌘[ and ⌘]: nothing typed is lost" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.press(.{ .key = 't', .cmd = true });
    typeKeys(&h, "hey there");
    try testing.expectEqualStrings("hey there", h.a.composer.text());
    h.press(.{ .key = 'd', .cmd = true });
    typeKeys(&h, "right");
    try testing.expectEqualStrings("right", h.a.composer.text());
    h.press(.{ .key = '[', .cmd = true });
    // Back where it was left, the caret at its end.
    typeKeys(&h, "!");
    try testing.expectEqualStrings("hey there!", h.a.composer.text());
    h.press(.{ .key = ']', .cmd = true });
    typeKeys(&h, "s");
    try testing.expectEqualStrings("rights", h.a.composer.text());
    h.showTab(0);
    typeKeys(&h, "on alpha");
    try testing.expectEqualStrings("on alpha", h.a.composer.text());
}

test "a second line makes the docked composer taller and keeps the keys" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.view.focus_composer = true;
    h.t.settle(1);
    typeKeys(&h, "one");
    h.t.textOps(&.{.{ .command = .insert_line_break }});
    h.t.settle(1);
    typeKeys(&h, "two");
    try testing.expectEqualStrings("one\ntwo", h.a.composer.text());
}

test "Settings › Shortcuts: a chip takes the next keys; a clash is refused, as the GPUI app says" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const shortcuts = @import("shortcuts.zig");
    @import("view_settings.zig").open(&h.a);
    h.a.settings.section = .shortcuts;
    h.t.settle(1);
    try testing.expect(h.t.hasText("Keyboard shortcuts"));
    try h.t.clickText("Cmd+S");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Press keys…"));
    // While it records, ⌘B is the chip's, not the sidebar's.
    h.press(.{ .key = 'b', .cmd = true, .alt = true });
    try testing.expectEqualStrings("mod-alt-b", h.a.settings.combo(shortcuts.all[0]));
    try testing.expect(h.t.hasText("Cmd+Opt+B"));
    try testing.expect(h.t.hasText("Reset"));
    try h.t.clickText("Cmd+Shift+R");
    h.t.settle(1);
    h.press(.{ .key = 'b', .cmd = true, .alt = true });
    try testing.expectEqualStrings("mod-shift-r", h.a.settings.combo(shortcuts.all[1]));
    try testing.expect(h.t.hasText("Cmd+Opt+B is already assigned to Save file."));
    try h.t.clickText("Restore defaults");
    h.t.settle(1);
    try testing.expectEqualStrings("mod-s", h.a.settings.combo(shortcuts.all[0]));
}

test "with ⌘ Enter chosen, Enter starts a new line and ⌘↩ sends" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.settings.setText("composerSendBehavior", "mod-enter");
    h.a.view.focus_composer = true;
    h.t.settle(1);
    typeKeys(&h, "one");
    h.t.key(.enter);
    h.t.settle(1);
    typeKeys(&h, "two");
    try testing.expectEqualStrings("one\ntwo", h.a.composer.text());
}

test "Settings › Appearance: Light switches the window, an accent recolours it, the width slider moves the column" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const look = @import("view_settings_appearance.zig");
    @import("view_settings.zig").open(&h.a);
    h.a.settings.section = .appearance;
    h.t.settle(1);
    try h.t.clickText("Light");
    h.t.settle(1);
    try testing.expectEqual(@as(?bool, false), h.a.dark);
    try testing.expectEqual(look.Mode.light, look.mode(&h.a));
    h.a.settings.setAccent("green");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Green · Controls, glyphs, selections, code, and activity."));
    try testing.expectEqual(@as(u24, 0x15803d), look.presetNamed("green").?.light);
    h.a.settings.setNumber("transcriptWidth", 1008);
    h.t.settle(1);
    try testing.expectEqual(@as(f32, 1008), @import("view_transcript.zig").column_w);
}

test "a session dragged from the sidebar onto the right target opens in a new pane to the right" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const beta = h.t.findText("Beta") orelse return error.NoRow;
    // Press on Beta's row, drag over the chat's right edge: the targets show.
    h.t.moveTo(beta.x + 4, beta.y + 4);
    h.t.ctx.pointerDown();
    h.t.frame();
    h.t.ctx.input.mouse = .{ .x = 900, .y = 300 };
    h.t.frame();
    h.t.ctx.input.mouse = .{ .x = 1100, .y = 400 };
    h.t.frame();
    try testing.expect(h.t.hasText("Open to the right ◨"));
    try testing.expect(h.t.hasText("Open below ⬓"));
    h.snap("drag-to-split");
    h.t.ctx.pointerUp();
    h.t.frame();
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Open to the right ◨"));
    const s = h.a.tabs.layout() orelse return error.NoSplit;
    try testing.expectEqual(tabs_axis.horizontal, s.axis);
    try testing.expectEqualStrings("b", h.a.selected.?);
    try testing.expectEqualStrings("a", s.panes.items[0].?);
}

test "a drag released off the targets does nothing, and isn't a click" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const beta = h.t.findText("Beta") orelse return error.NoRow;
    h.t.moveTo(beta.x + 4, beta.y + 4);
    h.t.ctx.pointerDown();
    h.t.frame();
    h.t.ctx.input.mouse = .{ .x = beta.x + 40, .y = beta.y + 4 };
    h.t.frame();
    h.t.ctx.input.mouse = .{ .x = beta.x + 4, .y = beta.y + 4 };
    h.t.frame();
    h.t.ctx.pointerUp();
    h.t.frame();
    h.t.settle(1);
    try testing.expect(h.a.tabs.layout() == null);
    try testing.expectEqualStrings("a", h.a.selected.?);
}

const tabs_axis = @import("tabs.zig").Axis;

/// Presses on `from`, moves (past the drag threshold) to what `to` gives
/// once the drag has laid the sidebar out, and lets go.
fn dragRow(h: *Harness, from: []const u8, comptime to: fn (*Harness) ui.Point) !void {
    // The session row: below the Sessions or Pinned header, not the tab's.
    const r = sessionText(h, from) orelse return error.NoRow;
    h.t.moveTo(r.x + 4, r.y + 4);
    h.t.ctx.pointerDown();
    h.t.frame();
    h.t.ctx.input.mouse = .{ .x = r.x + 4, .y = r.y + 14 };
    h.t.frame();
    h.t.frame();
    h.t.ctx.input.mouse = to(h);
    h.t.frame();
    h.t.frame();
    h.snap(c_name(from));
    h.t.ctx.pointerUp();
    h.t.frame();
    h.t.settle(1);
}

fn c_name(from: []const u8) []const u8 {
    return if (std.mem.eql(u8, from, "Alpha")) "pin-drag-alpha" else "pin-drag-beta";
}

fn sessionText(h: *Harness, text: []const u8) ?ui.Rect {
    const head = h.a.view.pin_header orelse h.a.view.sessions_header orelse return null;
    const top = head.y;
    for (h.t.ctx.nodes.items) |n| switch (n.content) {
        .text => |t| if (std.mem.eql(u8, t.str, text) and n.rect.y > top) return n.rect,
        else => {},
    };
    return null;
}

fn pinnedHeader(h: *Harness) ui.Point {
    const r = h.a.view.pin_header.?;
    return .{ .x = r.x + 20, .y = r.y + r.h / 2 };
}

fn belowFirstPin(h: *Harness) ui.Point {
    const r = h.a.view.pin_rows.?;
    return .{ .x = r.x + 20, .y = r.y + 4 + 29 * 0.75 };
}

fn sessionsHeader(h: *Harness) ui.Point {
    const r = h.a.view.sessions_header.?;
    return .{ .x = r.x + 20, .y = r.y + r.h / 2 };
}

test "sessions dragged onto Pinned are pinned in place, and back to Sessions unpinned" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try testing.expect(!h.t.hasText("Pinned"));
    try dragRow(&h, "Beta", pinnedHeader);
    try testing.expectEqual(@as(usize, 1), h.a.settings.pins.items.len);
    try testing.expectEqualStrings("b", h.a.settings.pins.items[0]);
    try testing.expect(h.t.hasText("Pinned"));
    // Below the first pin's middle: after it.
    try dragRow(&h, "Alpha", belowFirstPin);
    try testing.expectEqual(@as(usize, 2), h.a.settings.pins.items.len);
    try testing.expectEqualStrings("a", h.a.settings.pins.items[1]);
    try dragRow(&h, "Beta", sessionsHeader);
    try testing.expectEqual(@as(usize, 1), h.a.settings.pins.items.len);
    try testing.expectEqualStrings("a", h.a.settings.pins.items[0]);
    // A drag that ends outside the sidebar leaves the pins be.
    try testing.expect(h.a.tabs.layout() == null);
}

/// Hovers a session row and clicks its ⋯ (`{row}-menu`).
fn openRowMenu(h: *Harness, title: []const u8) !void {
    const r = sessionText(h, title) orelse return error.NoRow;
    h.t.moveTo(r.x + 4, r.y + 4);
    h.t.frame();
    // The row's last icon, at its right end.
    var best: ?ui.Rect = null;
    for (h.t.ctx.nodes.items) |n| switch (n.content) {
        .image => if (n.rect.x < 256 and n.rect.y < r.y + r.h and n.rect.y + n.rect.h > r.y and
            (best == null or n.rect.x > best.?.x)) {
            best = n.rect;
        },
        else => {},
    };
    const b = best orelse return error.NoMenuButton;
    h.t.click(b.x + b.w / 2, b.y + b.h / 2);
    h.t.settle(1);
}

test "a session's ⋯ menu pins it after the last pin, and unpins it" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try openRowMenu(&h, "Beta");
    try testing.expect(h.t.hasText("Rename…"));
    try testing.expect(h.t.hasText("Delete…"));
    h.snap("chat-menu");
    try h.t.clickText("Pin");
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Rename…"));
    try testing.expectEqual(@as(usize, 1), h.a.settings.pins.items.len);
    try testing.expectEqualStrings("b", h.a.settings.pins.items[0]);
    try openRowMenu(&h, "Alpha");
    try h.t.clickText("Pin");
    h.t.settle(1);
    try testing.expectEqualStrings("a", h.a.settings.pins.items[1]);
    try openRowMenu(&h, "Beta");
    try h.t.clickText("Unpin");
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 1), h.a.settings.pins.items.len);
    try testing.expectEqualStrings("a", h.a.settings.pins.items[0]);
}

test "Copy › Harness conversation link copies the GPUI app's link; a press outside closes the menu" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.a.device_id = try testing.allocator.dupe(u8, "dev");
    try openRowMenu(&h, "Beta");
    try h.t.clickText("Copy");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Back"));
    try testing.expect(!h.t.hasText("Harness session ID"));
    h.snap("chat-menu-copy");
    try h.t.clickText("Harness conversation link");
    h.t.settle(1);
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(@import("view_chat_menu.zig").conversationLink(&buf, "b", "dev").?, h.t.clipboard.items);
    try testing.expectEqualStrings("Harness conversation link copied", h.a.noticeText().?);
    try openRowMenu(&h, "Beta");
    h.t.click(700, 400);
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Rename…"));
}

test "Rename… opens its dialog holding the title, Escape closes it; Delete… asks first" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try openRowMenu(&h, "Beta");
    try h.t.clickText("Rename…");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Rename session"));
    try testing.expectEqualStrings("Beta", h.a.view.dialogs.name.text());
    // Its field has the keys once the menu under it is gone.
    h.t.typeText(" two");
    h.t.settle(1);
    try testing.expectEqualStrings("Beta two", h.a.view.dialogs.name.text());
    h.snap("rename-dialog");
    h.press(.{ .key = ui.Shortcut.escape });
    try testing.expect(!h.t.hasText("Rename session"));
    try openRowMenu(&h, "Beta");
    try h.t.clickText("Delete…");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Delete session?"));
    try testing.expect(h.t.containsText("\u{201C}Beta\u{201D} will be permanently deleted."));
    h.snap("delete-dialog");
    try h.t.clickText("Cancel");
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Delete session?"));
    try testing.expect(h.a.findChat("b") != null);
}

/// A right-click, with a nanoui that has them; the test is skipped before.
fn rightClick(h: *Harness, x: f32, y: f32) !void {
    if (comptime !@hasDecl(ui.Tester, "secondaryClick")) return error.SkipZigTest;
    h.t.secondaryClick(x, y);
}

/// Projects on this device and on one away since September, with a
/// session in each of two.
fn withProjects(h: *Harness) !void {
    const spaces =
        \\[{"id":"s1","deviceId":"d","path":"/work/fieldnotes"},
        \\ {"id":"s2","deviceId":"d","path":"/work/Ledger"},
        \\ {"id":"s3","deviceId":"far","path":"/work/attic"},
        \\ {"id":"s4","deviceId":"d","path":"/work/atlas"}]
    ;
    const devices =
        \\[{"id":"d","name":"Studio","platform":"macos","lastSeenAt":null},
        \\ {"id":"far","name":"Cabin","platform":"linux","lastSeenAt":"2026-09-01T00:00:00Z"}]
    ;
    const in_spaces =
        \\[{"id":"a","deviceId":"d","title":"Alpha","spaceId":"s1","archived":false,"lastMessageAt":"2026-10-03T00:00:00Z","createdAt":"2026-09-01T00:00:00Z"},
        \\ {"id":"b","deviceId":"d","title":"Beta","spaceId":"s2","archived":false,"lastMessageAt":"2026-10-02T00:00:00Z","createdAt":"2026-10-01T00:00:00Z"}]
    ;
    inline for (.{ .{ spaces, &h.a.spaces }, .{ devices, &h.a.devices }, .{ in_spaces, &h.a.chats } }) |l| {
        var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, l[0], .{});
        defer parsed.deinit();
        try l[1].replace(parsed.value);
    }
    h.a.resort();
    if (h.a.device_id) |old| testing.allocator.free(old);
    h.a.device_id = try testing.allocator.dupe(u8, "d");
    h.t.settle(1);
}

test "the project menu: All projects, then by name with the away device's last; a search ranks them; ↓ and Return pick one" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try withProjects(&h);
    const menus = @import("view_sidebar_menus.zig");
    try h.t.clickText("All projects");
    h.t.settle(1);
    try testing.expect(h.a.view.filter_menu);
    try testing.expect(h.t.hasText("New project"));
    try testing.expect(h.t.hasText("Offline"));
    try testing.expect(h.t.hasText("@ Cabin"));
    h.snap("project-menu");
    const rows = try menus.projectRows(&h.a, testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqual(menus.Row.all, rows[0]);
    const want = [_][]const u8{ "s4", "s1", "s2", "s3" };
    for (want, rows[1..]) |id, r| try testing.expectEqualStrings(id, r.space);
    // The search takes the keys: "le" puts Ledger first.
    h.t.typeText("le");
    h.t.settle(1);
    try testing.expect(!h.t.hasText("All projects") or h.t.findText("All projects").?.y < 120);
    h.press(.{ .key = ui.Shortcut.enter });
    try testing.expect(!h.a.view.filter_menu);
    try testing.expectEqualStrings("s2", h.a.view.filter.?);
    // Only Ledger's session is listed (Alpha stays on as its tab's title).
    try testing.expect(h.t.hasText("Beta"));
    try testing.expect(h.t.findText("Alpha").?.y < 80);
    try testing.expectEqualStrings("s2", h.a.settings.spaceFilter().?);
    // Back to all, by the keys from the filter's own row.
    try h.t.clickText("Ledger");
    h.t.settle(1);
    try testing.expectEqual(@as(usize, 3), h.a.view.menus.active);
    h.press(.{ .key = ui.Shortcut.up });
    h.press(.{ .key = ui.Shortcut.up });
    h.press(.{ .key = ui.Shortcut.up });
    h.press(.{ .key = ui.Shortcut.enter });
    try testing.expect(h.a.view.filter == null);
    try testing.expect(h.a.settings.spaceFilter() == null);
}

test "the project menu closes on Escape, and on a press outside; New project is last" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try withProjects(&h);
    try h.t.clickText("All projects");
    h.t.settle(1);
    h.press(.{ .key = ui.Shortcut.escape });
    try testing.expect(!h.a.view.filter_menu);
    try h.t.clickText("All projects");
    h.t.settle(1);
    h.t.click(700, 600);
    h.t.settle(1);
    try testing.expect(!h.a.view.filter_menu);
    try testing.expect(h.t.findText("New project") == null);
}

test "the view menu: Sort › Created reorders the sessions; Show › Archived and Compact switch and are kept" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try withProjects(&h);
    // Alpha was called last: first.
    try testing.expectEqualStrings("a", h.a.chats.items[0].id);
    const more = h.a.view.more_anchor.?;
    h.t.click(more.x + more.w / 2, more.y + more.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.view.more_menu);
    try testing.expect(h.t.hasText("Last called"));
    h.snap("view-menu");
    const sort = h.t.findText("Sort").?;
    h.t.moveTo(sort.x + 4, sort.y + sort.h / 2);
    h.t.settle(1);
    try testing.expect(h.t.containsText("S\u{200A}O\u{200A}R\u{200A}T"));
    h.snap("view-menu-sort");
    try h.t.clickText("Created");
    h.t.settle(1);
    try testing.expectEqual(@import("settings.zig").Sort.created, h.a.settings.sort());
    // Beta was made last: first now; the menu stays, its value updated.
    try testing.expect(h.a.view.more_menu);
    try testing.expectEqualStrings("b", h.a.chats.items[0].id);
    const show = h.t.findText("Show").?;
    h.t.moveTo(show.x + 4, show.y + show.h / 2);
    h.t.settle(1);
    try h.t.clickText("Archived");
    h.t.settle(1);
    try testing.expect(!h.a.settings.get(.sidebar_show_archived));
    // Show's menu stays open for the next switch.
    try testing.expect(h.t.hasText("Project icon"));
    try h.t.clickText("Compact");
    h.t.settle(1);
    try testing.expect(!h.a.settings.get(.sidebar_compact));
    h.press(.{ .key = ui.Shortcut.escape });
    h.press(.{ .key = ui.Shortcut.escape });
    try testing.expect(!h.a.view.more_menu);
}

test "a right-click on a session's row opens its menu where it's clicked" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try withProjects(&h);
    const beta = h.t.findText("Beta").?;
    try rightClick(&h, beta.x + 4, beta.y + beta.h / 2);
    h.t.settle(1);
    try testing.expect(h.a.view.chat_menu.open);
    try testing.expectEqualStrings("b", h.a.view.chat_menu.id.items);
    try testing.expect(h.t.hasText("Rename…"));
    // Not a click: Beta isn't opened.
    try testing.expectEqualStrings("a", h.a.selected.?);
}

test "a project right-clicked in the project menu: Rename… and Remove…, each asking first" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try withProjects(&h);
    try h.t.clickText("All projects");
    h.t.settle(1);
    const ledger = h.t.findText("Ledger").?;
    try rightClick(&h, ledger.x + 4, ledger.y + ledger.h / 2);
    h.t.settle(1);
    try testing.expect(h.t.hasText("Rename…"));
    try testing.expect(h.t.hasText("Remove…"));
    h.snap("space-menu");
    try h.t.clickText("Remove…");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Remove project?"));
    try testing.expect(h.t.containsText("permanently deletes its 1 session on Studio"));
    h.snap("remove-project");
    // Escape closes the dialog alone; the project menu is still there.
    h.press(.{ .key = ui.Shortcut.escape });
    try testing.expect(!h.t.hasText("Remove project?"));
    try testing.expect(h.a.view.filter_menu);
    const again = h.t.findText("Ledger").?;
    try rightClick(&h, again.x + 4, again.y + again.h / 2);
    h.t.settle(1);
    try h.t.clickText("Rename…");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Rename project"));
    try testing.expectEqualStrings("Ledger", h.a.view.dialogs.name.text());
    // The field has the keys, the menu under it gone or not.
    h.t.typeText(" books");
    h.t.settle(1);
    try testing.expectEqualStrings("Ledger books", h.a.view.dialogs.name.text());
    // Return in the field is the dialog's, not the menu's.
    h.t.textOps(&.{.{ .command = .insert_newline }});
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Rename project"));
    try testing.expect(h.a.view.filter == null);
}

test "Organize › By project heads each project's sessions; Compact off shows where each runs" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try withProjects(&h);
    h.a.settings.setText("sidebarOrganization", "byProject");
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Sessions"));
    try testing.expect(h.t.hasText("fieldnotes"));
    try testing.expect(h.t.hasText("Ledger"));
    // fieldnotes' session was called last: its group first.
    try testing.expect(h.t.findText("fieldnotes").?.y < h.t.findText("Ledger").?.y);
    h.snap("organize-by-project");
    // A group shut says how many it holds.
    try h.t.clickText("Ledger");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Ledger (1)"));
    h.a.settings.setText("sidebarOrganization", "byDevice");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Studio"));
    h.a.settings.setText("sidebarOrganization", "inOneList");
    h.a.settings.set(.sidebar_compact, false);
    h.t.settle(1);
    // (The open chat's header says "fieldnotes @ Studio" too.)
    try testing.expect(h.t.hasText("Ledger @ Studio"));
    h.snap("expanded-rows");
    h.a.settings.set(.sidebar_show_project_label, false);
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Ledger @ Studio"));
}

/// Settings › GitHub CI open, on no engine.
fn openGithubCi(h: *Harness) void {
    @import("view_settings.zig").open(&h.a);
    h.a.settings.section = .github_ci;
    h.t.settle(1);
}

/// Shows `reply` as the engine's `CodegraffGithubRunners` answer (the GPUI
/// test's `set_runners`).
fn githubRunners(h: *Harness, reply: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, reply, .{});
    defer parsed.deinit();
    @import("view_settings_github_ci.zig").setRunners(&h.a, parsed.value);
    h.t.settle(1);
}

const github_connected =
    \\{"available": true, "enabled": true,
    \\ "installUrl": "https://github.com/apps/codegraff/installations/new",
    \\ "installations": [{
    \\   "installationId": "4242", "account": "fieldnotes-co", "accountType": "Organization",
    \\   "monthlyBudgetMicroUsd": 50000000, "usedThisMonthMicroUsd": 12500000, "maxConcurrent": 3,
    \\   "repos": [{"fullName": "fieldnotes-co/app", "enabled": true, "defaultSize": "standard", "private": true},
    \\             {"fullName": "fieldnotes-co/docs", "enabled": false}]
    \\ }],
    \\ "recentJobs": [{
    \\   "repo": "fieldnotes-co/app", "workflow": "CI", "jobName": "test",
    \\   "state": "completed", "conclusion": "success", "durationSeconds": 180, "costMicroUsd": 5000,
    \\   "htmlUrl": "https://github.com/fieldnotes-co/app/actions/runs/1/job/2"
    \\ }],
    \\ "sizes": [{"key": "standard", "cpu": 2, "memoryGiB": 4, "pricePerHourMicroUsd": 100000},
    \\           {"key": "large", "cpu": 4, "memoryGiB": 8, "pricePerHourMicroUsd": 200000}]}
;

test "Settings › GitHub CI: without an engine it says so, with Retry and Refresh" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openGithubCi(&h);
    try testing.expect(h.t.hasText("GitHub CI"));
    try testing.expect(h.t.hasText("Refresh"));
    try testing.expect(h.t.hasText("Engine not connected"));
    try testing.expect(h.t.hasText("Retry"));
    try testing.expect(!h.t.hasText("Connect GitHub"));
    h.snap("github-ci-no-engine");
}

test "Settings › GitHub CI: each answer shows its panel" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openGithubCi(&h);
    try githubRunners(&h, "null");
    try testing.expect(h.t.hasText("Sign in with Codegraff from the account menu to run GitHub Actions on Codegraff."));
    try testing.expect(!h.t.hasText("Engine not connected"));
    try githubRunners(&h, "{}");
    try testing.expect(h.t.hasText("GitHub CI isn't available on Codegraff yet. This page fills in once it is."));
    try testing.expect(h.t.hasText("Coming soon"));
    try githubRunners(&h, "{\"available\": true, \"enabled\": false}");
    try testing.expect(h.t.hasText("GitHub CI is coming soon to your Codegraff account."));
    try githubRunners(&h, "{\"available\": true, \"enabled\": true}");
    try testing.expect(h.t.hasText("Codegraff didn't send an install link. Try Refresh."));
    try githubRunners(&h, "{\"available\": true, \"enabled\": true, \"installUrl\": \"https://github.com/apps/codegraff/installations/new\"}");
    try testing.expect(h.t.hasText("Run GitHub Actions on Codegraff"));
    try testing.expect(h.t.hasText("Connect GitHub"));
    try testing.expect(h.t.hasText("In a workflow, run a job on Codegraff:"));
    try testing.expect(h.t.hasText("    runs-on: codegraff"));
    try testing.expect(!h.t.hasText("Recent jobs"));
    h.snap("github-ci-not-connected");
    // Copy puts the snippet on the clipboard, and says so for a moment.
    try h.t.clickText("Copy");
    h.t.settle(1);
    try testing.expectEqualStrings(@import("runners.zig").yaml_snippet, h.t.clipboard.items);
    try testing.expect(h.t.hasText("Copied"));
    h.t.advance(2);
    try testing.expect(h.t.hasText("Copy"));

    h.t.resize(1200, 1400);
    try githubRunners(&h, github_connected);
    try testing.expect(!h.t.hasText("Connect GitHub"));
    for ([_][]const u8{
        "fieldnotes-co",
        "Organization · 1 of 2 repositories on",
        "Monthly budget",
        "$12.50 of $50 used this month",
        "Fork pull request budget",
        "Jobs from outside contributors stop at this amount each month.",
        "Concurrent jobs",
        "3",
        "fieldnotes-co/app",
        "Private",
        "Standard · $0.10/h",
        "fieldnotes-co/docs",
        "Connect another account",
        "Recent jobs",
        "fieldnotes-co/app · CI · test",
        "Open on GitHub",
    }) |want| {
        if (!h.t.hasText(want)) std.debug.print("missing: {s}\n", .{want});
        try testing.expect(h.t.hasText(want));
    }
    try testing.expect(h.t.hasText("Succeeded · 3m 0s · $0.005"));
    const page = &h.a.view.github_ci;
    try testing.expectEqualStrings("50", page.inputs.items[0].buf.text());
    h.snap("github-ci-connected");
}

test "Settings › GitHub CI: a bad budget is refused in place, and nothing is sent" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openGithubCi(&h);
    try githubRunners(&h, "{\"available\": true, \"enabled\": true, \"installations\": [{\"installationId\": \"1\", \"account\": \"studio\"}]}");
    try testing.expect(h.t.hasText("No repositories yet. Choose them in the Codegraff app's settings on GitHub."));
    try testing.expect(h.t.hasText("$0 used this month · no monthly budget"));
    const page = &h.a.view.github_ci;
    page.inputs.items[0].buf.set("twelve");
    try h.t.clickText("Save");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Enter a dollar amount, like 50 or 12.50."));
    try testing.expect(page.busy == null);
    h.snap("github-ci-bad-budget");
    // Editing it again clears the complaint.
    const field = h.t.findText("twelve") orelse return error.NoField;
    h.t.click(field.x + field.w, field.y + field.h / 2);
    h.t.settle(1);
    h.t.typeText("0");
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Enter a dollar amount, like 50 or 12.50."));
}

test "Settings › GitHub CI: the concurrent-jobs stepper stays within 1…8; Disconnect asks first; a size opens its menu" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openGithubCi(&h);
    h.t.resize(1200, 1400);
    try githubRunners(&h, "{\"available\": true, \"enabled\": true, \"installations\": [{\"installationId\": \"1\", \"account\": \"studio\", \"maxConcurrent\": 40, \"repos\": [{\"fullName\": \"studio/site\", \"enabled\": true}]}], \"sizes\": [{\"key\": \"standard\", \"cpu\": 2, \"memoryGiB\": 4, \"pricePerHourMicroUsd\": 100000}]}");
    try testing.expect(h.t.hasText("8"));
    try testing.expect(!h.t.hasText("40"));
    try githubRunners(&h, "{\"available\": true, \"enabled\": true, \"installations\": [{\"installationId\": \"1\", \"account\": \"studio\", \"maxConcurrent\": 0, \"repos\": [{\"fullName\": \"studio/site\", \"enabled\": true}]}], \"sizes\": [{\"key\": \"standard\", \"cpu\": 2, \"memoryGiB\": 4, \"pricePerHourMicroUsd\": 100000}]}");
    try testing.expect(h.t.hasText("1"));
    try h.t.clickText("Disconnect");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Disconnect for good?"));
    // No size named: the first.
    try h.t.clickText("Standard · $0.10/h");
    h.t.settle(1);
    try testing.expect(h.t.containsText("D\u{200A}E\u{200A}F\u{200A}A\u{200A}U\u{200A}L\u{200A}T"));
    try testing.expect(h.t.hasText("Standard · 2 vCPU · 4 GB · $0.10/h"));
    h.snap("github-ci-size-menu");
    h.t.click(700, 1300);
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Standard · 2 vCPU · 4 GB · $0.10/h"));
}

/// Settings › Agents open, on no engine.
fn openAgents(h: *Harness) void {
    @import("view_settings.zig").open(&h.a);
    h.a.settings.section = .harnesses;
    h.t.resize(1200, 1400);
    h.t.settle(1);
}

/// Shows `reply` as the engine's `ListHarnesses` answer.
fn agentList(h: *Harness, reply: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, reply, .{});
    defer parsed.deinit();
    @import("view_settings_agents.zig").setList(&h.a, parsed.value);
    h.t.settle(1);
}

/// The switch on the row titled `name`: at the card's right edge, level
/// with the middle of the title and the line under it.
fn agentToggle(h: *Harness, name: []const u8, line: []const u8) !void {
    const t = h.t.findText(name) orelse return error.NoRow;
    const m = h.t.findText(line) orelse return error.NoRow;
    const main_w = 1200 - @import("view_sidebar.zig").width;
    const col_w = @min(main_w, 768);
    const right = @import("view_sidebar.zig").width + (main_w - col_w) / 2 + col_w - 24 - 1 - 20;
    h.t.click(right - 16, (t.y + m.y + m.h) / 2);
    h.t.settle(1);
}

test "Settings › Agents: with no engine, the GPUI app's waiting page" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openAgents(&h);
    for ([_][]const u8{
        "Agents",
        "This device",
        "This GUI drives whatever agent is installed on the selected device. A custom build can point at its binary with that agent's *_EXECUTABLE variable. Downloads start only when you choose Install.",
        "Experimental Graff ACP child agents",
        "Session titles",
        "Loading title settings…",
    }) |want| try testing.expect(h.t.hasText(want));
    // Nothing asked, nothing failed: the skeleton waits for an engine.
    try testing.expectEqual(.idle, h.a.view.agents.phase);
    try testing.expect(!h.t.hasText("Engine not connected"));
    try testing.expect(!h.t.hasText("Retry"));
    h.snap("agents-no-engine");
}

const agent_catalog =
    \\[{"id":"codex","name":"Codex","installed":true,"enabled":true},
    \\ {"id":"graff","name":"Graff","installed":true,"canInstall":true,"enabled":false},
    \\ {"id":"pi","name":"Pi","installed":false,"canInstall":false},
    \\ {"id":"cursor","name":"Cursor","installed":true,"enabled":false},
    \\ {"id":"antigravity","name":"Antigravity","installed":true,"enabled":false},
    \\ {"id":"mock","name":"Mock","installed":true}]
;

test "Settings › Agents: each row's blurb, hints and actions, as the GPUI app's" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openAgents(&h);
    try agentList(&h, agent_catalog);
    for ([_][]const u8{
        "OpenAI's coding agent, driven through the Codex CLI.",
        "codegraff's graff agent over ACP (graff CLI).",
        "Install beta updates the managed Codegraff CLI for new Graff sessions.",
        "Update",
        "Install beta",
        "The pi coding agent (pi CLI).",
        "Install the pi CLI to enable. Install with `npm install -g --ignore-scripts @earendil-works/pi-coding-agent`",
        "Custom build: set PI_EXECUTABLE to that binary.",
        "Off by default — turn on to use",
        "Sign in",
    }) |want| {
        if (!h.t.hasText(want)) std.debug.print("missing: {s}\n", .{want});
        try testing.expect(h.t.hasText(want));
    }
    // The mock is the dev rig's: hidden.
    try testing.expect(!h.t.hasText("Scripted test harness."));
    // Pi can't be installed from here: no Install.
    try testing.expect(!h.t.hasText("Install"));
    h.snap("agents-rows");
}

test "Settings › Agents: the last enabled agent can't be switched off; another can be switched on" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openAgents(&h);
    try agentList(&h, agent_catalog);
    // Codex is the only one on: its switch does nothing.
    try agentToggle(&h, "Codex", "OpenAI's coding agent, driven through the Codex CLI.");
    try testing.expect(!h.t.hasText("Engine not connected"));
    // Cursor is installed and off: its switch asks the engine (none here).
    try agentToggle(&h, "Cursor", "Cursor's coding agent, driven through the cursor-agent CLI.");
    try testing.expect(h.t.hasText("Engine not connected"));
}

test "Settings › Agents: graff's compact-at pills; a point set elsewhere is named" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openAgents(&h);
    try agentList(&h, agent_catalog);
    try testing.expect(h.t.hasText("Compact context at"));
    for (@import("agents.zig").compact_choices) |ch| try testing.expect(h.t.hasText(ch.label));
    try testing.expect(h.t.hasText("How full the context window gets before Graff compacts. Applies to new Graff chats; /compact-at 70 changes one chat."));
    @import("view_settings_agents.zig").setCompact(&h.a, 65);
    h.t.settle(1);
    try testing.expect(h.t.hasText("Currently 65%, set on this device."));
    @import("view_settings_agents.zig").setCompact(&h.a, 70);
    h.t.settle(1);
    try testing.expect(!h.t.hasText("Currently 70%, set on this device."));
    h.snap("agents-compact-at");
    // A pill saves through the engine; with none, the strip says so.
    try h.t.clickText("50%");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Engine not connected"));
    try testing.expect(!h.a.view.agents.compact_saving);
}

test "Settings › Agents: the device switcher lists each device, this one as You, and retargets the page" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\[{"id":"d2","name":"Workbench","platform":"linux","createdAt":"2026-10-02T00:00:00Z"},
        \\ {"id":"d1","name":"Studio","platform":"macos","createdAt":"2026-10-01T00:00:00Z"}]
    , .{});
    defer parsed.deinit();
    try h.a.devices.replace(parsed.value);
    h.a.device_id = try testing.allocator.dupe(u8, "d1");
    openAgents(&h);
    try agentList(&h, agent_catalog);
    try h.t.clickText("Studio");
    h.t.settle(1);
    try testing.expect(h.t.containsText("D\u{200A}E\u{200A}V\u{200A}I\u{200A}C\u{200A}E\u{200A}S"));
    try testing.expect(h.t.hasText("Workbench"));
    try testing.expect(h.t.hasText("You"));
    // Added first, listed first.
    const studio = h.t.findText("You") orelse return error.NoRow;
    const bench = h.t.findText("Workbench") orelse return error.NoRow;
    try testing.expect(studio.y < bench.y);
    h.snap("agents-device-menu");
    try h.t.clickText("Workbench");
    h.t.settle(1);
    const p = &h.a.view.agents;
    try testing.expectEqualStrings("d2", p.target.?);
    try testing.expect(!p.device_menu);
    // Another device: its rows are read again (and wait for an engine).
    try testing.expectEqual(.idle, p.phase);
    try testing.expect(!h.t.hasText("You"));
    try h.t.clickText("Workbench");
    h.t.settle(1);
    try h.t.clickText("Studio");
    h.t.settle(1);
    try testing.expect(p.target == null);
}

test "Settings › Agents: session titles name the agent and model; the agent list offers those that can title" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openAgents(&h);
    try agentList(&h, agent_catalog);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"harness\":\"claude-code\",\"model\":null}", .{});
    defer parsed.deinit();
    @import("view_settings_agents.zig").setTitles(&h.a, parsed.value);
    h.t.settle(1);
    try testing.expect(h.t.hasText("Title harness"));
    try testing.expect(h.t.hasText("Automatic (cheapest model)"));
    try testing.expect(!h.t.hasText("Automatic"));
    try h.t.clickText("Claude Code");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Automatic"));
    try testing.expectEqual(@as(?bool, false), h.a.view.agents.title_menu);
}

/// Settings › Accounts open, on no engine.
fn openAccounts(h: *Harness) void {
    @import("view_settings.zig").open(&h.a);
    h.a.settings.section = .agents;
    h.t.settle(1);
}

/// Shows `reply` as the engine's answer to `which`'s call.
fn accountsReply(h: *Harness, comptime which: []const u8, reply: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, reply, .{});
    defer parsed.deinit();
    @field(@import("view_settings_accounts.zig"), which)(&h.a, parsed.value);
    h.t.settle(1);
}

test "Settings › Accounts: without an engine, as the GPUI app's: loading cards, ChatGPT unknown, the failure with Click to retry" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openAccounts(&h);
    for ([_][]const u8{ "Accounts", "Refresh", "CodeGraff", "View usage", "ChatGPT", "Continue with ChatGPT", "Separate from Codex · graff login chatgpt-new", "graff providers", "Engine not connected", "Click to retry" }) |want| {
        if (!h.t.hasText(want)) std.debug.print("missing: {s}\n", .{want});
        try testing.expect(h.t.hasText(want));
    }
    try testing.expect(h.t.containsText("Switching rewrites the CLI"));
    try testing.expect(!h.t.hasText("Sign out"));
    try testing.expect(!h.t.hasText("Add account"));
    try testing.expect(!h.t.hasText("Claude Code"));
    // Retrying without an engine fails again, in place.
    try h.t.clickText("Click to retry");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Engine not connected"));
    // Signing in needs an engine: the page says so.
    try h.t.clickText("Continue with ChatGPT");
    h.t.settle(1);
    try testing.expectEqualStrings("Engine not connected", h.a.view.accounts.notice.items);
    try testing.expect(h.a.view.accounts.login.flow == null);
    h.snap("accounts-no-engine");
}

const accounts_snapshot =
    \\{"accounts": [
    \\  {"id": "c1", "harness": "claude-code", "email": "ada@example.com", "planLabel": "Max", "active": true, "switchable": true,
    \\   "usageWindows": [{"label": "5h", "usedFraction": 0.42, "resetsAt": null}, {"label": "Weekly", "usedFraction": 0.86, "resetsAt": null}]},
    \\  {"id": "c2", "harness": "claude-code", "email": "bea@example.com", "planLabel": "Pro", "active": false, "switchable": true},
    \\  {"id": "c3", "harness": "claude-code", "email": null, "displayName": "Kit", "planLabel": null, "active": false, "switchable": false}],
    \\ "warnings": [{"harness": "codex", "message": "Keychain didn't let Harness read the Codex login."}]}
;

test "Settings › Accounts: accounts with plans, Active, meters; empty providers; CodeGraff usage; graff's sign-ins" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.resize(1200, 2200);
    openAccounts(&h);
    try accountsReply(&h, "setSnapshot", accounts_snapshot);
    try accountsReply(&h, "setUsage",
        \\{"email": "cg@example.com", "tier": "Team", "credits_micro_usd": 12340000, "spend_30d_micro_usd": 2500000,
        \\ "requests_30d": 31, "key_budget_monthly_micro_usd": 20000000, "key_spend_monthly_micro_usd": 5000000, "key_budget_resets_at": ""}
    );
    try accountsReply(&h, "setGraffLogins",
        \\[{"id": "xai", "name": "xAI", "signedIn": true, "account": "x@example.com"},
        \\ {"id": "kimi", "name": "Kimi", "signedIn": false},
        \\ {"id": "chatgpt-new", "name": "ChatGPT", "signedIn": true, "account": "g@example.com", "planUsage": true}]
    );
    for ([_][]const u8{
        // Three accounts and the CodeGraff sign-in.
        "4",
        "Sign out",
        "cg@example.com",
        "Graff CLI account on this device",
        "$12.34 credits available",
        "$2.50 spent · 31 requests in 30 days",
        // "Key budget", cut at the meter's 48-point label as GPUI's.
        "25% used",
        "Team",
        "Signed in as g@example.com · using your ChatGPT plan",
        "Manage usage",
        "xAI",
        "Signed in as x@example.com",
        "Sign in again",
        "ChatGPT (old Codex)",
        "Not signed in — add a Codex account below",
        "Kimi",
        "Sign in",
        "Claude Code",
        "ada@example.com",
        "Active",
        "Max",
        "5h",
        "42% used",
        "Weekly",
        "86% used",
        "bea@example.com",
        "Pro",
        "Usage unavailable",
        "Switch",
        "Kit",
        "Credentials unavailable",
        "Keychain didn't let Harness read the Codex login.",
        "No Codex login detected on this device — sign in with \u{201C}codex\u{201D} or add an account.",
        "Cursor isn't connected on this device — connect it to run Cursor sessions.",
        "Add account",
    }) |want| {
        if (!h.t.hasText(want)) std.debug.print("missing: {s}\n", .{want});
        try testing.expect(h.t.hasText(want));
    }
    try testing.expect(!h.t.hasText("Engine not connected"));
    // The legacy Codex row comes second, after graff's first provider.
    try testing.expect(h.t.findText("xAI").?.y < h.t.findText("ChatGPT (old Codex)").?.y);
    try testing.expect(h.t.findText("ChatGPT (old Codex)").?.y < h.t.findText("Kimi").?.y);
    // The engine's order holds: the active account isn't moved first.
    try testing.expect(h.t.findText("ada@example.com").?.y < h.t.findText("bea@example.com").?.y);
    h.snap("accounts-ready");
    // Switch without an engine leaves the row be.
    try h.t.clickText("Switch");
    h.t.settle(1);
    try testing.expect(h.a.view.accounts.busy_account == null);
}

test "Settings › Accounts: the add-account dialog's paste-code and browser bodies; Copy, then Escape closes it" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    openAccounts(&h);
    const p = &h.a.view.accounts;
    // As StartAgentLogin answers for Claude: open the page, paste the code.
    p.login.flow = .{ .stage = .paste, .harness = .claude_code, .start = .{ .login_id = "l1", .url = "https://example.com/oauth/authorize?state=demo", .mode = .paste_code } };
    p.login.focus_code = true;
    h.t.settle(1);
    try testing.expect(h.t.hasText("Add Claude account"));
    try testing.expect(h.t.hasText("Reopen the authorization page"));
    try testing.expect(h.t.hasText("Or copy this link into any browser"));
    try testing.expect(h.t.hasText("Add account"));
    try testing.expect(h.t.hasText("Cancel"));
    // The field has the keys.
    h.t.typeText("abc123");
    h.t.settle(1);
    try testing.expectEqualStrings("abc123", p.login.code.text());
    h.snap("accounts-paste-code");
    try h.t.clickText("Copy");
    h.t.settle(1);
    try testing.expectEqualStrings("https://example.com/oauth/authorize?state=demo", h.t.clipboard.items);
    try testing.expect(h.t.hasText("Copied"));
    h.press(.{ .key = ui.Shortcut.escape });
    try testing.expect(p.login.flow == null);
    try testing.expect(!h.t.hasText("Add Claude account"));
    // A graff device-code sign-in: the code to confirm, then the wait.
    p.login.flow = .{ .stage = .browser, .harness = .graff, .provider = try testing.allocator.dupe(u8, "xai"), .start = .{ .login_id = "l2", .url = "https://example.com/device", .mode = .browser, .code = "WXYZ-1234" } };
    h.t.settle(1);
    try testing.expect(h.t.hasText("Sign in to xAI"));
    try testing.expect(h.t.hasText("Finish signing in to xAI in your browser. graff saves the login itself, so nothing is copied into Harness."));
    try testing.expect(h.t.hasText("Confirm this code on the page"));
    try testing.expect(h.t.hasText("WXYZ-1234"));
    try testing.expect(h.t.hasText("Waiting for the browser…"));
    h.snap("accounts-browser");
    try h.t.clickText("Cancel");
    h.t.settle(1);
    try testing.expect(p.login.flow == null);
}

const sandboxes_reply =
    \\{"enabled": true,
    \\ "sandboxes": [
    \\  {"id": "sbx-run", "provider": "fleet", "name": "Field cloud", "state": "running", "harness": true, "keepRunning": false,
    \\   "cpu": 2, "memoryGiB": 4, "pricePerHourMicroUsd": 100000},
    \\  {"id": "sbx-bare", "provider": "fleet", "name": "Half set up", "state": "running", "harness": false},
    \\  {"id": "sbx-nap", "provider": "fleet", "name": "Napping box", "state": "paused", "harness": true},
    \\  {"id": "tmp-7", "provider": "daytona", "state": "paused", "tier": "ephemeral"}],
    \\ "sizes": [
    \\  {"id": "standard", "cpu": 2, "memoryGiB": 4, "diskGiB": 40, "pricePerHourMicroUsd": 100000, "default": true},
    \\  {"id": "large", "cpu": 4, "memoryGiB": 8, "diskGiB": 80, "pricePerHourMicroUsd": 200000}]}
;

test "Settings › Accounts: cloud sandboxes with each one's buttons, Delete asking first, the size choice, and the running strip" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    h.t.resize(1200, 2400);
    openAccounts(&h);
    try testing.expect(!h.t.hasText("Cloud sandboxes"));
    try accountsReply(&h, "feedSandboxes", sandboxes_reply);
    for ([_][]const u8{
        "Cloud sandboxes",
        "Field cloud",
        "Running · 2 vCPU · 4 GB · $0.10/h",
        "Keep running",
        "Half set up",
        "Running · Harness not set up",
        "Set up Harness",
        "Napping box",
        "Paused — memory and files kept",
        "Start",
        "Temporary sandbox",
        "Paused",
        "Copy ID",
        "Harness cloud",
        "Standard",
        "2 vCPU · 4 GB · 40 GB · $0.10/h",
        "Large",
        "4 vCPU · 8 GB · 80 GB · $0.20/h",
        "Create",
        "Create temporary",
        // The strip in the settings sidebar: two running, so Turn off all.
        "Turn off all",
    }) |want| {
        if (!h.t.hasText(want)) std.debug.print("missing: {s}\n", .{want});
        try testing.expect(h.t.hasText(want));
    }
    try testing.expect(h.t.containsText("Cloud sandbox"));
    // Cut to the strip's width: "Billed per second until you turn it off".
    try testing.expect(h.t.containsText("Billed per"));
    h.snap("accounts-sandboxes");
    const cl = &h.a.view.accounts.cloud;
    // Delete asks first; nothing is sent.
    var deletes: usize = 0;
    for (h.t.ctx.nodes.items) |n| switch (n.content) {
        .text => |t| if (std.mem.eql(u8, t.str, "Delete")) {
            deletes += 1;
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 4), deletes);
    try h.t.clickText("Delete");
    h.t.settle(1);
    try testing.expect(h.t.hasText("Delete for good?"));
    try testing.expectEqualStrings("sbx-run", cl.confirm_delete.?);
    try testing.expect(cl.busy == null);
    // Copy ID puts the temporary one's id on the clipboard.
    try h.t.clickText("Copy ID");
    h.t.settle(1);
    try testing.expectEqualStrings("tmp-7", h.t.clipboard.items);
    // The size choice: Standard by default, Large once picked.
    try testing.expect(cl.size == null);
    try h.t.clickText("Large");
    h.t.settle(1);
    try testing.expectEqualStrings("large", cl.size.?);
    // Without an engine, Create starts nothing.
    try h.t.clickText("Create");
    h.t.settle(1);
    try testing.expect(!cl.creating);
    // A Turn off under way reads so, and dims its row's buttons.
    cl.busy = try testing.allocator.dupe(u8, "sbx-run");
    cl.busy_action = "stop";
    h.t.settle(1);
    try testing.expect(h.t.hasText("Turning off…"));
    // Where the feature is off, no card and no strip.
    try accountsReply(&h, "feedSandboxes", "{\"enabled\": false, \"sandboxes\": []}");
    try testing.expect(!h.t.hasText("Cloud sandboxes"));
    try testing.expect(!h.t.hasText("Turn off all"));
}
