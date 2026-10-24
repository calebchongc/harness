//! The model chip's picker, opening above it (crates/ui/src/pickers.rs):
//! the agent (a new chat's only; a chat keeps the agent it started with),
//! its models, and the model's reasoning levels. A chat's picks replace its
//! config for the next message (`SetChatConfig`).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const rules = @import("rules.zig");
const App = @import("app.zig").App;

const row_h: f32 = 30;
const head_h: f32 = 24;

pub fn popover(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (a.picker == .none) return;
    const anchor = a.view.chip_anchor orelse return;
    const t = a.target();
    const new_chat = a.selected == null;
    var agents: usize = 0;
    if (new_chat) for (a.harnesses.items) |h| {
        if (h.offered or std.mem.eql(u8, h.id, t.harness)) agents += 1;
    };
    const levels = a.levelsOf(t.model);
    const rows = agents + @max(a.models.items.len, 1) + levels.len;
    const heads: usize = (if (agents > 0) @as(usize, 1) else 0) + 1 + (if (levels.len > 0) @as(usize, 1) else 0);
    const h = @min(@as(f32, @floatFromInt(rows)) * row_h + @as(f32, @floatFromInt(heads)) * head_h + 8, c.size.h - 80);
    const w: f32 = 280;
    {
        const back = ui.div(c).fixed().offset(0, 0).size(c.size.w, c.size.h).layer(4);
        defer back.end();
        if (back.clicked()) {
            a.picker = .none;
            return;
        }
    }
    const x = std.math.clamp(anchor.x + anchor.w - w, 8, c.size.w - w - 8);
    const panel = ui.div(c).fixed().offset(x, @max(anchor.y - h - 6, 8)).w(w).h(h).layer(5).column().p(4).gap(1)
        .scrollY().bg(k.composer).border(k.border).borderW(1).rounded(10).shadowLg();
    defer panel.end();
    if (agents > 0) {
        head(c, k, "Agent");
        for (a.harnesses.items) |hn| {
            if (!hn.offered and !std.mem.eql(u8, hn.id, t.harness)) continue;
            ui.key(c, c.print("agent-{s}", .{hn.id}));
            if (option(c, k, icons.harnessMark(hn.id), hn.name, std.mem.eql(u8, hn.id, t.harness))) a.setHarness(hn.id);
        }
    }
    head(c, k, "Model");
    if (a.models.items.len == 0) {
        const e = ui.div(c).row().h(row_h).px(10).itemsCenter();
        defer e.end();
        ui.text(c, "Loading models…", .{ .size = 12, .color = k.muted });
    }
    const current = t.model orelse if (a.models.items.len > 0) a.models.items[0].id else "";
    for (a.models.items) |m| {
        ui.key(c, c.print("model-{s}", .{m.id}));
        if (option(c, k, null, m.label, std.mem.eql(u8, m.id, current))) a.pickModel(m.id);
    }
    if (levels.len > 0) {
        head(c, k, "Reasoning");
        for (levels) |l| {
            ui.key(c, c.print("level-{s}", .{l}));
            const on = t.reasoning != null and std.mem.eql(u8, t.reasoning.?, l);
            if (option(c, k, null, rules.reasoningLabel(l), on)) a.pickReasoning(l);
        }
    }
}

fn head(c: *ui.Context, k: theme.Colors, label: []const u8) void {
    const r = ui.div(c).row().wFull().h(head_h).px(10).itemsEnd().pb(4);
    defer r.end();
    ui.text(c, label, .{ .size = 11, .weight = .medium, .color = k.muted.alpha(0.7) });
}

fn option(c: *ui.Context, k: theme.Colors, mark: ?@TypeOf(icons.harnessMark("")), label: []const u8, on: bool) bool {
    var r = ui.div(c).row().wFull().h(row_h).px(10).gap(8).itemsCenter().rounded(7).hover(k.hover);
    if (on) r = r.bg(k.selected);
    defer r.end();
    const clicked = r.clicked();
    if (mark) |m| icons.icon(c, m.name, 15, m.brand orelse k.muted, 0);
    ui.text(c, label, .{ .size = 13, .color = k.text });
    ui.spacer(c);
    if (on) icons.icon(c, .check, 12, k.accent, 0);
    return clicked;
}
