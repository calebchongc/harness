//! The sidebar, as the GPUI shell lays it out (crates/ui/src/shell.rs,
//! shell/chat_tabs.rs, shell/spaces.rs): the open tabs, the project filter
//! with search and view options, then Sessions and Archived, each row a
//! status mark, the agent's mark, the project's monogram, a fading title
//! and how long ago; a running cloud sandbox's strip and the account badge
//! at the foot.
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
    // The edge is drawn over its last column (view.zig), as the GPUI app's.
    const side = ui.div(c).column().w(width).hFull().bg(k.sidebar).pt(titlebar_h);
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
            // The number sits at the slot's left; ✕ is centred in it.
            const slot = ui.div(c).row().size(16, 16).itemsCenter().rounded(4);
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
    const menus = @import("view_sidebar_menus.zig");
    const row = ui.div(c).row().wFull().px(8).pt(8).pb(4).gap(4).itemsCenter();
    defer row.end();
    {
        var t = ui.div(c).row().grow().h(29).px(8).gap(8).itemsCenter().rounded(8).clip();
        t = if (a.view.filter_menu) t.bg(k.hover) else t.hover(k.hover);
        defer t.end();
        if (t.clicked()) if (a.view.filter_menu) menus.close(a) else menus.openProjects(a);
        if (c.rects.get(c.node(t.index).id)) |r| a.view.filter_anchor = r;
        icons.icon(c, .folder, 16, k.muted, 0);
        const color = if (t.hovered() or a.view.filter_menu) k.text else k.text.alpha(0.8);
        // The trigger less its insets, icon, chevron and gaps.
        const room = width - 16 - 2 * 29 - 2 * 4 - 16 - 16 - 14 - 2 * 8;
        if (a.findSpace(a.view.filter)) |s| {
            // The project, "@ device" after it, and the offline mark.
            const tag = c.print("@ {s}", .{a.deviceName(s.device_id)});
            const off = !menus.online(a, s.device_id, a.nowMs());
            const tag_w = @min(c.text.width(tag, .{ .size = 10 }), room / 2);
            const name_w = @min(c.text.width(s.name, .{ .size = 13, .weight = .medium }), room - tag_w - 6 - (if (off) @as(f32, 18) else 0));
            const box = ui.div(c).row().grow().w(0).gap(6).itemsCenter().clip();
            defer box.end();
            kit.fadeText(c, s.name, .{ .size = 13, .weight = .medium, .color = color }, name_w);
            kit.fadeText(c, tag, .{ .size = 10, .color = k.muted.alpha(0.45) }, tag_w);
            if (off) icons.icon(c, .@"wifi-off", 12, k.warning.alpha(0.8), 0);
        } else {
            kit.fadeText(c, "All projects", .{ .size = 13, .weight = .medium, .color = color }, room);
            ui.spacer(c);
        }
        icons.icon(c, .@"alt-arrow-down", 14, k.muted.alpha(0.6), 0);
    }
    // The magnifier, accent while the search is open (`render_sidebar_search_trigger`).
    if (kit.iconButton(c, k, .magnifer, .{ .size = 29, .radius = 8, .icon = 16, .color = if (a.view.search_open) k.accent else k.muted, .on = a.view.search_open })) {
        menus.close(a);
        a.view.search_open = !a.view.search_open;
        if (!a.view.search_open) a.view.search.clear();
    }
    const more = ui.div(c).row();
    defer more.end();
    if (kit.iconButton(c, k, .@"more-horizontal", .{ .size = 29, .radius = 8, .icon = 16, .color = k.muted.alpha(0.6), .on = a.view.more_menu }))
        if (a.view.more_menu) menus.close(a) else menus.openView(a);
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
    // A filter on a project that's gone shows them all, as its label does.
    if (a.view.filter) |f| if (a.findSpace(f) != null) if (chat.space_id == null or !std.mem.eql(u8, chat.space_id.?, f)) return false;
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
            const body = ui.div(c).column().wFull().pt(2).pb(4).gap(2);
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
        // Groups bring their own 12 above them.
        if (a.settings.organization() == .in_one_list) _ = c.leaf(.{ .height = .{ .px = 12 - 2 } }, .none, null);
    } else {
        a.view.pin_header = null;
        a.view.pin_rows = null;
    }
    if (a.settings.organization() != .in_one_list) {
        groups(c, a, k, pins, moving);
    } else regular: {
    a.view.sessions_header = rectOf(c, sectionAt(c, k, "Sessions", active, &a.view.sessions_open));
    if (!a.view.sessions_open) {
        a.view.session_rows = null;
        break :regular;
    }
        // SIDEBAR_DISCLOSURE_BODY_INSET: 4 under the header, the list's 2 twice.
        _ = c.leaf(.{ .height = .{ .px = 0 } }, .none, null);
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
    }
    // Show › Archived off: no shelf.
    if (archived == 0 or !a.settings.get(.sidebar_show_archived)) return;
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

