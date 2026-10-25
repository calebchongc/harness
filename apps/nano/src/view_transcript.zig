//! The open chat's transcript, as the GPUI transcript draws it
//! (crates/ui/src/transcript.rs): a centred column 736 points wide, the
//! user's messages as bubbles on the right, the agent's Markdown, its tool
//! calls and reasoning folded into groups ("Ran 2 commands"), errors as
//! chips, and under each message a lane whose copy button shows on hover.
//! An error signing in fixes says so and offers "Log in" (run_errors.zig);
//! a typed ChatGPT sign-in error carries its reconnect card
//! (view_reauth.zig).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const tools = @import("tools.zig");
const tr = @import("transcript.zig");
const sidebar = @import("view_sidebar.zig");
const App = @import("app.zig").App;
const rows_st = @import("view_settings_accounts_rows.zig").st;

/// The column's width: Settings › Appearance's conversation width
/// (`transcript_width`, 736 unless set), as of this frame.
pub var column_w: f32 = 736;

/// The column's width in a main area `w` wide, with its gutters.
pub fn columnWidth(w: f32) f32 {
    const gutter = std.math.clamp(w * 0.06, 12, 48);
    return @max(@min(column_w, w - 2 * gutter), 200);
}

/// The chat column's width: the window less the sidebar and the panels.
pub fn mainWidth(c: *ui.Context, a: *const App) f32 {
    var w = c.size.w - (if (a.view.sidebar_open) sidebar.width else 0);
    if (a.selected != null and a.panels.host_open) w -= @import("view_host.zig").width + 1;
    if (a.selected != null and a.panels.files_open) w -= @import("view_files.zig").width + 1;
    return @max(w, 300);
}

/// The focused pane's width: the chat column's, less the other panes of a
/// split across it.
pub fn paneWidth(c: *ui.Context, a: *const App) f32 {
    const w = mainWidth(c, a);
    const s = a.tabs.layout() orelse return w;
    if (s.zoomed or s.axis != .horizontal) return w;
    return @max(w * s.shares.items[s.focus] - 1, 200);
}

/// The focused pane's height under the title bar, in a split down the
/// window; null when it has the column's full height.
pub fn paneHeight(c: *ui.Context, a: *const App) ?f32 {
    const s = a.tabs.layout() orelse return null;
    if (s.zoomed or s.axis != .vertical) return null;
    return (c.size.h - sidebar.titlebar_h) * s.shares.items[s.focus] - 1;
}

/// The open chat's transcript, and over its left edge the prompt rail
/// (`render_rail`, view_rail.zig): the column it is in is the rail's.
pub fn transcript(c: *ui.Context, a: *App, k: theme.Colors) void {
    const rail = @import("view_rail.zig");
    rail.step(c, &a.view.rail);
    const drawn = entries(c, a, k, &a.transcript, paneWidth(c, a), a.w_doc.id != null, 64 - sidebar.titlebar_h);
    rail.rail(c, k, &a.view.rail, &a.transcript, drawn.ticks, drawn.box, mainWidth(c, a));
}

/// What a transcript drew: its scroll box, and its prompts' rows as last
/// laid out.
pub const Drawn = struct { box: u64 = 0, ticks: []const @import("view_rail.zig").Tick = &.{} };

/// A transcript `w` wide: the open chat's, or a split pane's neighbor's.
/// The first row sits `top` points down; rows settle at the bottom, over
/// the composer, until they fill it.
pub fn entries(c: *ui.Context, a: *App, k: theme.Colors, t: *const tr.Transcript, w: f32, loading: bool, top: f32) Drawn {
    const frame = ui.div(c).column().grow().wFull().h(0);
    defer frame.end();
    const drawn = rows(c, a, k, t, w, loading, top);
    topFade(c, k);
    return drawn;
}

/// `TRANSCRIPT_FADE_BAND`: rows scrolled up fade out over the 24 points
/// under the title bar, gone by its edge (shell.rs `edge_faded`, its
/// `inset_top(TITLEBAR_HEIGHT)`), here as the column's colour laid over
/// them a point at a time.
fn topFade(c: *ui.Context, k: theme.Colors) void {
    const band: f32 = 24;
    var y: f32 = 0;
    while (y < band) : (y += 1) {
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.shell.alpha(1 - (y + 0.5) / band), .absolute = true, .offset = .{ .x = 0, .y = y } }, .none, null);
    }
}

