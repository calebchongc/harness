//! The sidebar, as the GPUI shell lays it out (crates/ui/src/shell.rs,
//! shell/chat_tabs.rs, shell/spaces.rs): the open tabs, the project filter
//! with search and view options, then Sessions and Archived, each row a
//! status mark, the agent's mark, the project's monogram, a fading title
//! and how long ago; the account badge at the foot.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const rules = @import("rules.zig");
const workspace = @import("workspace.zig");
const App = @import("app.zig").App;

pub const width: f32 = 256;
pub const titlebar_h: f32 = 38;

pub fn sidebar(c: *ui.Context, a: *App, k: theme.Colors) void {
    // The edge after it is inside its width, as the GPUI app's.
    const side = ui.div(c).column().w(width - 1).hFull().bg(k.sidebar).pt(titlebar_h);
    defer side.end();
    tabList(c, a, k);
    filterRow(c, a, k);
    if (a.view.search_open) searchField(c, a, k);
    lists(c, a, k);
    footer(c, a, k);
}

fn tabList(c: *ui.Context, a: *App, k: theme.Colors) void {
    const tabs = a.tabs.items.items;
    const box = ui.div(c).column().wFull().px(10).pt(4).pb(6).gap(2);
    defer box.end();
    if (tabs.len > 1) {
        const h = ui.div(c).row().px(4).pb(2);
        defer h.end();
        ui.text(c, c.print("Tabs · {d}", .{tabs.len}), .{ .size = 11, .color = k.muted.alpha(0.8) });
    }
    var close: ?usize = null;
    var show: ?usize = null;
    for (tabs, 0..) |id, i| {
        ui.key(c, c.print("tab-{d}", .{i}));
        const lit = i == a.tabs.active;
        var row = ui.div(c).row().wFull().h(26).px(8).gap(6).itemsCenter().rounded(7).clip();
        row = if (lit) row.bg(k.hover) else row.hover(k.hover);
        defer row.end();
        const hovered = row.hovered();
        if (row.clicked() and !lit) show = i;
        {
            const slot = ui.div(c).row().size(16, 16).center().rounded(4);
            defer slot.end();
            if (hovered and tabs.len > 1) {
                const x = ui.div(c).row().size(16, 16).center().rounded(4).hover(k.wash(0.12));
                defer x.end();
                if (x.clicked()) close = i;
                icons.icon(c, .close, 12, k.muted, 0);
            } else {
                ui.text(c, c.print("{d}", .{i + 1}), .{ .size = 11, .color = k.muted.alpha(0.7) });
            }
        }
        const title = if (id) |cid| (if (a.findChat(cid)) |ch| chatLabel(ch) else "Untitled session") else "New session";
        kit.ellipsisText(c, title, .{ .size = 12.5, .color = if (lit) k.text else k.muted }, width - 20 - 16 - 16 - 6);
    }
    if (close) |i| a.closeTab(i) else if (show) |i| a.showTab(i);
}

fn filterRow(c: *ui.Context, a: *App, k: theme.Colors) void {
    const row = ui.div(c).row().wFull().px(8).pt(8).pb(4).gap(4).itemsCenter();
    defer row.end();
    {
        var t = ui.div(c).row().grow().h(29).px(8).gap(8).itemsCenter().rounded(8).clip();
        t = if (a.view.filter_menu) t.bg(k.hover) else t.hover(k.hover);
        defer t.end();
        if (t.clicked()) a.view.filter_menu = !a.view.filter_menu;
        if (c.rects.get(c.node(t.index).id)) |r| a.view.filter_anchor = r;
        icons.icon(c, .folder, 16, k.muted, 0);
        const space = a.findSpace(a.view.filter);
        const label = if (space) |s| s.name else "All projects";
        const color = if (t.hovered() or a.view.filter_menu) k.text else k.text.alpha(0.8);
        kit.fadeText(c, label, .{ .size = 13, .weight = .medium, .color = color }, width - 16 - 8 - 58 - 16 - 24 - 14 - 16);
        ui.spacer(c);
        icons.icon(c, .@"alt-arrow-down", 14, k.muted.alpha(0.6), 0);
    }
    if (kit.iconButton(c, k, .@"palette-search", .{ .size = 29, .radius = 8, .color = k.muted.alpha(0.6), .on = a.view.search_open })) {
        a.view.search_open = !a.view.search_open;
        if (!a.view.search_open) a.view.search.clear();
    }
    const more = ui.div(c).row();
    defer more.end();
    if (kit.iconButton(c, k, .@"more-horizontal", .{ .size = 29, .radius = 8, .color = k.muted.alpha(0.6), .on = a.view.more_menu }))
        a.view.more_menu = !a.view.more_menu;
    if (c.rects.get(c.node(more.index).id)) |r| a.view.more_anchor = r;
}

