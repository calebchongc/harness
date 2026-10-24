//! The sidebar's popovers, drawn over the window under the control that
//! opened them: the project filter, view options, and the account badge's.
//! A click outside closes them.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const App = @import("app.zig").App;

pub fn menus(c: *ui.Context, a: *App, k: theme.Colors) void {
    const v = &a.view;
    if (!v.filter_menu and !v.more_menu and !v.account_menu and !v.space_menu) return;
    {
        // Behind the menu: a click anywhere else closes it.
        const back = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(4);
        defer back.end();
        if (back.clicked()) {
            v.filter_menu = false;
            v.more_menu = false;
            v.account_menu = false;
            v.space_menu = false;
            return;
        }
    }
    if (v.filter_menu) if (v.filter_anchor) |r| {
        const m = panel(c, k, r.x, r.y + r.h + 4, @max(r.w, 220));
        defer m.end();
        if (item(c, k, .folder, "All projects", v.filter == null)) v.setFilter(a.gpa, null);
        for (a.spaces.items) |s| {
            ui.key(c, c.print("filter-{s}", .{s.id}));
            const on = v.filter != null and std.mem.eql(u8, v.filter.?, s.id);
            if (item(c, k, .folder, s.name, on)) v.setFilter(a.gpa, s.id);
        }
        divider(c, k);
        if (item(c, k, .plus, "Add folder…", false)) {
            v.filter_menu = false;
            a.addFolder();
        }
    };
    if (v.more_menu) if (v.more_anchor) |r| {
        const m = panel(c, k, r.x, r.y + r.h + 4, 200);
        defer m.end();
        if (item(c, k, .plus, "Add folder…", false)) {
            v.more_menu = false;
            a.addFolder();
        }
        if (item(c, k, .@"archive-minimalistic", if (v.archived_open) "Hide archived" else "Show archived", false)) {
            v.archived_open = !v.archived_open;
            v.more_menu = false;
        }
    };
    if (v.space_menu) if (v.space_anchor) |r| {
        const m = panel(c, k, r.x, r.y + r.h + 4, 240);
        defer m.end();
        const current = a.newChatSpace();
        for (a.spaces.items) |s| {
            ui.key(c, c.print("space-{s}", .{s.id}));
            const on = current != null and std.mem.eql(u8, current.?.id, s.id);
            if (item(c, k, .folder, s.name, on)) {
                a.select(null, s.id);
                v.space_menu = false;
            }
        }
        divider(c, k);
        if (item(c, k, .plus, "Add folder…", false)) {
            v.space_menu = false;
            a.addFolder();
        }
    };
    if (v.account_menu) if (v.account_anchor) |r| {
        const m = panel(c, k, r.x, r.y - 52, 256 - 16);
        defer m.end();
        const id = ui.div(c).row().wFull().px(10).py(6);
        defer id.end();
        ui.text(c, "Local only", .{ .size = 11, .color = k.muted });
    };
}

fn panel(c: *ui.Context, k: theme.Colors, x: f32, y: f32, w: f32) ui.Div {
    return ui.div(c).fixed().offset(x, y).w(w).layer(5).column().p(4).gap(1)
        .bg(k.composer).border(k.border).borderW(1).rounded(10).shadowLg();
}

fn item(c: *ui.Context, k: theme.Colors, icon: icons.Name, label: []const u8, on: bool) bool {
    var r = ui.div(c).row().wFull().h(30).px(8).gap(8).itemsCenter().rounded(7).hover(k.hover);
    if (on) r = r.bg(k.selected);
    defer r.end();
    const clicked = r.clicked();
    icons.icon(c, icon, 15, k.muted, 0);
    ui.text(c, label, .{ .size = 13, .color = k.text });
    ui.spacer(c);
    if (on) icons.icon(c, .check, 12, k.accent, 0);
    return clicked;
}

fn divider(c: *ui.Context, k: theme.Colors) void {
    const d = ui.div(c).column().wFull().py(3);
    defer d.end();
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
}