fn rows(c: *ui.Context, a: *App, k: theme.Colors, t: *const tr.Transcript, w: f32, loading: bool, top: f32) Drawn {
    const col = columnWidth(w);
    // The last row clears the status strip over the composer and the fade
    // band above it (`bottom_clearance + TRANSCRIPT_FADE_BAND + 8`); the
    // composer itself is under the scroll, not over it. Its bar shows
    // while it scrolls, as GPUI's overlay rail.
    var st: ui.Style = .{ .grow = 1, .width = .fill, .padding = .{ .top = top, .bottom = 24 + 24 + 8 }, .align_items = .center, .justify = .end, .follow_end = true };
    if (@hasField(ui.Style, "scrollbar")) st.scrollbar = .{ .overlay = k.faint.alpha(0.5) };
    st.scroll = true;
    st.direction = .column;
    const scroll = c.open(st, null);
    defer ui.end(c);
    var drawn: Drawn = .{ .box = c.node(scroll).id };
    var ticks: std.ArrayList(@import("view_rail.zig").Tick) = .empty;
    const body = ui.div(c).column().w(col);
    defer body.end();
    const entries_ = t.entries.items;
    // The chat these are, for routing a sign-in: the open one's or a pane's.
    const chat_id: ?[]const u8 = if (t == &a.transcript) a.selected else for (a.peers.items) |*p| {
        if (&p.transcript == t) break p.id;
    } else null;
    if (entries_.len == 0) {
        const e = ui.div(c).row().wFull().pt(40).justifyCenter();
        defer e.end();
        ui.text(c, if (loading) "Loading…" else "Nothing here yet.", .{ .size = 13, .color = k.faint });
        return drawn;
    }
    for (entries_, 0..) |*e, i| {
        ui.key(c, c.print("entry-{s}", .{e.id}));
        // `top_gap_for`: every entry's first row opens a turn (`SPACE_LG`).
        if (i > 0) _ = c.leaf(.{ .height = .{ .px = 16 } }, .none, null);
        const at: At = .{ .chat_id = chat_id, .entries = entries_, .index = i, .col = col };
        switch (e.role) {
            .user => {
                // Its row starts where the turn's gap does (`top_gap_for`).
                const r = user(c, k, e, col);
                ticks.append(c.alloc(), .{ .entry = i, .top = if (r) |x| x.y - (if (i > 0) @as(f32, 16) else 0) else null }) catch {};
            },
            .assistant => assistant(c, a, k, e, at),
            .system => system(c, a, k, e, at),
        }
    }
    drawn.ticks = ticks.items;
    return drawn;
}

/// A prompt's bubble; where it was last laid out.
fn user(c: *ui.Context, k: theme.Colors, e: *const tr.Entry, col: f32) ?ui.Rect {
    const wrap = ui.div(c).column().wFull().itemsEnd();
    defer wrap.end();
    const hovered = wrap.hovered();
    {
        const bubble = ui.div(c).column().maxW(col * 0.8).bg(k.user_bubble).rounded(16).px(16).py(10).gap(6);
        defer bubble.end();
        const st = kit.style(c, 14, 22, .{ .wrap = true, .color = k.text });
        for (e.parts.items) |*p| switch (p.kind) {
            .text => ui.text(c, p.text.items, st),
            .image => attachment(c, k, .document, p.text.items),
            else => {},
        };
    }
    lane(c, k, e, hovered, true);
    return c.rects.get(c.node(wrap.index).id);
}

/// Under a message: 32 points held for its copy button, shown on hover.
fn lane(c: *ui.Context, k: theme.Colors, e: *const tr.Entry, hovered: bool, right: bool) void {
    var l = ui.div(c).row().wFull().h(32).pt(8);
    if (right) l = l.justifyEnd();
    defer l.end();
    if (!hovered) return;
    if (kit.iconButton(c, k, .copy, .{ .size = 24, .radius = 6, .icon = 14 })) {
        var text: std.ArrayList(u8) = .empty;
        for (e.parts.items) |*p| if (p.kind == .text) {
            if (text.items.len > 0) text.appendSlice(c.alloc(), "\n\n") catch {};
            text.appendSlice(c.alloc(), p.text.items) catch {};
        };
        c.clipboard.write(c.clipboard.ctx, text.items);
    }
}

/// Where an entry is: its chat, its place among the entries, the column.
const At = struct {
    chat_id: ?[]const u8,
    entries: []const tr.Entry,
    index: usize,
    col: f32,
};

