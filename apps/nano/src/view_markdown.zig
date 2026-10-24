//! An agent's Markdown, drawn: paragraphs with bold, italics, inline code
//! and links in place; headings; lists with hanging markers and task
//! boxes; quotes with a bar; tables in a grid; code in a panel with its
//! language, syntax colors and a copy button. After nanoterm's
//! view_markdown.zig (markdown.zig, markdown_html.zig and highlight.zig
//! are nanoterm's, unchanged), without its pictures and diagrams: a
//! picture shows as its alt text.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const md = @import("markdown.zig");
const highlight = @import("highlight.zig");

/// Prose: its size and line spacing.
pub const body: ui.TextStyle = .{ .size = 14, .leading = 1.5, .wrap = true };

/// The colors of the Markdown being drawn (the UI thread draws one at a time).
var k: theme.Colors = undefined;

/// Draws the Markdown `src`.
pub fn markdown(c: *ui.Context, colors: theme.Colors, src: []const u8) void {
    k = colors;
    const blocks = md.parse(c.alloc(), src, .{ .code = k.accent, .code_bg = k.code_inline_bg, .link = k.accent, .muted = k.muted });
    const col = ui.div(c).column().wFull();
    defer col.end();
    for (blocks, 0..) |b, i| {
        // Items of a list sit close; other blocks get room.
        if (i > 0) {
            const tight = b == .item and blocks[i - 1] == .item;
            _ = c.leaf(.{ .height = .{ .px = if (tight) 3 else 12 } }, .none, null);
        }
        ui.key(c, c.print("md-{d}", .{i}));
        block(c, b, i == 0);
    }
}

fn rich(c: *ui.Context, in: md.Inline, style: ui.TextStyle) void {
    var st = style;
    if (st.color == null) st.color = k.text;
    ui.richText(c, in.text, in.spans, st);
}

fn block(c: *ui.Context, b: md.Block, first: bool) void {
    switch (b) {
        .paragraph => |in| rich(c, in, body),
        .heading => |h| {
            if (!first) _ = c.leaf(.{ .height = .{ .px = if (h.level <= 2) 6 else 2 } }, .none, null);
            var st = body;
            st.size = switch (h.level) {
                1 => 19,
                2 => 16.5,
                3 => 15,
                else => 14,
            };
            st.leading = 1.3;
            st.weight = if (h.level <= 2) .bold else .semibold;
            rich(c, h.text, st);
            if (h.level == 1) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null);
        },
        .item => |it| item(c, it),
        .quote => |in| {
            const r = ui.div(c).row().wFull().gap(12);
            defer r.end();
            _ = c.leaf(.{ .width = .{ .px = 3 }, .height = .fill, .radius = 1.5, .background = k.quote.alpha(0.45) }, .none, null);
            var st = body;
            st.color = k.muted;
            st.italic = true;
            const box = ui.div(c).column().grow();
            defer box.end();
            rich(c, in, st);
        },
        .rule => _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = k.border }, .none, null),
        .code => |code| codeBlock(c, code.lang, code.text),
        .table => |t| table(c, t.header, t.rows),
    }
}

fn item(c: *ui.Context, it: @FieldType(md.Block, "item")) void {
    const r = ui.div(c).row().wFull().gap(8).pl(@as(f32, @floatFromInt(it.depth)) * 20);
    defer r.end();
    {
        // The marker's column: a fixed width, so wrapped lines hang.
        const m = ui.div(c).row().w(if (it.marker.len > 2) 26 else 16).h(c.text.lineHeight(body)).itemsCenter();
        defer m.end();
        if (it.task) |done| {
            ui.icon(c, if (done) "checkmark.circle.fill" else "circle", .{ .size = 13, .color = if (done) k.success else k.muted });
        } else if (std.mem.eql(u8, it.marker, "•")) {
            _ = c.leaf(.{ .width = .{ .px = 5 }, .height = .{ .px = 5 }, .radius = 2.5, .background = k.muted, .offset = .{ .x = 4 } }, .none, null);
        } else {
            ui.text(c, it.marker, .{ .size = 13, .color = k.muted });
        }
    }
    const box = ui.div(c).column().grow();
    defer box.end();
    var st = body;
    if (it.task == true) st.color = k.muted;
    rich(c, it.text, st);
}

fn codeBlock(c: *ui.Context, lang: []const u8, src: []const u8) void {
    const box = ui.div(c).column().wFull().p(1).bg(k.code_bg).rounded(10).border(k.border).clip();
    defer box.end();
    {
        const h = ui.div(c).row().wFull().px(12).py(6).gap(8).itemsCenter().bg(k.code_header);
        defer h.end();
        ui.text(c, if (lang.len > 0) lang else "code", .{ .size = 11.5, .weight = .medium, .color = k.muted });
        ui.spacer(c);
        if (ui.button(c, "Copy", .{ .variant = .ghost, .size = 11.5, .icon = "doc.on.doc" }).clicked) c.clipboard.write(c.clipboard.ctx, src);
    }
    const s = k.syntax;
    const pal: highlight.Palette = .{ .comment = s[0], .keyword = s[1], .string = s[2], .number = s[3], .type = s[4], .call = s[5] };
    const lines = ui.div(c).column().wFull().px(14).py(10).gap(0);
    defer lines.end();
    var in_block = false;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| {
        const spans = highlight.line(c.alloc(), l, lang, pal, &in_block);
        ui.richText(c, if (l.len == 0) " " else l, spans, .{ .size = 12.5, .mono = true, .wrap = true, .leading = 1.35, .color = k.text });
    }
}

fn table(c: *ui.Context, header: []const md.Inline, rows: []const []const md.Inline) void {
    const box = ui.div(c).column().wFull().p(1).rounded(8).border(k.border).clip();
    defer box.end();
    tableRow(c, header, true, false);
    for (rows, 0..) |r, i| tableRow(c, r, false, i % 2 == 1);
}

fn tableRow(c: *ui.Context, cells: []const md.Inline, head: bool, zebra: bool) void {
    var r = ui.div(c).row().wFull();
    if (head) r = r.bg(k.code_header) else if (zebra) r = r.bg(k.zebra);
    defer r.end();
    for (cells) |cell| {
        const d = ui.div(c).column().wFull().px(10).py(6);
        defer d.end();
        var st = body;
        st.size = 13;
        st.leading = 1.35;
        if (head) st.weight = .semibold;
        rich(c, cell, st);
    }
}