fn searchField(c: *ui.Context, a: *App, k: theme.Colors) void {
    const box = ui.div(c).row().wFull().px(8).pb(4);
    defer box.end();
    const field = ui.div(c).row().wFull().h(29).px(8).gap(6).itemsCenter().rounded(8).bg(k.ink(0.05)).border(k.border).borderW(1);
    defer field.end();
    icons.icon(c, .magnifer, 14, k.muted, 0);
    _ = ui.textField(c, &a.view.search, .{ .placeholder = "Search sessions", .width = .fill, .bare = true, .size = 13 });
    if (c.shortcut(.{ .key = ui.Shortcut.escape })) {
        a.view.search.clear();
        a.view.search_open = false;
    }
}

/// The rows the lists show: top-level chats in a project that still
/// exists (or none), narrowed by the project filter and the search.
fn listed(a: *const App, chat: workspace.Chat) bool {
    if (chat.parent_chat_id != null) return false;
    if (chat.space_id) |sid| if (a.findSpace(sid) == null) return false;
    if (a.view.filter) |f| if (chat.space_id == null or !std.mem.eql(u8, chat.space_id.?, f)) return false;
    const q = std.mem.trim(u8, a.view.search.text(), " ");
    if (q.len > 0 and !containsIgnoreCase(chatLabel(chat), q)) return false;
    return true;
}

fn containsIgnoreCase(s: []const u8, q: []const u8) bool {
    if (q.len > s.len) return false;
    for (0..s.len - q.len + 1) |i| if (std.ascii.eqlIgnoreCase(s[i..][0..q.len], q)) return true;
    return false;
}

/// The pins this list shows, in pin order: listed and not archived.
pub fn visiblePins(a: *const App, gpa: std.mem.Allocator) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (a.settings.pins.items) |id| if (a.findChat(id)) |ch| if (!ch.archived and listed(a, ch)) out.append(gpa, id) catch {};
    return out.items;
}

fn pinned(pins: []const []const u8, id: []const u8) ?usize {
    for (pins, 0..) |p, i| if (std.mem.eql(u8, p, id)) return i;
    return null;
}

/// A row's slot: its 29 points and the 2 between rows.
pub const row_slot: f32 = 29 + 2;

