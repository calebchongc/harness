//! The agent and model pickers under a new chat's composer: two buttons,
//! each opening its list above the composer.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const App = @import("app.zig").App;

/// The two buttons, in the composer's bottom row.
pub fn buttons(c: *ui.Context, a: *App, k: theme.Colors) void {
    chip(c, a, k, .harness, a.harnessName(a.new_harness));
    chip(c, a, k, .model, a.modelLabel(a.new_model));
}

fn chip(c: *ui.Context, a: *App, k: theme.Colors, which: @TypeOf(a.picker), label: []const u8) void {
    var b = ui.div(c).row().px(8).py(3).gap(5).itemsCenter().rounded(6).hover(k.hover);
    if (a.picker == which) b = b.bg(k.raised);
    defer b.end();
    if (b.clicked()) a.picker = if (a.picker == which) .none else which;
    ui.text(c, label, .{ .size = 12, .color = k.muted });
    ui.icon(c, "chevron.down", .{ .size = 9, .frame = 10, .color = k.faint });
}

/// The open picker's list, drawn above the composer.
pub fn list(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (a.picker == .none) return;
    const box = ui.div(c).column().w(300).maxH(320).scrollY().bg(k.card).border(k.border).borderW(1).rounded(10).p(4).gap(1).shadowMd();
    defer box.end();
    switch (a.picker) {
        .harness => {
            var any = false;
            for (a.harnesses.items) |h| {
                if (!h.offered and !std.mem.eql(u8, h.id, a.new_harness)) continue;
                any = true;
                ui.key(c, c.print("h-{s}", .{h.id}));
                if (option(c, k, h.name, std.mem.eql(u8, h.id, a.new_harness))) a.setHarness(h.id);
            }
            if (!any) ui.text(c, "No agents are enabled.", .{ .size = 12, .color = k.muted });
        },
        .model => {
            if (option(c, k, "Default model", a.new_model == null)) a.setModel(null);
            for (a.models.items) |m| {
                ui.key(c, c.print("m-{s}", .{m.id}));
                const on = a.new_model != null and std.mem.eql(u8, a.new_model.?, m.id);
                if (option(c, k, m.label, on)) a.setModel(m.id);
            }
        },
        .none => {},
    }
}

fn option(c: *ui.Context, k: theme.Colors, label: []const u8, on: bool) bool {
    var row = ui.div(c).row().wFull().px(10).py(6).gap(8).itemsCenter().rounded(6).hover(k.hover);
    if (on) row = row.bg(k.selected);
    defer row.end();
    const clicked = row.clicked();
    ui.text(c, label, .{ .size = 13, .color = k.text });
    ui.spacer(c);
    if (on) ui.icon(c, "checkmark", .{ .size = 11, .frame = 14, .color = k.accent });
    return clicked;
}
