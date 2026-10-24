//! The window, laid out as Harness's: the sidebar of spaces and their chats
//! on the left, the open chat on the right (its transcript, then the
//! composer).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const workspace = @import("workspace.zig");
const transcript_view = @import("view_transcript.zig");
const picker = @import("view_picker.zig");
const App = @import("app.zig").App;

const sidebar_w = 264;
/// The hidden title bar's height: the traffic lights sit in it.
const title_h = 40;

pub fn view(a: *App, c: *ui.Context) void {
    const dark = a.dark orelse nanoui.isDark();
    c.theme = theme.ui(dark);
    const k = theme.colors(dark);
    if (a.tick(c.time)) |wait| c.frameIn(wait);
    c.title_bar_height = title_h;
    keys(c, a);
    const root = ui.div(c).row().sizeFull().bg(k.background);
    defer root.end();
    sidebar(c, a, k);
    _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = k.border }, .none, null);
    const main = ui.div(c).column().grow().w(0).hFull().clip();
    defer main.end();
    header(c, a, k);
    transcript_view.transcript(c, a, k);
    composer(c, a, k);
}

/// ⌘N starts a new chat; ⌘↩ sends; Escape closes a picker.
fn keys(c: *ui.Context, a: *App) void {
    if (c.shortcut(.{ .key = ui.Shortcut.escape })) a.picker = .none;
    if (c.shortcut(.{ .key = 'n', .cmd = true })) a.select(null, null);
    if (c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true })) a.send();
}

fn sidebar(c: *ui.Context, a: *App, k: theme.Colors) void {
    const side = ui.div(c).column().w(sidebar_w).hFull().bg(k.shell).pt(title_h).pb(10).gap(2);
    defer side.end();
    {
        const top = ui.div(c).row().wFull().px(14).pb(8).gap(8).itemsCenter();
        defer top.end();
        ui.text(c, "Harness", .{ .size = 15, .weight = .semibold, .color = k.text });
        ui.spacer(c);
        connection(c, a, k);
    }
    {
        const pad = ui.div(c).column().wFull().px(8).pb(6);
        defer pad.end();
        var row = ui.div(c).row().wFull().px(10).py(7).gap(8).itemsCenter().rounded(7).hover(k.hover);
        if (a.selected == null) row = row.bg(k.selected);
        defer row.end();
        if (row.clicked()) a.select(null, null);
        ui.icon(c, "square.and.pencil", .{ .size = 13, .frame = 16, .color = k.muted });
        ui.text(c, "New chat", .{ .color = k.text });
    }
    {
        const pad = ui.div(c).column().wFull().px(8).pb(6);
        defer pad.end();
        const row = ui.div(c).row().wFull().px(10).py(7).gap(8).itemsCenter().rounded(7).hover(k.hover);
        defer row.end();
        if (row.clicked()) a.addFolder();
        ui.icon(c, "folder.badge.plus", .{ .size = 13, .frame = 16, .color = k.muted });
        ui.text(c, "Add folder", .{ .color = k.text });
    }
    ui.scroll(c, .{ .grow = 1, .width = .fill, .padding = .xy(8, 0), .gap = 2 });
    defer ui.end(c);
    for (a.spaces.items) |s| {
        ui.key(c, c.print("space-{s}", .{s.id}));
        spaceHeader(c, a, k, s);
        for (a.chats.items) |chat| {
            if (chat.archived) continue;
            const in = chat.space_id != null and std.mem.eql(u8, chat.space_id.?, s.id);
            if (in) chatRow(c, a, k, chat);
        }
    }
    var others = false;
    for (a.chats.items) |chat| {
        if (chat.archived or a.findSpace(chat.space_id) != null) continue;
        if (!others) {
            others = true;
            sectionLabel(c, k, "Chats");
        }
        chatRow(c, a, k, chat);
    }
    if (a.engine.state == .connected and a.spaces.items.len == 0 and a.chats.items.len == 0)
        ui.text(c, "No chats yet.", .{ .size = 12, .color = k.muted });
    footer(c, a, k);
}

fn footer(c: *ui.Context, a: *App, k: theme.Colors) void {
    const v = a.release.version() orelse return;
    const row = ui.div(c).row().wFull().px(10).pt(12);
    defer row.end();
    ui.text(c, c.print("Latest release: {s}", .{v}), .{ .size = 11, .color = k.faint });
}

fn connection(c: *ui.Context, a: *App, k: theme.Colors) void {
    const color, const label = switch (a.engine.state) {
        .connected => .{ k.success, "Engine" },
        .connecting => .{ k.warning, "Connecting" },
        .disconnected => .{ k.danger, "No engine" },
    };
    ui.text(c, label, .{ .size = 11, .color = k.muted });
    _ = c.leaf(.{ .width = .{ .px = 7 }, .height = .{ .px = 7 }, .radius = 3.5, .background = color }, .none, null);
}