fn lists(c: *ui.Context, a: *App, k: theme.Colors) void {
    ui.scroll(c, .{ .grow = 1, .width = .fill, .padding = .{ .left = 8, .right = 8, .top = 4, .bottom = 8 }, .gap = 2 });
    defer ui.end(c);
    const drag = @import("view_drag.zig");
    const moving = drag.moving(a);
    const target = drag.sidebarTarget(a);
    const pins = visiblePins(a, c.alloc());
    const source_pin = if (moving) |id| pinned(pins, id) else null;
    var active: usize = 0;
    var archived: usize = 0;
    for (a.chats.items) |ch| if (listed(a, ch)) {
        if (ch.archived) archived += 1 else if (pinned(pins, ch.id) == null) active += 1;
    };
    // Pinned, while there are pins or a session is being dragged.
    if (pins.len > 0 or moving != null) {
        a.view.pin_header = rectOf(c, sectionAt(c, k, "Pinned", pins.len, &a.view.pinned_open));
        if (a.view.pinned_open) {
            const body = ui.div(c).column().wFull().py(4).gap(2);
            defer body.end();
            a.view.pin_rows = rectOf(c, body);
            const gap_at: ?usize = if (target) |t| switch (t) {
                .pinned => |i| if (source_pin == null) i else null,
                .regular => null,
            } else null;
            for (pins, 0..) |id, ix| {
                const ch = a.findChat(id) orelse continue;
                // Rows give way: toward the held row's place among them, or
                // apart for one coming from Sessions.
                var dy: f32 = 0;
                if (source_pin) |from| {
                    if (target) |t| if (t == .pinned) {
                        dy = @as(f32, @floatFromInt(@import("pins.zig").slideOffset(ix, from, @min(t.pinned, pins.len - 1)))) * row_slot;
                    };
                    if (target != null and target.? == .regular and ix > from) dy = -row_slot;
                } else if (gap_at) |g| {
                    if (ix >= g) dy = row_slot;
                }
                const held = source_pin != null and source_pin.? == ix;
                slotRow(c, a, k, ch, dy, held);
            }
            // Room for the row coming in.
            if (gap_at != null) _ = c.leaf(.{ .height = .{ .px = row_slot - 2 } }, .none, null);
            if (pins.len == 0 and gap_at == null) _ = c.leaf(.{ .height = .{ .px = 0 } }, .none, null);
        } else a.view.pin_rows = null;
        _ = c.leaf(.{ .height = .{ .px = 12 - 2 } }, .none, null);
    } else {
        a.view.pin_header = null;
        a.view.pin_rows = null;
    }
    a.view.sessions_header = rectOf(c, sectionAt(c, k, "Sessions", active, &a.view.sessions_open));
    if (a.view.sessions_open) {
        _ = c.leaf(.{ .height = .{ .px = 2 } }, .none, null);
        const body = ui.div(c).column().wFull().gap(2);
        defer body.end();
        a.view.session_rows = rectOf(c, body);
        const unpinning = source_pin != null and target != null and target.? == .regular;
        for (a.chats.items) |ch| if (!ch.archived and listed(a, ch) and pinned(pins, ch.id) == null) {
            const held = moving != null and std.mem.eql(u8, moving.?, ch.id);
            // Dragged to the pins, a session's row leaves the list.
            if (held and target != null and target.? == .pinned) continue;
            slotRow(c, a, k, ch, 0, held);
        };
        if (unpinning) _ = c.leaf(.{ .height = .{ .px = row_slot - 2 } }, .none, null);
        if (active == 0 and moving != null) {
            // While a session is dragged, an empty list takes it back.
            const e = ui.div(c).row().wFull().h(48).px(10).itemsCenter();
            defer e.end();
            ui.text(c, "Drop here to unpin", .{ .size = 12, .line_height = 12 * 1.618, .color = k.muted });
        } else if (active == 0 and pins.len == 0) {
            const e = ui.div(c).row().px(8).py(6);
            defer e.end();
            ui.text(c, if (a.view.search.text().len > 0) "No matching sessions" else "No sessions yet", .{ .size = 12, .color = k.faint });
        }
    } else a.view.session_rows = null;
    if (archived == 0) return;
    _ = c.leaf(.{ .height = .{ .px = 8 } }, .none, null);
    if (section(c, k, "Archived", archived, &a.view.archived_open)) {
        var shown: usize = 0;
        for (a.chats.items) |ch| if (ch.archived and listed(a, ch)) {
            if (shown == a.view.archived_limit) break;
            sessionRow(c, a, k, ch);
            shown += 1;
        };
        if (archived > shown) {
            const more = ui.div(c).row().wFull().h(29).px(8).itemsCenter().rounded(8).hover(k.hover);
            defer more.end();
            if (more.clicked()) a.view.archived_limit += 25;
            ui.text(c, c.print("Show {d} more", .{archived - shown}), .{ .size = 12, .color = k.muted });
        }
    }
}

/// A row, moved `dy` while rows give way; the held one keeps its place
/// empty, drawn instead under the pointer.
fn slotRow(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat, dy: f32, held: bool) void {
    ui.key(c, c.print("slot-{s}", .{ch.id}));
    var w = ui.div(c).column().wFull().offset(0, dy);
    if (held) w = w.opacity(0);
    defer w.end();
    sessionRow(c, a, k, ch);
}

fn rectOf(c: *ui.Context, d: ui.Div) ?ui.Rect {
    return c.rects.get(c.node(d.index).id);
}

