//! The window, laid out as Harness's (crates/ui/src/shell.rs): the sidebar
//! on the left, the open chat on the right with its header in the title
//! bar's row, and over both the title bar's buttons: the sidebar toggle,
//! back and forward through the tabs, and a new tab. A split tab shows its
//! panes side by side (⌘D) or stacked (⌘⇧D), each its share of the column.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const sidebar = @import("view_sidebar.zig");
const transcript_view = @import("view_transcript.zig");
const tabs = @import("tabs.zig");
const settings_view = @import("view_settings.zig");
const App = @import("app.zig").App;

/// Where the title bar's buttons start: right of the traffic lights.
const cluster_x: f32 = 88;
/// Three 24-point buttons, 8 then 2 points apart.
const cluster_w: f32 = 24 * 3 + 8 + 2;

pub fn view(a: *App, c: *ui.Context) void {
    const dark = a.dark orelse nanoui.isDark();
    c.theme = theme.ui(dark);
    const k = theme.colors(dark);
    a.ansi = k.ansi;
    if (a.tick(c.time)) |wait| c.frameIn(wait);
    c.title_bar_height = sidebar.titlebar_h;
    keys(c, a);
    a.syncPeers();
    {
        const root = ui.div(c).row().sizeFull().bg(k.shell);
        defer root.end();
        if (a.view.settings_open) {
            settings_view.nav(c, a, k);
            _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = k.border }, .none, null);
        } else if (a.view.sidebar_open) {
            sidebar.sidebar(c, a, k);
            _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = k.border }, .none, null);
        }
        const main = ui.div(c).row().grow().w(0).hFull();
        defer main.end();
        column: {
            const chat = ui.div(c).column().grow().w(0).hFull().clip();
            defer chat.end();
            if (a.view.settings_open) {
                _ = c.leaf(.{ .width = .fill, .height = .{ .px = sidebar.titlebar_h } }, .none, null);
                settings_view.page(c, a, k);
                break :column;
            }
            header(c, a, k);
            if (a.tabs.layout()) |s| if (!s.zoomed) {
                panes(c, a, k, s);
            } else focused(c, a, k) else focused(c, a, k);
        }
        if (a.selected != null and a.panels.host_open) {
            _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = k.border }, .none, null);
            @import("view_host.zig").host(c, a, k);
        }
        if (a.selected != null and a.panels.files_open) {
            _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = k.border }, .none, null);
            @import("view_files.zig").explorer(c, a, k);
        }
    }
    titlebar(c, a, k);
    trailing(c, a, k);
    @import("view_diffs.zig").overlays(c, a, k);
    @import("view_actions.zig").overlays(c, a, k);
    @import("view_menus.zig").menus(c, a, k);
    @import("view_picker.zig").popover(c, a, k);
}

/// The focused pane: its chat's transcript over the composer, or a new
/// chat's page.
fn focused(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (a.selected == null) {
        @import("view_newchat.zig").canvas(c, a, k);
    } else {
        transcript_view.transcript(c, a, k);
        @import("view_composer.zig").docked(c, a, k);
        @import("view_actions.zig").dock(c, a, k);
    }
}

/// A split's panes along its axis, each its share of the column; the
/// focused one is the tab's chat, the others its neighbors, read only
/// (`render_chat_split`, shell/chat_split.rs).
fn panes(c: *ui.Context, a: *App, k: theme.Colors, s: *tabs.Split) void {
    const across = s.axis == .horizontal;
    var box = ui.div(c).grow().wFull().h(0);
    box = if (across) box.row() else box.column();
    defer box.end();
    const total: f32 = if (across) transcript_view.mainWidth(c, a) else c.size.h - sidebar.titlebar_h;
    var focus: ?usize = null;
    for (s.panes.items, s.shares.items, 0..) |chat, share, ix| {
        ui.key(c, c.print("pane-{d}", .{ix}));
        if (ix > 0) divider(c, a, k, ix, across, total);
        const size = @max(0, total * share - 1);
        var pane = ui.div(c).column().clip();
        pane = if (across) pane.w(size).hFull() else pane.h(size).wFull();
        defer pane.end();
        if (ix == s.focus) {
            focused(c, a, k);
            continue;
        }
        if (pane.clicked()) focus = ix;
        if (neighbor(c, a, k, ix, chat, size)) return;
    }
    if (focus) |ix| a.focusPane(ix);
}