fn sectionLabel(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    const row = ui.div(c).row().wFull().px(10).pt(12).pb(4);
    defer row.end();
    ui.text(c, label, .{ .size = 11, .weight = .semibold, .color = k.faint });
}

fn spaceHeader(c: *ui.Context, a: *App, k: theme.Colors, s: workspace.Space) void {
    const row = ui.div(c).row().wFull().px(10).pt(12).pb(4).gap(6).itemsCenter();
    defer row.end();
    ui.icon(c, "folder", .{ .size = 11, .frame = 14, .color = k.faint });
    ui.text(c, s.name, .{ .size = 11, .weight = .semibold, .color = k.faint });
    ui.spacer(c);
    const plus = ui.div(c).row().px(4).py(2).rounded(4).hover(k.hover);
    defer plus.end();
    if (plus.clicked()) a.select(null, s.id);
    ui.icon(c, "plus", .{ .size = 11, .frame = 14, .color = k.faint });
}

fn chatRow(c: *ui.Context, a: *App, k: theme.Colors, chat: workspace.Chat) void {
    ui.key(c, c.print("chat-{s}", .{chat.id}));
    const selected = a.selected != null and std.mem.eql(u8, a.selected.?, chat.id);
    var row = ui.div(c).row().wFull().px(10).py(6).gap(8).itemsCenter().rounded(7).clip();
    row = if (selected) row.bg(k.selected) else row.hover(k.hover);
    defer row.end();
    if (row.clicked() and !selected) a.select(chat.id, chat.space_id);
    const status = workspace.statusOf(a.sessions.items, chat.id);
    const dot = switch (status) {
        .working => k.accent,
        .awaiting_input => k.warning,
        .errored => k.danger,
        .idle => k.faint.alpha(0.0),
    };
    _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 3, .background = dot }, .none, null);
    ui.text(c, chatTitle(chat), .{ .size = 13, .color = if (selected) k.text else k.text.alpha(0.85) });
}

pub fn chatTitle(chat: workspace.Chat) []const u8 {
    if (chat.title) |t| if (t.len > 0) return firstLine(t);
    if (chat.preview) |p| if (p.len > 0) return firstLine(p);
    return "New chat";
}

fn firstLine(s: []const u8) []const u8 {
    const line = s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
    return line[0..@min(line.len, 80)];
}

fn header(c: *ui.Context, a: *App, k: theme.Colors) void {
    const bar = ui.div(c).row().wFull().h(title_h + 4).px(20).gap(10).itemsCenter();
    defer bar.end();
    const chat = if (a.selected) |id| a.findChat(id) else null;
    if (chat) |ch| {
        ui.text(c, chatTitle(ch), .{ .size = 14, .weight = .semibold, .color = k.text });
        if (ch.harness) |h| ui.badge(c, if (ch.model) |m| c.print("{s} · {s}", .{ h, m }) else h, k.muted);
    } else {
        ui.text(c, "New chat", .{ .size = 14, .weight = .semibold, .color = k.text });
        if (a.findSpace(a.space) orelse if (a.spaces.items.len > 0) a.spaces.items[0] else null) |s|
            ui.badge(c, s.name, k.muted);
    }
    ui.spacer(c);
    if (a.transcript.window) |w| if (a.transcript.tokens) |t|
        ui.textf(c, .{ .size = 11, .color = k.faint, .mono = true }, "{d}% of context", .{t * 100 / @max(w, 1)});
}

fn composer(c: *ui.Context, a: *App, k: theme.Colors) void {
    const outer = ui.div(c).column().wFull().px(20).pb(16).gap(6);
    defer outer.end();
    if (a.selected == null) picker.list(c, a, k) else a.picker = .none;
    const frame = ui.div(c).column().wFull().bg(k.card).border(k.border).borderW(1).rounded(12).px(12).pt(10).pb(8).gap(8);
    defer frame.end();
    const r = ui.textField(c, &a.composer, .{
        .placeholder = if (a.engine.state == .connected) "Ask anything" else "Waiting for the engine…",
        .width = .fill,
        .bare = true,
        .multiline = true,
        .max_lines = 10,
    });
    if (r.submitted) a.send();
    const row = ui.div(c).row().wFull().gap(8).itemsCenter();
    defer row.end();
    if (a.selected == null) picker.buttons(c, a, k);
    if (a.noticeText()) |n| ui.text(c, n, .{ .size = 11, .color = k.danger }) else ui.text(c, "Return to send · Shift-Return for a new line", .{ .size = 11, .color = k.faint });
    ui.spacer(c);
    const working = a.selectedStatus() == .working;
    if (working and ui.button(c, "Stop", .{ .variant = .secondary, .size = 12, .icon = "stop.fill" }).clicked) a.interrupt();
    const empty = std.mem.trim(u8, a.composer.text(), " \n\t").len == 0;
    if (ui.button(c, "Send", .{ .variant = .primary, .size = 12, .disabled = empty or a.engine.state != .connected }).clicked) a.send();
}