/// `section` that hands back its header, for its place as a drop target.
fn sectionAt(c: *ui.Context, k: theme.Colors, label: []const u8, count: usize, open: *bool) ui.Div {
    ui.key(c, label);
    const h = ui.div(c).row().wFull().h(28).px(8).gap(8).itemsCenter().rounded(8);
    if (h.clicked()) open.* = !open.*;
    const color = k.muted.alpha(0.5);
    ui.text(c, if (open.*) label else c.print("{s} ({d})", .{ label, count }), .{ .size = 12, .weight = .medium, .color = color });
    ui.spacer(c);
    icons.icon(c, if (open.*) .@"alt-arrow-down" else .@"alt-arrow-right", 12, color, 0);
    h.end();
    return h;
}

/// A disclosure header ("Sessions", "Archived (12)" when shut); true while open.
fn section(c: *ui.Context, k: theme.Colors, label: []const u8, count: usize, open: *bool) bool {
    ui.key(c, label);
    const h = ui.div(c).row().wFull().h(28).px(8).gap(8).itemsCenter().rounded(8);
    defer h.end();
    if (h.clicked()) open.* = !open.*;
    const color = k.muted.alpha(0.5);
    ui.text(c, if (open.*) label else c.print("{s} ({d})", .{ label, count }), .{ .size = 12, .weight = .medium, .color = color });
    ui.spacer(c);
    icons.icon(c, if (open.*) .@"alt-arrow-down" else .@"alt-arrow-right", 12, color, 0);
    return open.*;
}

/// A row as drawn while it's dragged: the same content, nothing to hover
/// or click (`render_chat_row` with `preview`).
pub fn rowPreview(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat) void {
    const r = ui.div(c).row().wFull().h(29).px(8).gap(4).itemsCenter();
    defer r.end();
    const now = a.nowMs();
    statusSlot(c, k, workspace.markOf(ch, workspace.sessionOf(a.sessions.items, ch.id), now));
    const mark = icons.harnessMark(ch.harness orelse "graff");
    icons.icon(c, mark.name, 13, (mark.brand orelse k.subline).alpha(0.8), 13);
    badge(c, a, k, ch.space_id, false);
    const time = rules.relativeTime(c.alloc().alloc(u8, 16) catch &.{}, now, ch.timeMs());
    const title_w = width - 16 - 16 - 13 * 3 - 4 * 4 - 6 - c.text.width(time, .{ .size = 11 });
    {
        const t = ui.div(c).row().grow().w(0).clip();
        defer t.end();
        kit.fadeText(c, chatLabel(ch), kit.style(c, 13, 17, .{ .color = k.text.alpha(0.8) }), title_w);
    }
    const tm = ui.div(c).row().pl(6);
    defer tm.end();
    ui.text(c, time, .{ .size = 11, .color = k.subline });
}

fn sessionRow(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat) void {
    ui.key(c, c.print("row-{s}", .{ch.id}));
    const selected = a.selected != null and std.mem.eql(u8, a.selected.?, ch.id);
    var r = ui.div(c).row().wFull().h(29).px(8).gap(4).itemsCenter().rounded(8).clip();
    r = if (selected) r.bg(k.selected) else r.hover(k.hover);
    defer r.end();
    // No hover while a session is dragged over the rows.
    const hovered = r.hovered() and !@import("view_drag.zig").dragging(a);
    var archive = false;
    const now = a.nowMs();
    statusSlot(c, k, workspace.markOf(ch, workspace.sessionOf(a.sessions.items, ch.id), now));
    const mark = icons.harnessMark(ch.harness orelse "graff");
    const dim: f32 = if (ch.archived) 0.4 else 0.8;
    icons.icon(c, mark.name, 13, (mark.brand orelse k.subline).alpha(dim), 13);
    badge(c, a, k, ch.space_id, selected or hovered);
    // In the frame's memory: the text is drawn after this returns.
    const time = rules.relativeTime(c.alloc().alloc(u8, 16) catch &.{}, now, ch.timeMs());
    const time_w = if (hovered) 18 else c.text.width(time, .{ .size = 11 });
    const title_w = width - 16 - 16 - 13 * 3 - 4 * 4 - 6 - time_w - (if (hovered) @as(f32, 22) else 0);
    const tc = if (selected or hovered) k.text else if (ch.archived) k.text.alpha(0.55) else k.text.alpha(0.8);
    {
        const t = ui.div(c).row().grow().w(0).clip();
        defer t.end();
        kit.fadeText(c, chatLabel(ch), kit.style(c, 13, 17, .{ .color = tc }), title_w);
    }
    if (hovered) {
        // The archive control takes the remote slot while the pointer is here.
        const b = ui.div(c).row().size(18, 18).center().rounded(4).hover(k.wash(0.10));
        defer b.end();
        if (b.clicked()) archive = true;
        icons.icon(c, .@"archive-minimalistic", 13, k.muted, 0);
    }
    {
        const tm = ui.div(c).row().pl(6);
        defer tm.end();
        if (hovered) {
            icons.icon(c, .@"more-horizontal", 13, k.muted, 18);
        } else {
            ui.text(c, time, .{ .size = 11, .color = k.subline });
        }
    }
    if (archive) return a.setArchived(ch.id, !ch.archived);
    // Pressed, it may be dragged onto the chat to split it; a release that
    // ends a drag isn't a click.
    const drag = @import("view_drag.zig");
    const it = r.interaction();
    if (it.pressed and c.input.pressed) drag.press(c, a, ch.id, it.rect);
    if (r.clicked() and !selected and !drag.dragging(a)) a.openChat(ch.id, ch.space_id);
}

