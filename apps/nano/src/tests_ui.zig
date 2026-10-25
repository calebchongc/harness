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
