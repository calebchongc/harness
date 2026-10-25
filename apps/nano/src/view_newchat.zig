//! A new chat, before its first message (crates/ui/src/composer.rs,
//! composer_dock.rs, starters.rs): the composer floats a little below the
//! middle, expanded, under "New session in" and the project's name (which
//! picks another), with starter prompts below it while it is empty.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const composer = @import("view_composer.zig");
const transcript_view = @import("view_transcript.zig");
const sidebar = @import("view_sidebar.zig");
const App = @import("app.zig").App;

const pill_h: f32 = 120;
/// From the heading's top to the pill's.
const heading_h: f32 = 94;

const Starter = struct { icon: icons.Name, title: []const u8, prompt: []const u8, needs_project: bool = false };

const starters = [_]Starter{
    .{ .icon = .@"magic-stick-3", .title = "Build something new", .prompt = "Build something new from scratch. Create a new folder for it under ~/Projects, set it up, and get a first working version running. Ask me anything you need to know before you start.\n\nMy idea: " },
    .{ .icon = .magnifer, .title = "Research a topic", .prompt = "Research the topic below and give me a concise, well-sourced write-up: key takeaways first, then the details, with links to your sources.\n\nTopic: " },
    .{ .icon = .global, .title = "Plan a launch", .prompt = "Help me take my product to market. Ask me about the product, who it's for, and my goals, then draft positioning, a go-to-market plan, and landing page copy.\n\nThe product: " },
    .{ .icon = .@"file-code", .title = "Tour this project", .prompt = "Give me a tour of this project: what it does, how it's organized, how to run it, and where I'd start making changes.", .needs_project = true },
};

pub fn canvas(c: *ui.Context, a: *App, k: theme.Colors) void {
    const main_w = transcript_view.paneWidth(c, a);
    const w = @min(main_w - 32, 768);
    // The pill's top, from the window's: (height − pill) / 2 + 8.
    const top = (c.size.h - pill_h) * 0.5 + 8;
    const area = ui.div(c).column().wFull().grow().itemsCenter();
    defer area.end();
    var lead = @max(top - heading_h - sidebar.titlebar_h, 0);
    // In a pane of a split down the window, centred in the pane.
    if (transcript_view.paneHeight(c, a)) |h| lead = @max((h - pill_h - heading_h) * 0.5, 0);
    _ = c.leaf(.{ .height = .{ .px = lead } }, .none, null);
    heading(c, a, k, w);
    composer.pill(c, a, k, w, .expanded, 26);
    // Only while nothing at all is typed, a space included.
    if (a.composer.text().len == 0) starterRow(c, a, k, w);
}

fn heading(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const box = ui.div(c).column().w(w).h(heading_h).px(4).gap(2);
    defer box.end();
    const space = a.newChatSpace();
    ui.text(c, if (space != null) "New session in" else "New session in your home folder", .{ .size = 12, .color = k.muted.alpha(0.7) });
    var t = ui.div(c).row().gap(6).itemsCenter().rounded(6);
    if (a.spaces.items.len > 0) t = t.hover(k.hover);
    defer t.end();
    if (t.clicked() and a.spaces.items.len > 0) a.view.space_menu = !a.view.space_menu;
    if (c.rects.get(c.node(t.index).id)) |r| a.view.space_anchor = r;
    ui.text(c, if (space) |s| s.name else "No project", .{ .size = 22, .weight = .semibold, .color = k.text.alpha(0.9) });
    icons.icon(c, .@"alt-arrow-down", 16, k.muted.alpha(0.6), 0);
}

/// The starters under an empty composer, as chips in rows that wrap at
/// the composer's width, each row centred, 6 points apart either way
/// (`render_starter_chips`: flex_wrap, justify_center, gap 6).
fn starterRow(c: *ui.Context, a: *App, k: theme.Colors, w: f32) void {
    const st: ui.TextStyle = .{ .size = 12 };
    const has_project = a.newChatSpace() != null;
    var shown: [starters.len]Starter = undefined;
    var n: usize = 0;
    for (starters) |s| {
        if (s.needs_project and !has_project) continue;
        shown[n] = s;
        n += 1;
    }
    const box = ui.div(c).column().w(w).pt(16).gap(6).itemsCenter();
    defer box.end();
    var i: usize = 0;
    while (i < n) {
        // As many chips as fit on this row; always at least one.
        var end = i + 1;
        var used = chipWidth(c, shown[i], st);
        while (end < n) : (end += 1) {
            const next = used + 6 + chipWidth(c, shown[end], st);
            if (next > w) break;
            used = next;
        }
        const row = ui.div(c).row().gap(6).justifyCenter();
        defer row.end();
        for (shown[i..end]) |s| chip(c, a, k, s, st);
        i = end;
    }
}

/// A chip's width: 10 points either side, the 13-point icon, 6 between.
fn chipWidth(c: *ui.Context, s: Starter, st: ui.TextStyle) f32 {
    return 10 + 13 + 6 + c.text.width(s.title, st) + 10 + 2;
}

fn chip(c: *ui.Context, a: *App, k: theme.Colors, s: Starter, st: ui.TextStyle) void {
    ui.key(c, s.title);
    const ch = ui.div(c).row().h(28).px(10).gap(6).itemsCenter().rounded(14).border(k.border).borderW(1).hover(k.hover);
    defer ch.end();
    const hot = ch.hovered();
    if (ch.clicked()) a.composer.set(s.prompt);
    icons.icon(c, s.icon, 13, if (hot) k.text else k.muted, 0);
    var t = st;
    t.color = if (hot) k.text else k.muted;
    ui.text(c, s.title, t);
}