/// By project or by device (`sidebar_organization`): a disclosure for
/// each, in the order their newest sessions come; this device's first.
fn groups(c: *ui.Context, a: *App, k: theme.Colors, pins: []const []const u8, moving: ?[]const u8) void {
    const by_project = a.settings.organization() == .by_project;
    const gpa = c.alloc();
    var keys: std.ArrayList([]const u8) = .empty;
    for (a.chats.items) |ch| if (!ch.archived and listed(a, ch) and pinned(pins, ch.id) == null) {
        const key = groupKey(c, ch, by_project);
        for (keys.items) |have| {
            if (std.mem.eql(u8, have, key)) break;
        } else keys.append(gpa, key) catch {};
    };
    if (!by_project) if (a.device_id) |me| for (keys.items, 0..) |key, i| if (std.mem.eql(u8, key, me)) {
        std.mem.copyBackwards([]const u8, keys.items[1 .. i + 1], keys.items[0..i]);
        keys.items[0] = me;
        break;
    };
    a.view.sessions_header = null;
    a.view.session_rows = null;
    for (keys.items) |key| {
        ui.key(c, c.print("group-{s}", .{key}));
        // `SIDEBAR_SECTION_GAP` above each, past the list's 2 between them.
        const box = ui.div(c).column().wFull().pt(12);
        defer box.end();
        var count: usize = 0;
        for (a.chats.items) |ch| if (!ch.archived and listed(a, ch) and pinned(pins, ch.id) == null and std.mem.eql(u8, groupKey(c, ch, by_project), key)) {
            count += 1;
        };
        const collapse = c.print("{s}:{s}", .{ if (by_project) "project" else "device", key });
        const open = a.view.groupOpen(collapse, true);
        const label = if (by_project)
            (if (std.mem.startsWith(u8, key, "home:")) "~" else if (a.findSpace(key)) |sp| sp.name else "?")
        else
            a.deviceName(key);
        {
            const h = ui.div(c).row().wFull().h(28).px(8).gap(8).itemsCenter();
            defer h.end();
            if (h.clicked()) a.view.toggleGroup(a.gpa, collapse, true);
            const color = k.muted.alpha(0.5);
            ui.text(c, if (open) label else c.print("{s} ({d})", .{ label, count }), .{ .size = 12, .weight = .medium, .color = color });
            ui.spacer(c);
            icons.icon(c, if (open) .@"alt-arrow-down" else .@"alt-arrow-right", 12, color, 0);
        }
        if (!open) continue;
        const body = ui.div(c).column().wFull().pt(4).gap(2);
        defer body.end();
        for (a.chats.items) |ch| if (!ch.archived and listed(a, ch) and pinned(pins, ch.id) == null and std.mem.eql(u8, groupKey(c, ch, by_project), key)) {
            const held = moving != null and std.mem.eql(u8, moving.?, ch.id);
            slotRow(c, a, k, ch, 0, held);
        };
    }
}