fn statusSlot(c: *ui.Context, k: theme.Colors, mark: workspace.Mark) void {
    const s = ui.div(c).row().size(13, 13).center();
    defer s.end();
    switch (mark) {
        .working => kit.snake(c, k),
        .completed => icons.icon(c, .check, 11, k.success.alpha(0.9), 0),
        .awaiting_input => kit.dot(c, 6, k.accent.alpha(0.6)),
        .errored => kit.dot(c, 6, k.danger.alpha(0.65)),
        .idle => kit.dot(c, 6, k.ink(0.14)),
    }
}

/// The project's monogram tile (`project_icon.rs`).
pub fn badge(c: *ui.Context, a: *const App, k: theme.Colors, space_id: ?[]const u8, lit: bool) void {
    const space = a.findSpace(space_id);
    const m = rules.monogram(if (space) |s| s.name else "Home", if (space) |s| s.path else null, k.dark);
    const tile = ui.div(c).row().size(13, 13).center().rounded(3).bg(k.tone.alpha(if (lit) 0.24 else 0.08));
    defer tile.end();
    const letter = if (lit) (if (k.dark) m.color.mix(.{ .r = 1, .g = 1, .b = 1 }, 0.25) else m.color.mix(.{}, 0.2)) else m.color.alpha(0.85);
    ui.text(c, c.print("{c}", .{m.letter}), .{ .size = 9, .weight = .medium, .mono = true, .color = letter });
}

/// A chat's name: its title, else its first prompt, else "New session".
pub fn chatLabel(ch: workspace.Chat) []const u8 {
    if (ch.title) |t| if (t.len > 0) return firstLine(t);
    if (ch.preview) |p| if (p.len > 0) return firstLine(p);
    return "New session";
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

fn footer(c: *ui.Context, a: *App, k: theme.Colors) void {
    const f = ui.div(c).row().wFull().p(8);
    defer f.end();
    var b = ui.div(c).row().size(21, 21).center().roundedFull();
    b = if (a.view.account_menu) b.bg(k.hover) else b.hover(k.hover.alpha(k.hover.a * 0.8));
    defer b.end();
    if (b.clicked()) {
        a.view.account_menu = !a.view.account_menu;
        // Opening asks the Codegraff sign-in again.
        if (a.view.account_menu) @import("app_account.zig").refresh(a);
    }
    if (c.rects.get(c.node(b.index).id)) |r| a.view.account_anchor = r;
    const av = ui.div(c).row().size(13, 13).center().roundedFull().bg(k.text);
    defer av.end();
    const acc = &a.account;
    const letter = @import("app_account.zig").initial(@import("app_account.zig").menu(acc.scope, acc.user, acc.codegraff).line);
    ui.text(c, c.print("{c}", .{letter}), .{ .size = 9, .weight = .semibold, .mono = true, .color = k.shell });
}
