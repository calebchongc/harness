//! The window, laid out as Harness's (crates/ui/src/shell.rs): the sidebar
//! on the left, the open chat on the right with its header in the title
//! bar's row, and over both the title bar's buttons: the sidebar toggle,
//! back and forward through the tabs, and a new tab.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const sidebar = @import("view_sidebar.zig");
const App = @import("app.zig").App;

/// Where the title bar's buttons start: right of the traffic lights.
const cluster_x: f32 = 88;
/// Three 24-point buttons, 8 then 2 points apart.
const cluster_w: f32 = 24 * 3 + 8 + 2;

pub fn view(a: *App, c: *ui.Context) void {
    const dark = a.dark orelse nanoui.isDark();
    c.theme = theme.ui(dark);
    const k = theme.colors(dark);
    if (a.tick(c.time)) |wait| c.frameIn(wait);
    c.title_bar_height = sidebar.titlebar_h;
    keys(c, a);
    {
        const root = ui.div(c).row().sizeFull().bg(k.shell);
        defer root.end();
        if (a.view.sidebar_open) {
            sidebar.sidebar(c, a, k);
            _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = k.border }, .none, null);
        }
        const main = ui.div(c).row().grow().w(0).hFull();
        defer main.end();
        {
            const chat = ui.div(c).column().grow().w(0).hFull().clip();
            defer chat.end();
            header(c, a, k);
            if (a.selected == null) {
                @import("view_newchat.zig").canvas(c, a, k);
            } else {
                @import("view_transcript.zig").transcript(c, a, k);
                @import("view_composer.zig").docked(c, a, k);
            }
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
    @import("view_menus.zig").menus(c, a, k);
    @import("view_picker.zig").popover(c, a, k);
}

/// ⌘B the sidebar, ⌘T or ⌘N a new tab, ⌘W closes the tab, ⌘[ and ⌘] step
/// through tabs; Escape closes what is open.
fn keys(c: *ui.Context, a: *App) void {
    const S = ui.Shortcut;
    if (c.shortcut(.{ .key = 'b', .cmd = true })) a.view.sidebar_open = !a.view.sidebar_open;
    if (a.selected != null and c.shortcut(.{ .key = 'e', .cmd = true })) @import("app_files.zig").toggle(a);
    if (a.selected != null and c.shortcut(.{ .key = 'r', .cmd = true })) @import("app_panels.zig").toggleHost(a);
    if (c.shortcut(.{ .key = 't', .cmd = true }) or c.shortcut(.{ .key = 'n', .cmd = true })) a.newTab();
    if (c.shortcut(.{ .key = 'w', .cmd = true })) a.closeTab(a.tabs.active);
    if (c.shortcut(.{ .key = '[', .cmd = true }) and a.tabs.canStep(-1)) a.showTab(a.tabs.active - 1);
    if (c.shortcut(.{ .key = ']', .cmd = true }) and a.tabs.canStep(1)) a.showTab(a.tabs.active + 1);
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
    const w: f32 = 28 * 2 + 4;
    const bar = ui.div(c).fixed().offset(c.size.w - 6 - w, 4 + (34 - 28) / 2).row().gap(4).itemsCenter().layer(3);
    defer bar.end();
    if (kit.iconButton(c, k, .@"file-tree", .{ .size = 28, .on = a.panels.files_open })) @import("app_files.zig").toggle(a);
    if (kit.iconButton(c, k, .@"sidebar-minimalistic", .{ .size = 28 })) @import("app_panels.zig").toggleHost(a);
}

/// The chat's identity in the title bar's row: its agent's mark, its title,
/// and "project @ device" (`shell/tabs.rs`).
fn header(c: *ui.Context, a: *App, k: theme.Colors) void {
    const side: f32 = if (a.view.sidebar_open) sidebar.width + 1 else 0;
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
