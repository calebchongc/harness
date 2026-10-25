//! The surface pane right of the chat (crates/ui/src/shell.rs): a band of
//! tabs in the title bar's row (a checkout's diff, an open file), "+" to
//! add one, the picker while none is open, and the open tab's view. A file
//! shows its path as a breadcrumb, then Markdown as it reads or code with
//! line numbers and colours.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const panels = @import("app_panels.zig");
const highlight = @import("highlight.zig");
const App = @import("app.zig").App;

pub const width: f32 = 520;
const band_h: f32 = 38;

pub fn host(c: *ui.Context, a: *App, k: theme.Colors) void {
    const col = ui.div(c).column().w(width).hFull().bg(k.shell).clip();
    defer col.end();
    band(c, a, k);
    const t = a.panels.activeTab() orelse return picker(c, a, k);
    switch (t.kind) {
        .diffs => @import("view_diffs.zig").diffs(c, a, k),
        .file => file(c, a, k, t.path),
    }
}

fn band(c: *ui.Context, a: *App, k: theme.Colors) void {
    const b = ui.div(c).row().wFull().h(band_h).px(8).gap(4).itemsCenter().clip();
    defer b.end();
    var close: ?usize = null;
    var show: ?usize = null;
    for (a.panels.tabs.items, 0..) |t, i| {
        ui.key(c, c.print("host-tab-{d}", .{i}));
        const on = i == a.panels.active;
        var chip = ui.div(c).row().size(112, 24).px(6).gap(5).itemsCenter().rounded(6).clip();
        chip = if (on) chip.bg(k.wash(0.10)) else chip.hover(k.wash(0.06));
        defer chip.end();
        const hot = chip.hovered();
        if (chip.clicked() and !on) show = i;
        icons.icon(c, if (t.kind == .diffs) .list else .document, 12, k.muted, 0);
        const title = if (t.kind == .diffs) a.panels.scope.label() else std.fs.path.basename(t.path);
        kit.fadeText(c, title, .{ .size = 11.5, .color = if (on) k.text else k.muted }, if (hot) 62 else 82);
        if (hot) {
            ui.spacer(c);
            const x = ui.div(c).row().size(16, 16).center().rounded(4).hover(k.wash(0.12));
            defer x.end();
            if (x.clicked()) close = i;
            icons.icon(c, .close, 10, k.muted, 0);
        }
    }
    if (kit.iconButton(c, k, .plus, .{ .size = 24, .icon = 14 })) panels.addDiffsTab(a);
    if (close) |i| panels.closeTab(a, i) else if (show) |i| panels.showTab(a, i);
}

/// With no tab open: what can be opened here.
fn picker(c: *ui.Context, a: *App, k: theme.Colors) void {
    const area = ui.div(c).column().wFull().grow().center().gap(8);
    defer area.end();
    const row = ui.div(c).row().w(280).h(44).px(14).gap(10).itemsCenter().rounded(10).border(k.border).borderW(1).bg(k.ink(0.02)).hover(k.ink(0.05));
    defer row.end();
    if (row.clicked()) panels.addDiffsTab(a);
    icons.icon(c, .list, 15, k.muted, 0);
    ui.text(c, "Diffs", .{ .size = 13, .weight = .medium, .color = k.text });
}

fn file(c: *ui.Context, a: *App, k: theme.Colors, path: []const u8) void {
    {
        const bar = ui.div(c).row().wFull().h(32).px(12).gap(5).itemsCenter().border(k.border).borderW(0).clip();
        defer bar.end();
        icons.icon(c, .document, 12, k.muted, 0);
        var it = std.mem.splitScalar(u8, path, '/');
        var first = true;
        while (it.next()) |seg| {
            if (!first) ui.text(c, "›", .{ .size = 11, .color = k.faint });
            first = false;
            ui.text(c, seg, .{ .size = 11, .color = if (it.peek() == null) k.muted else k.faint });
        }
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
    const f = a.panels.file;
    if (f.loading) return centered(c, k, "Loading…");
    const text = f.text orelse return centered(c, k, f.reason orelse "This file can't be shown.");
    ui.scroll(c, .{ .grow = 1, .width = .fill, .padding = .{ .left = 16, .right = 16, .top = 12, .bottom = 24 } });
    defer ui.end(c);
    if (std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".markdown"))
        return @import("view_markdown.zig").markdown(c, k, text);
    code(c, k, text, langOf(path));
}

/// Code with its line numbers, coloured as the language reads.
pub fn code(c: *ui.Context, k: theme.Colors, text: []const u8, lang: []const u8) void {
    const pal = k.syntax;
    const st = kit.style(c, 12.5, 19, .{ .mono = true, .color = k.text });
    const num = kit.style(c, 11, 19, .{ .mono = true, .color = k.faint });
    var in_block: highlight.State = .{};
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |l| {
        n += 1;
        if (n > 4000) break;
        const r = ui.div(c).row().gap(12);
        defer r.end();
        {
            const g = ui.div(c).row().w(36).justifyEnd();
            defer g.end();
            ui.text(c, c.print("{d}", .{n}), num);
        }
        ui.richText(c, if (l.len == 0) " " else l, highlight.line(c.alloc(), l, lang, pal, &in_block), st);
    }
}

/// The language a path names, for colouring (`language_for_path`): a
/// Dockerfile's, a Makefile's, Cargo.lock's, else its extension's.
pub fn langOf(path: []const u8) []const u8 {
    const name = std.fs.path.basename(path);
    const named = [_][2][]const u8{ .{ "dockerfile", "dockerfile" }, .{ "containerfile", "dockerfile" }, .{ "makefile", "make" }, .{ "gnumakefile", "make" }, .{ "cargo.lock", "toml" } };
    for (named) |n| if (std.ascii.eqlIgnoreCase(name, n[0])) return n[1];
    const ext = std.fs.path.extension(name);
    return if (ext.len > 1) ext[1..] else "";
}

fn centered(c: *ui.Context, k: theme.Colors, text: []const u8) void {
    const box = ui.div(c).column().wFull().grow().center();
    defer box.end();
    ui.text(c, text, .{ .size = 12, .color = k.muted });
}