/// The line between two panes, and a 9-point grip on it: drag to share
/// the room differently, double-click to make them even
/// (`render_split_divider`).
fn divider(c: *ui.Context, a: *App, k: theme.Colors, ix: usize, across: bool, total: f32) void {
    const dragging = if (a.pane_drag) |d| d.divider == ix else false;
    var line = ui.div(c).bg(if (dragging) k.accent.alpha(0.7) else k.border);
    line = if (across) line.w(1).hFull() else line.h(1).wFull();
    defer line.end();
    var grip = ui.div(c).absolute();
    grip = if (across) grip.offset(-4, 0).w(9).hFull() else grip.offset(0, -4).h(9).wFull();
    defer grip.end();
    const it = grip.interaction();
    if (it.hovered or it.pressed) c.cursor = if (across) .resize_left_right else .resize_up_down;
    const at = if (across) c.input.mouse.x else c.input.mouse.y;
    if (it.double_clicked) {
        a.pane_drag = null;
        return a.tabs.equalize();
    }
    if (it.pressed) {
        if (a.pane_drag == null) {
            var d: tabs.Drag = .{ .divider = ix, .origin = at, .start = @splat(0) };
            const sh = a.tabs.layout().?.shares.items;
            @memcpy(d.start[0..sh.len], sh);
            a.pane_drag = d;
        }
        if (a.pane_drag) |d| if (d.divider == ix) a.tabs.dragDivider(d, (at - d.origin) / @max(total, 1));
    } else if (dragging) a.pane_drag = null;
}

/// A pane other than the focused one (`render_peer_chat_pane`): its title
/// and a ✕ that closes it, over its chat's transcript, dimmed; or, empty,
/// where a click starts a chat. True when the ✕ closed it.
fn neighbor(c: *ui.Context, a: *App, k: theme.Colors, ix: usize, chat_id: ?[]const u8, w: f32) bool {
    {
        const h = ui.div(c).row().wFull().h(30).px(14).gap(6).itemsCenter();
        defer h.end();
        const ch = if (chat_id) |id| a.findChat(id) else null;
        const title = if (ch) |x| sidebar.chatLabel(x) else if (chat_id != null) "Untitled session" else "New session";
        kit.ellipsisText(c, title, .{ .size = 12, .color = k.muted }, @max(w - 28 - 20 - 6, 0));
        ui.spacer(c);
        if (kit.iconButton(c, k, .close, .{ .size = 20, .radius = 5, .icon = 12 })) {
            a.focusPane(ix);
            a.closeFocused();
            return true;
        }
    }
    // Ghostty dims unfocused splits.
    const body = ui.div(c).column().grow().wFull().opacity(0.8);
    defer body.end();
    if (chat_id) |id| {
        if (a.peer(id)) |p| transcript_view.entries(c, a, k, &p.transcript, w, p.watch != null, 8);
        return false;
    }
    const empty = ui.div(c).column().grow().wFull().px(16).gap(4).center();
    defer empty.end();
    ui.text(c, "Empty pane", .{ .size = 13, .color = k.muted.alpha(0.8) });
    const space = a.newChatSpace();
    ui.text(c, if (space) |sp| c.print("Click to start a session in {s}", .{sp.name}) else "Click to start a session", .{ .size = 11.5, .color = k.muted.alpha(0.55) });
    return false;
}

/// ⌘B the sidebar, ⌘T or ⌘N a new tab; ⌘D and ⌘⇧D split the chat, ⌘[ and
/// ⌘] step through its panes (through tabs with none), ⌥⌘ and ⌃⌘ with an
/// arrow focus and resize them, ⌃⌘= evens them, ⌘⇧↩ zooms one; ⌘W closes
/// the pane, then the tab; Escape closes what is open
/// (protocol/keymap-macos.json, the GPUI app's `shell::` bindings).
fn keys(c: *ui.Context, a: *App) void {
    const S = ui.Shortcut;
    // A shortcut being rebound takes the keys first.
    const rebinding = @import("view_settings_shortcuts.zig");
    if (rebinding.recording(a)) return rebinding.capture(c, a);
    if (c.shortcut(.{ .key = 'b', .cmd = true })) a.view.sidebar_open = !a.view.sidebar_open;
    if (c.shortcut(.{ .key = ',', .cmd = true })) settings_view.open(a);
    if (a.selected != null and c.shortcut(.{ .key = 'e', .cmd = true })) @import("app_files.zig").toggle(a);
    if (a.selected != null and c.shortcut(.{ .key = 'r', .cmd = true })) @import("app_panels.zig").toggleHost(a);
    if (c.shortcut(.{ .key = 't', .cmd = true }) or c.shortcut(.{ .key = 'n', .cmd = true })) a.newTab();
    if (c.shortcut(.{ .key = 'w', .cmd = true })) a.closeFocused();
    if (c.shortcut(.{ .key = 'd', .cmd = true })) a.splitPane(.horizontal);
    if (c.shortcut(.{ .key = 'd', .cmd = true, .shift = true })) a.splitPane(.vertical);
    if (c.shortcut(.{ .key = '[', .cmd = true })) a.stepPane(false);
    if (c.shortcut(.{ .key = ']', .cmd = true })) a.stepPane(true);
    if (c.shortcut(.{ .key = S.enter, .cmd = true, .shift = true })) a.tabs.toggleZoom();
    if (c.shortcut(.{ .key = '=', .cmd = true, .ctrl = true })) a.tabs.equalize();
    const arrows = [_]struct { u21, tabs.Direction }{ .{ S.left, .left }, .{ S.right, .right }, .{ S.up, .up }, .{ S.down, .down } };
    for (arrows) |x| {
        if (c.shortcut(.{ .key = x[0], .cmd = true, .alt = true })) a.focusToward(x[1]);
        if (c.shortcut(.{ .key = x[0], .cmd = true, .ctrl = true })) a.tabs.resize(x[1]);
    }
    if (c.shortcut(.{ .key = S.escape }) and a.queue_edit == null) {
        a.picker = .none;
        a.view.filter_menu = false;
        a.view.more_menu = false;
        a.view.account_menu = false;
    }
}

