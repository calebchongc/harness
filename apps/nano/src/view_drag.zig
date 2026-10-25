//! Dragging a session from the sidebar onto the chat splits it there, as
//! the GPUI app's (`render_split_drop_zones`, shell/chat_split.rs): while a
//! row is dragged, two targets lie over the chat, "Open to the right" down
//! its right edge and "Open below" along its foot; dropping on one opens
//! the session in a new pane that way. The row rides under the pointer.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const sidebar = @import("view_sidebar.zig");
const transcript_view = @import("view_transcript.zig");
const tabs = @import("tabs.zig");
const App = @import("app.zig").App;

/// A row pressed: the session, where the press was, and whether the
/// pointer has gone far enough to be a drag.
pub const Drag = struct {
    id: std.ArrayList(u8) = .empty,
    origin: ui.Point = .{},
    /// The press's offset into its row, so the row rides where it was held.
    grip: ui.Point = .{},
    active: bool = false,

    pub fn deinit(d: *Drag, gpa: std.mem.Allocator) void {
        d.id.deinit(gpa);
    }
};

/// How far the pointer goes, held, before a press is a drag.
const threshold: f32 = 4;

/// From a session row pressed this frame.
pub fn press(c: *ui.Context, a: *App, chat_id: []const u8, row: ?ui.Rect) void {
    const d = &a.view.drag;
    d.id.clearRetainingCapacity();
    d.id.appendSlice(a.gpa, chat_id) catch return;
    d.origin = c.input.mouse;
    d.grip = if (row) |r| .{ .x = c.input.mouse.x - r.x, .y = c.input.mouse.y - r.y } else .{};
    d.active = false;
}

/// Whether a session is being dragged: its row's click is the drop's.
pub fn dragging(a: *const App) bool {
    return a.view.drag.active;
}

/// Early each frame: a press becomes a drag once it has moved far enough.
pub fn update(c: *ui.Context, a: *App) void {
    const d = &a.view.drag;
    if (d.id.items.len == 0 or d.active or !c.input.down) return;
    const dx = c.input.mouse.x - d.origin.x;
    const dy = c.input.mouse.y - d.origin.y;
    if (dx * dx + dy * dy >= threshold * threshold) d.active = true;
}

const Zone = struct { rect: ui.Rect, axis: tabs.Axis, label: []const u8 };

/// The targets over the chat column (`chat-drop-right`, `chat-drop-below`):
/// the right one 30% of its width below the title bar, the one below 28% of
/// its height, clear of the right one; both 8 points in.
pub fn zones(a: *const App, x0: f32, w: f32, h: f32, out: *[2]Zone) []Zone {
    var n: usize = 0;
    const right = a.tabs.canSplit(.horizontal);
    const below = a.tabs.canSplit(.vertical);
    if (right) {
        out[n] = .{ .rect = .{ .x = x0 + w - 8 - w * 0.3, .y = sidebar.titlebar_h + 8, .w = w * 0.3, .h = h - 16 - sidebar.titlebar_h }, .axis = .horizontal, .label = "Open to the right ◨" };
        n += 1;
    }
    if (below) {
        const end = if (right) x0 + w - w * 0.33 else x0 + w - 8;
        out[n] = .{ .rect = .{ .x = x0 + 8, .y = h - 8 - h * 0.28, .w = end - x0 - 8, .h = h * 0.28 }, .axis = .vertical, .label = "Open below ⬓" };
        n += 1;
    }
    return out[0..n];
}

/// Over everything, while a session is dragged: the targets, the row under
/// the pointer, and on release the split (or nothing, off the targets).
pub fn overlay(c: *ui.Context, a: *App, k: theme.Colors) void {
    const d = &a.view.drag;
    if (d.id.items.len == 0) return;
    if (!d.active) {
        if (!c.input.down) d.id.clearRetainingCapacity();
        return;
    }
    const x0: f32 = if (a.view.sidebar_open) sidebar.width else 0;
    var buf: [2]Zone = undefined;
    const targets = if (a.view.settings_open) buf[0..0] else zones(a, x0, transcript_view.mainWidth(c, a), c.size.h, &buf);
    var over: ?Zone = null;
    for (targets) |z| if (z.rect.contains(c.input.mouse)) {
        over = z;
    };
    for (targets) |z| {
        const hot = over != null and over.?.axis == z.axis;
        var box = ui.div(c).fixed().offset(z.rect.x, z.rect.y).size(z.rect.w, z.rect.h).layer(6).center().rounded(12)
            .border(if (hot) k.accent.alpha(0.7) else k.border).borderW(1).bg(if (hot) k.accent.alpha(0.14) else k.ink(0.02));
        // Dashed, as GPUI's, with a nanoui that dashes (justrach/nanoui#21).
        if (comptime @hasDecl(ui.Div, "dashed")) box = box.dashed();
        defer box.end();
        ui.text(c, z.label, .{ .size = 12.5, .line_height = 12.5 * 1.618, .color = if (hot) k.accent else k.muted });
    }
    ghost(c, a, k);
    if (c.input.down) {
        c.cursor = .hand;
        return;
    }
    // Released.
    const id = a.gpa.dupe(u8, d.id.items) catch "";
    defer if (id.len > 0) a.gpa.free(id);
    d.id.clearRetainingCapacity();
    d.active = false;
    if (over) |z| a.splitOpening(z.axis, id);
}

/// The dragged row, lifted, under the pointer where it was held.
fn ghost(c: *ui.Context, a: *App, k: theme.Colors) void {
    const d = &a.view.drag;
    const ch = a.findChat(d.id.items) orelse return;
    const w = sidebar.width - 20;
    const row = kit.shadowLg(ui.div(c).fixed().offset(c.input.mouse.x - d.grip.x, c.input.mouse.y - d.grip.y).w(w).h(29).layer(7)
        .row().px(8).gap(6).itemsCenter().rounded(8).bg(k.raised).border(k.border).borderW(1));
    defer row.end();
    kit.fadeText(c, sidebar.chatLabel(ch), kit.style(c, 13, 17, .{ .color = k.text }), w - 16);
}

const testing = std.testing;

test "the drop targets sit as the GPUI app's, and only where a split can go" {
    var a: App = .init(testing.allocator, testing.io, 1);
    defer a.deinit();
    var buf: [2]Zone = undefined;
    const both = zones(&a, 256, 944, 780, &buf);
    try testing.expectEqual(@as(usize, 2), both.len);
    try testing.expectApproxEqAbs(@as(f32, 256 + 944 - 8 - 944 * 0.3), both[0].rect.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 38 + 8), both[0].rect.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 780 * 0.28), both[1].rect.h, 0.01);
    // Split across: only the right target is left.
    a.tabs.show("x");
    _ = try a.tabs.split(.horizontal);
    const one = zones(&a, 256, 944, 780, &buf);
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqual(tabs.Axis.horizontal, one[0].axis);
}