fn assistant(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, at: At) void {
    const last = at.index + 1 == at.entries.len;
    const col = ui.div(c).column().wFull();
    defer col.end();
    const hovered = col.hovered();
    // Its parts 12 apart; the lane right under the last (the row's
    // `strip`, with no gap of its own).
    const parts_box = ui.div(c).column().wFull().gap(12);
    var buf: [256]tools.Run = undefined;
    const rs = tools.runs(&buf, e.parts.items);
    for (rs, 0..) |r, i| {
        const p = &e.parts.items[r.start];
        ui.key(c, c.print("run-{s}-{s}", .{ e.id, p.id }));
        if (r.group) {
            const tail = e.status == .streaming and last and i + 1 == rs.len;
            group(c, a, k, e, e.parts.items[r.start..r.end], tail);
            continue;
        }
        switch (p.kind) {
            .text => @import("view_markdown.zig").markdown(c, k, p.text.items),
            .@"error" => errorPart(c, a, k, e, p, at),
            .image => attachment(c, k, .document, p.text.items),
            .visual => attachment(c, k, .widget, p.text.items),
            .delegation => attachment(c, k, .widget, "Delegated to a subagent"),
            .input => {
                const q = if (p.questions.len > 0) p.questions[0] else null;
                const label = if (q) |x| (if (x.question.len > 0) x.question else x.header) else "Question";
                @import("view_question.zig").chip(c, k, label, p.resolved);
            },
            else => {},
        }
    }
    if (e.status == .streaming and e.parts.items.len == 0) ui.text(c, "Working…", .{ .size = 12, .color = k.muted });
    parts_box.end();
    if (e.status != .streaming) lane(c, k, e, hovered, false);
}

const row_h: f32 = 32;
const tree_w: f32 = 48;

/// A run of tool calls and reasoning, folded under one line; it opens on
/// its own while it is the tail of a streaming reply.
fn group(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, parts: []const tr.Part, tail: bool) void {
    const key = c.print("{s}/{s}", .{ e.id, parts[0].id });
    const open = a.view.groupOpen(key, tail);
    const box = ui.div(c).column().wFull();
    defer box.end();
    {
        const h = ui.div(c).row().h(26).gap(6).pr(4).itemsCenter();
        defer h.end();
        if (h.clicked()) a.view.toggleGroup(a.gpa, key, tail);
        const slot = ui.div(c).row().size(22, 18).center();
        icons.icon(c, if (open) .@"alt-arrow-down" else .@"alt-arrow-right", 14, k.muted, 0);
        slot.end();
        const lb = c.alloc().alloc(u8, 160) catch return;
        ui.text(c, tools.label(lb, parts), kit.style(c, 12, 18, .{ .color = if (h.hovered()) k.text else k.muted }));
    }
    if (!open) return;
    for (parts, 0..) |*p, i| {
        ui.key(c, c.print("tool-{s}", .{p.id}));
        treeRow(c, k, p, i + 1 == parts.len);
    }
}

/// One call in an open group: the tree's trunk and elbow, its icon, its
/// chip and what it ran.
fn treeRow(c: *ui.Context, k: theme.Colors, p: *const tr.Part, last: bool) void {
    const line = k.wash(0.12);
    const r = ui.div(c).row().wFull().gap(8).itemsStart();
    defer r.end();
    {
        const g = ui.div(c).column().w(tree_w).h(row_h);
        defer g.end();
        // Trunk down from the header (to the elbow on the last row), then
        // the branch out to the icon.
        _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .{ .px = if (last) row_h / 2 else row_h }, .background = line, .absolute = true, .offset = .{ .x = 12, .y = 0 } }, .none, null);
        _ = c.leaf(.{ .width = .{ .px = 15 }, .height = .{ .px = 1 }, .background = line, .absolute = true, .offset = .{ .x = 13, .y = row_h / 2 } }, .none, null);
        const ic = ui.div(c).row().absolute().offset(30, (row_h - 18) / 2);
        defer ic.end();
        icons.icon(c, toolIcon(p), 16, if (p.is_error) k.danger else k.muted, 18);
    }
    const body = ui.div(c).column().grow().w(0).justifyCenter().gap(4).py(7);
    defer body.end();
    const head = ui.div(c).row().gap(8).itemsCenter();
    {
        defer head.end();
        const chip = if (p.kind == .reasoning) "Thought process" else p.chip;
        ui.text(c, chip, .{ .size = 12, .weight = .medium, .color = k.text.alpha(0.8) });
        if (p.kind == .tool) {
            const d = firstLine(p.text.items);
            kit.fadeText(c, d, .{ .size = 12, .mono = p.tool == .exec, .color = if (p.is_error) k.danger else k.muted }, 560);
            if (!p.resolved) kit.snake(c, k);
        }
    }
    if (p.kind == .reasoning) {
        const lines = limitLines(p.text.items, 24);
        ui.text(c, lines, kit.style(c, 12, 18, .{ .wrap = true, .italic = true, .color = k.muted }));
    }
}

fn toolIcon(p: *const tr.Part) icons.Name {
    if (p.kind == .reasoning) return .@"magic-stick-3";
    return switch (p.tool) {
        .exec => .terminal,
        .readFile => .document,
        .writeFile, .editFile, .applyPatch => .pen,
        .search, .glob => .magnifer,
        .webFetch, .webSearch => .globe,
        .todo => .checklist,
        .mcp, .unknown => .widget,
    };
}

fn firstLine(s: []const u8) []const u8 {
    return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
}