fn titlebar(c: *ui.Context, a: *App, k: theme.Colors) void {
    const bar = ui.div(c).fixed().offset(cluster_x, 4 + (34 - 24) / 2).row().itemsCenter().layer(3);
    defer bar.end();
    if (kit.iconButton(c, k, .@"sidebar-minimalistic-left", .{})) a.view.sidebar_open = !a.view.sidebar_open;
    _ = c.leaf(.{ .width = .{ .px = 8 } }, .none, null);
    if (kit.iconButton(c, k, .@"arrow-left", .{ .disabled = !a.tabs.canStep(-1) })) a.showTab(a.tabs.active - 1);
    _ = c.leaf(.{ .width = .{ .px = 2 } }, .none, null);
    if (kit.iconButton(c, k, .@"arrow-right", .{ .disabled = !a.tabs.canStep(1) })) a.showTab(a.tabs.active + 1);
    if (a.selected != null) {
        _ = c.leaf(.{ .width = .{ .px = 8 } }, .none, null);
        if (kit.iconButton(c, k, .plus, .{})) a.newTab();
    }
}

/// The title bar's right end, over the panels: the files panel and the
/// surface pane's toggles (`shell/tabs.rs`); a new chat has none.
fn trailing(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (a.selected == null) return;
    const va = @import("view_actions.zig");
    const actions_w = va.controlWidth(c, a);
    const w: f32 = 28 * 2 + 4 + (if (actions_w > 0) actions_w + 8 else 0);
    const bar = ui.div(c).fixed().offset(c.size.w - 6 - w, 4 + (34 - 28) / 2).row().gap(4).itemsCenter().layer(3);
    defer bar.end();
    if (actions_w > 0) {
        va.control(c, a, k);
        _ = c.leaf(.{ .width = .{ .px = 4 } }, .none, null);
    }
    if (kit.iconButton(c, k, .@"file-tree", .{ .size = 28, .on = a.panels.files_open })) @import("app_files.zig").toggle(a);
    if (kit.iconButton(c, k, .@"sidebar-minimalistic", .{ .size = 28 })) @import("app_panels.zig").toggleHost(a);
}

/// The chat's identity in the title bar's row: its agent's mark, its title,
/// and "project @ device" (`shell/tabs.rs`).
fn header(c: *ui.Context, a: *App, k: theme.Colors) void {
    const side: f32 = if (a.view.sidebar_open) sidebar.width else 0;
    // Clear of the title bar's buttons, and 16 points into the main column.
    const left = @max(side + 16, cluster_x + cluster_w + 12 + 32) - side;
    const bar = ui.div(c).row().wFull().h(sidebar.titlebar_h).pt(4).pl(left).pr(6).gap(6).itemsCenter().clip();
    defer bar.end();
    const id = a.selected orelse return;
    const chat = a.findChat(id) orelse return;
    const mark = icons.harnessMark(chat.harness orelse "graff");
    icons.icon(c, mark.name, 14, mark.brand orelse k.muted, 0);
    const room = @import("view_transcript.zig").mainWidth(c, a) - left - 6 - 70;
    const title = sidebar.chatLabel(chat);
    const title_st: ui.TextStyle = .{ .size = 12, .weight = .medium, .color = k.text.alpha(0.85) };
    const title_w = @min(c.text.width(title, title_st), room * 0.6);
    kit.fadeText(c, title, title_st, title_w);
    const space = a.findSpace(chat.space_id);
    const where = c.print("{s} @ {s}", .{ if (space) |s| s.name else "~", a.deviceName(chat.device_id) });
    kit.fadeText(c, where, .{ .size = 12, .color = k.muted.alpha(0.5) }, room - title_w - 20 - 12);
}
