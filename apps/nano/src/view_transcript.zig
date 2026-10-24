//! The open chat's transcript: the user's messages as bubbles on the right,
//! the agent's text, its reasoning faint, each tool call on a line of its
//! own with how it went. It follows the end while the reader is there.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const tr = @import("transcript.zig");
const App = @import("app.zig").App;

/// Reasoning shows its first lines only; the rest is the agent's own.
const reasoning_cap = 600;

pub fn transcript(c: *ui.Context, a: *App, k: theme.Colors) void {
    ui.scroll(c, .{ .grow = 1, .width = .fill, .padding = .xy(28, 12), .gap = 16, .follow_end = true });
    defer ui.end(c);
    if (a.selected == null) return empty(c, k, "Pick a chat, or write below to start one.");
    if (a.transcript.entries.items.len == 0)
        return empty(c, k, if (a.w_doc.id != null) "Loading…" else "Nothing here yet.");
    for (a.transcript.entries.items) |*e| {
        ui.key(c, c.print("entry-{s}", .{e.id}));
        switch (e.role) {
            .user => user(c, k, e),
            .assistant => assistant(c, k, e),
            .system => system(c, k, e),
        }
    }
}

fn empty(c: *ui.Context, k: theme.Colors, text: []const u8) void {
    const box = ui.div(c).column().wFull().pt(80).itemsCenter();
    defer box.end();
    ui.text(c, text, .{ .color = k.muted });
}

fn user(c: *ui.Context, k: theme.Colors, e: *const tr.Entry) void {
    const row = ui.div(c).row().wFull().justifyEnd();
    defer row.end();
    const bubble = ui.div(c).column().maxW(620).bg(k.raised).rounded(14).px(14).py(9).gap(6);
    defer bubble.end();
    for (e.parts.items) |*p| switch (p.kind) {
        .text => ui.text(c, p.text.items, .{ .wrap = true, .color = k.text, .leading = 1.3 }),
        .image => attachment(c, k, "photo", p.text.items),
        else => {},
    };
}

fn assistant(c: *ui.Context, k: theme.Colors, e: *const tr.Entry) void {
    const col = ui.div(c).column().wFull().maxW(820).gap(8);
    defer col.end();
    for (e.parts.items) |*p| {
        ui.key(c, c.print("part-{s}-{s}", .{ e.id, p.id }));
        switch (p.kind) {
            .text => @import("view_markdown.zig").markdown(c, k, p.text.items),
            .reasoning => {
                const t = p.text.items;
                const shown = t[0..@min(t.len, reasoning_cap)];
                ui.text(c, if (shown.len < t.len) c.print("{s}…", .{shown}) else shown, .{ .wrap = true, .italic = true, .size = 12.5, .color = k.faint, .leading = 1.35 });
            },
            .tool => tool(c, k, p),
            .@"error" => ui.text(c, p.text.items, .{ .wrap = true, .color = k.danger }),
            .image => attachment(c, k, "photo", p.text.items),
            .visual => attachment(c, k, "chart.bar", p.text.items),
            .delegation => attachment(c, k, "person.2", "Delegated to a subagent"),
            .input => attachment(c, k, "questionmark.bubble", if (p.resolved) "Question answered" else "The agent is asking a question"),
            .other => {},
        }
    }
    if (e.status == .streaming and e.parts.items.len == 0) ui.text(c, "…", .{ .color = k.muted });
    if (e.status == .aborted) ui.text(c, "Stopped", .{ .size = 11, .color = k.faint });
}

fn tool(c: *ui.Context, k: theme.Colors, p: *const tr.Part) void {
    const row = ui.div(c).row().wFull().gap(8).itemsCenter().px(10).py(6).rounded(8).bg(k.card).border(k.border).borderW(1).clip();
    defer row.end();
    const icon, const color = if (!p.resolved)
        .{ "circle.dotted", k.accent }
    else if (p.is_error)
        .{ "xmark.circle", k.danger }
    else
        .{ "checkmark.circle", k.success };
    ui.icon(c, icon, .{ .size = 12, .frame = 16, .color = color });
    const line = p.text.items[0 .. std.mem.indexOfScalar(u8, p.text.items, '\n') orelse p.text.items.len];
    ui.text(c, line[0..@min(line.len, 160)], .{ .mono = true, .size = 12, .color = k.muted });
}

fn attachment(c: *ui.Context, k: theme.Colors, icon: []const u8, label: []const u8) void {
    const row = ui.div(c).row().gap(6).itemsCenter();
    defer row.end();
    ui.icon(c, icon, .{ .size = 12, .frame = 16, .color = k.muted });
    ui.text(c, label, .{ .size = 12, .color = k.muted });
}

fn system(c: *ui.Context, k: theme.Colors, e: *const tr.Entry) void {
    for (e.parts.items) |*p| if (p.kind == .text or p.kind == .@"error")
        ui.text(c, p.text.items, .{ .wrap = true, .size = 12, .color = if (p.kind == .@"error") k.danger else k.faint });
}