fn limitLines(s: []const u8, n: usize) []const u8 {
    var count: usize = 0;
    for (s, 0..) |ch, i| if (ch == '\n') {
        count += 1;
        if (count == n) return s[0..i];
    };
    return s;
}

/// An error part: a typed sign-in error's reconnect card, else the chip.
fn errorPart(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, p: *const tr.Part, at: At) void {
    const row_id = c.print("{s}#{s}", .{ e.id, p.id });
    // Harness-generated; the chip is one line.
    const message = singleLine(c, p.text.items);
    const provider = p.reauth orelse return errorChip(c, a, k, at.chat_id, message);
    // The chat moved on: a person's message after this error.
    const later = for (at.entries[at.index + 1 ..]) |x| {
        if (x.role == .user) break true;
    } else false;
    @import("view_reauth.zig").card(c, a, k, .{ .chat_id = at.chat_id, .row_id = row_id, .message = message, .provider = provider, .later_activity = later, .col = at.col });
}

/// `single_line`: every run of whitespace as one space, none at the ends.
fn singleLine(c: *ui.Context, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, s, " \t\r\n\x0b\x0c");
    while (it.next()) |w| {
        if (out.items.len > 0) out.append(c.alloc(), ' ') catch return s;
        out.appendSlice(c.alloc(), w) catch return s;
    }
    return out.items;
}

/// `notice_chip` with its tile (notice.rs): the danger triangle, `label`,
/// Copy, then the message wrapped. The caller adds what goes under it and
/// ends it.
pub fn noticeChip(c: *ui.Context, k: theme.Colors, label: []const u8, message: []const u8) ui.Div {
    // GPUI's edge insets what's inside it; here it's drawn over the box.
    const chip = ui.div(c).column().wFull().rounded(10).px(10 + 1).py(8 + 1).gap(6).border(k.danger.alpha(0.16)).borderW(1).bg(k.danger.alpha(0.05));
    {
        const h = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer h.end();
        const tile = ui.div(c).row().size(20, 20).center().rounded(6).bg(k.danger.alpha(0.12));
        icons.icon(c, .@"danger-triangle", 12, k.danger_muted.alpha(0.8), 0);
        tile.end();
        ui.text(c, label, .{ .size = 12, .weight = .medium, .color = k.danger_muted.alpha(0.8) });
        ui.spacer(c);
        const copy = ui.div(c).row().size(20, 20).center().rounded(6).hover(k.danger.alpha(0.12));
        icons.icon(c, .copy, 12, k.danger_muted.alpha(0.8), 0);
        copy.end();
        if (copy.clicked()) c.clipboard.write(c.clipboard.ctx, message);
    }
    // GPUI's line height (phi), as the GPUI renderer draws the chip.
    ui.text(c, message, rows_st(c, 12, .{ .wrap = true, .color = k.text.alpha(0.8) }));
    return chip;
}

/// `error_chip`: the message wraps; a refusal that signing in fixes says so
/// in the label, and with a chat to route it carries "Log in" under the
/// message (`sign_in_for_chat`).
fn errorChip(c: *ui.Context, a: *App, k: theme.Colors, chat_id: ?[]const u8, message: []const u8) void {
    const run_errors = @import("run_errors.zig");
    // The ChatGPT plan's own limit has its plan-usage card in the GPUI app,
    // never "Log in".
    const problem = if (run_errors.isPlanUsageLimit(message)) null else run_errors.providerProblem(message);
    const outer = ui.div(c).column().wFull().py(4);
    defer outer.end();
    const chip = noticeChip(c, k, if (problem) |p| p.label() else "Error", message);
    defer chip.end();
    const p = problem orelse return;
    const id = chat_id orelse return;
    const r = ui.div(c).row().pt(2);
    defer r.end();
    // `btn_primary` at px(10) py(5) rounded(7), 12 points.
    const b = ui.div(c).row().px(10).py(5).rounded(7).bg(k.solid);
    defer b.end();
    ui.text(c, p.actionLabel(), rows_st(c, 12, .{ .weight = .medium, .color = k.on_solid }));
    if (b.clicked()) @import("app_reauth.zig").signInForChat(a, id);
}

fn attachment(c: *ui.Context, k: theme.Colors, icon: icons.Name, label: []const u8) void {
    const row = ui.div(c).row().gap(6).itemsCenter();
    defer row.end();
    icons.icon(c, icon, 14, k.muted, 0);
    ui.text(c, label, .{ .size = 12, .color = k.muted });
}

fn system(c: *ui.Context, a: *App, k: theme.Colors, e: *const tr.Entry, at: At) void {
    for (e.parts.items) |*p| switch (p.kind) {
        .text => ui.text(c, p.text.items, kit.style(c, 12, 18, .{ .wrap = true, .color = k.faint })),
        .@"error" => errorPart(c, a, k, e, p, at),
        else => {},
    };
}