/// A session's group: its project (or its device's home), or its device.
fn groupKey(c: *ui.Context, ch: workspace.Chat, by_project: bool) []const u8 {
    if (by_project) return ch.space_id orelse c.print("home:{s}", .{ch.device_id orelse ""});
    return ch.device_id orelse "";
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

/// What the ⋯ menu's Show and Compact ask of every row.
const Look = struct {
    compact: bool,
    harness: bool,
    icon: bool,
    label: bool,
    branch: bool,

    fn of(a: *const App) Look {
        const s = &a.settings;
        return .{
            .compact = s.get(.sidebar_compact),
            .harness = s.get(.sidebar_show_harness),
            .icon = s.get(.sidebar_show_project_icon),
            .label = s.get(.sidebar_show_project_label),
            .branch = s.get(.sidebar_show_branch),
        };
    }

    /// The marks before a compact row's title, and their gaps.
    fn marksW(l: Look) f32 {
        return 13 + 4 + (if (l.harness) @as(f32, 17) else 0) + (if (l.icon) @as(f32, 17) else 0);
    }
};

/// A row's height (`sidebar_row_height`): 29 compact; else 45 with its
/// "project @ device" line, 16 more with its branch's.
pub fn rowHeight(a: *const App, ch: workspace.Chat) f32 {
    const l = Look.of(a);
    if (l.compact) return 29;
    const branch = l.branch and ch.branch != null;
    return (if (branch) @as(f32, 61) else 45) - (if (l.label) @as(f32, 0) else 16);
}

/// A row as drawn while it's dragged: the same content, nothing to hover
/// or click (`render_chat_row` with `preview`).
pub fn rowPreview(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat) void {
    const l = Look.of(a);
    if (!l.compact) {
        const r = ui.div(c).column().wFull().h(rowHeight(a, ch)).px(8).py(6).gap(2);
        defer r.end();
        return expandedLines(c, a, k, ch, l, false, false);
    }
    const r = ui.div(c).row().wFull().h(29).px(8).pt(6).pb(5).gap(4).itemsCenter();
    defer r.end();
    const now = a.nowMs();
    statusSlot(c, k, workspace.markOf(ch, workspace.sessionOf(a.sessions.items, ch.id), now));
    marks(c, a, k, ch, l, false);
    const time = rules.relativeTime(c.alloc().alloc(u8, 16) catch &.{}, now, ch.timeMs());
    const title_w = width - 16 - 16 - l.marksW() - 4 - 6 - c.text.width(time, .{ .size = 11 });
    {
        const t = ui.div(c).row().grow().w(0).clip();
        defer t.end();
        kit.fadeText(c, chatLabel(ch), kit.style(c, 13, 17, .{ .color = k.text.alpha(0.8) }), title_w);
    }
    const tm = ui.div(c).row().pl(6);
    defer tm.end();
    ui.text(c, time, .{ .size = 11, .color = k.subline });
}

/// The harness's mark and the project's monogram, as Show has them.
fn marks(c: *ui.Context, a: *const App, k: theme.Colors, ch: workspace.Chat, l: Look, lit: bool) void {
    const muted = ch.archived and !lit;
    if (l.harness) {
        const mark = icons.harnessMark(ch.harness orelse "graff");
        icons.icon(c, mark.name, 13, (mark.brand orelse k.subline).alpha(if (muted) 0.4 else 0.8), 13);
    }
    if (l.icon) {
        const b = ui.div(c).row().opacity(if (muted) 0.4 else 1);
        defer b.end();
        badge(c, a, k, ch.space_id, lit);
    }
}

/// On another device: the compact row's corner says so.
fn remote(a: *const App, ch: workspace.Chat) bool {
    const mine = a.device_id orelse return false;
    const dev = ch.device_id orelse return false;
    return !std.mem.eql(u8, mine, dev);
}

/// "project @ device" (`sidebar_chat_data`): "~" for no project, and no
/// device when it isn't known.
fn folderLabel(c: *ui.Context, a: *const App, ch: workspace.Chat) []const u8 {
    const project = if (a.findSpace(ch.space_id)) |s| s.name else if (ch.space_id == null) "~" else "?";
    const dev = ch.device_id orelse return project;
    for (a.devices.items) |d| if (std.mem.eql(u8, d.id, dev)) return c.print("{s} @ {s}", .{ project, d.name });
    return project;
}

/// The expanded row's lines: "project @ device" with the status or time,
/// the marks and title, then the branch.
fn expandedLines(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat, l: Look, lit: bool, hovered: bool) void {
    const inner = width - 16 - 16;
    const subline = k.subline;
    var archive = false;
    if (l.label) {
        const line = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer line.end();
        const corner_w = cornerWidth(c, a, ch, hovered);
        {
            const t = ui.div(c).row().grow().w(0).clip();
            defer t.end();
            kit.fadeText(c, folderLabel(c, a, ch), .{ .size = 11, .line_height = 14, .color = subline }, inner - 8 - corner_w);
        }
        archive = corner(c, a, k, ch, hovered);
    }
    {
        const line = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer line.end();
        marks(c, a, k, ch, l, lit);
        const marks_w = (if (l.harness) @as(f32, 21) else 0) + (if (l.icon) @as(f32, 21) else 0);
        const corner_w = if (l.label) 0 else cornerWidth(c, a, ch, hovered) + 8;
        const tc = if (lit) k.text else if (ch.archived) k.text.alpha(0.55) else k.text.alpha(0.8);
        {
            const t = ui.div(c).row().grow().w(0).clip();
            defer t.end();
            kit.fadeText(c, chatLabel(ch), kit.style(c, 13, 17, .{ .color = tc }), inner - marks_w - corner_w);
        }
        if (!l.label) archive = corner(c, a, k, ch, hovered);
    }
    if (l.branch) if (ch.branch) |b| {
        const line = ui.div(c).row().wFull().gap(4).itemsCenter();
        defer line.end();
        icons.icon(c, .@"git-branch", 11, subline, 0);
        kit.fadeText(c, b, .{ .size = 11, .line_height = 14, .color = subline }, inner - 15);
    };
    if (archive) a.setArchived(ch.id, !ch.archived);
}

fn cornerWidth(c: *ui.Context, a: *const App, ch: workspace.Chat, hovered: bool) f32 {
    const st: ui.TextStyle = .{ .size = 10, .weight = .medium };
    if (hovered) return 4 + 11 + 4 + c.text.width(if (ch.archived) "Unarchive" else "Archive", st);
    const word = statusWord(workspace.markOf(ch, workspace.sessionOf(a.sessions.items, ch.id), a.nowMs()));
    if (word) |w| return 6 + 4 + c.text.width(w, st);
    return c.text.width(rules.relativeTime(c.alloc().alloc(u8, 16) catch &.{}, a.nowMs(), ch.timeMs()), st);
}

fn statusWord(mark: workspace.Mark) ?[]const u8 {
    return switch (mark) {
        .working => "Working",
        .awaiting_input => "Input",
        .errored => "Failed",
        .completed => "Done",
        .idle => null,
    };
}

/// The expanded row's corner: its status in words, or how long ago;
/// Archive under the pointer (true when clicked).
fn corner(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat, hovered: bool) bool {
    const box = ui.div(c).row().h(14).itemsCenter();
    defer box.end();
    if (hovered) {
        const b = ui.div(c).row().h(18).px(4).gap(4).itemsCenter().rounded(5).bg(k.wash(0.10)).hover(k.wash(0.18)).offset(4, 0);
        defer b.end();
        icons.icon(c, if (ch.archived) .@"archive-up-minimalistic" else .@"archive-minimalistic", 11, k.muted, 0);
        ui.text(c, if (ch.archived) "Unarchive" else "Archive", .{ .size = 10, .color = k.muted });
        return b.clicked();
    }
    const now = a.nowMs();
    const mark = workspace.markOf(ch, workspace.sessionOf(a.sessions.items, ch.id), now);
    if (statusWord(mark)) |word| {
        const color = switch (mark) {
            .completed => k.success.alpha(0.9),
            .awaiting_input => k.accent,
            .errored => k.danger,
            else => k.muted,
        };
        const g = ui.div(c).row().gap(4).itemsCenter();
        defer g.end();
        switch (mark) {
            .working => kit.snake(c, k),
            .completed => icons.icon(c, .check, 11, color, 0),
            else => kit.dot(c, 6, color),
        }
        ui.text(c, word, .{ .size = 10, .weight = .medium, .color = color });
        return false;
    }
    ui.text(c, rules.relativeTime(c.alloc().alloc(u8, 16) catch &.{}, now, ch.timeMs()), .{ .size = 10, .weight = .medium, .color = k.subline });
    return false;
}

fn sessionRow(c: *ui.Context, a: *App, k: theme.Colors, ch: workspace.Chat) void {
    ui.key(c, c.print("row-{s}", .{ch.id}));
    const selected = a.selected != null and std.mem.eql(u8, a.selected.?, ch.id);
    const l = Look.of(a);
    // 6 above an 18-point line, as `render_chat_row`'s `py(6)` column.
    var r = if (l.compact)
        ui.div(c).row().wFull().h(29).px(8).pt(6).pb(5).gap(4).itemsCenter().rounded(8).clip()
    else
        ui.div(c).column().wFull().h(rowHeight(a, ch)).px(8).py(6).gap(2).rounded(8).clip();
    r = if (selected) r.bg(k.selected) else r.hover(k.hover);
    defer r.end();
    // No hover while a session is dragged over the rows.
    // Its menu open, the row stays as hovered: the menu's backdrop takes
    // the pointer, but the GPUI app's row keeps its actions shown.
    const menu_here = a.view.chat_menu.open and std.mem.eql(u8, a.view.chat_menu.id.items, ch.id);
    const hovered = (r.hovered() or menu_here) and !@import("view_drag.zig").dragging(a);
    var archive = false;
    var menu = false;
    const now = a.nowMs();
    if (!l.compact) {
        expandedLines(c, a, k, ch, l, selected or hovered, hovered);
    } else {
        statusSlot(c, k, workspace.markOf(ch, workspace.sessionOf(a.sessions.items, ch.id), now));
        marks(c, a, k, ch, l, selected or hovered);
        // In the frame's memory: the text is drawn after this returns.
        const time = rules.relativeTime(c.alloc().alloc(u8, 16) catch &.{}, now, ch.timeMs());
        const time_w = if (hovered) 18 else c.text.width(time, .{ .size = 11 });
        const far = remote(a, ch);
        const title_w = width - 16 - 16 - l.marksW() - 4 - 6 - time_w - (if (hovered or far) @as(f32, 22) else 0);
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
            icons.icon(c, if (ch.archived) .@"archive-up-minimalistic" else .@"archive-minimalistic", 13, k.muted, 0);
        } else if (far) {
            const b = ui.div(c).row().size(18, 14).center();
            defer b.end();
            icons.icon(c, .@"remote-server", 13, k.muted.alpha(0.5), 0);
        }
        {
            const tm = ui.div(c).row().pl(6);
            defer tm.end();
            if (hovered) {
                // The session menu (`{row}-menu`): opens where it's clicked.
                const m = ui.div(c).row().size(18, 18).center().rounded(4).hover(k.wash(0.10));
                defer m.end();
                if (m.clicked()) menu = true;
                icons.icon(c, .@"more-horizontal", 13, k.muted, 0);
            } else {
                ui.text(c, time, .{ .size = 11, .color = k.subline });
            }
        }
    }
    // A right-click opens the same menu where it's clicked.
    if (kit.secondaryClicked(r)) menu = true;
    if (archive) return a.setArchived(ch.id, !ch.archived);
    if (menu) return @import("view_chat_menu.zig").open(a, ch.id, c.input.mouse);
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
    // The project's own tone (`project_icon::monogram`), its letter's
    // lightness raised (lowered, in light) when the row is lit.
    const tile = ui.div(c).row().size(13, 13).center().rounded(3).bg(m.color.alpha(if (lit) 0.24 else 0.08));
    defer tile.end();
    const letter = if (lit) rules.shiftLightness(m.color, if (k.dark) 0.12 else -0.10, 0.15, 0.95) else m.color.alpha(0.85);
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
    // A running cloud sandbox is billed until it is turned off: always in
    // view, above the account badge.
    @import("view_sandbox_strip.zig").strip(c, a, k, 0);
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
