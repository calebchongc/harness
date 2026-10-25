//! Pieces the window's regions share: text at an exact line height, the
//! square icon buttons of the title bar and sidebar, a title that fades at
//! its right edge instead of being cut, and the "snake" spinner a working
//! session shows.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const icons = @import("icons.zig");
const theme = @import("theme.zig");

/// A text style of `size` points whose lines are `line` points tall, as
/// the GPUI app sets them (14 px text on 22 px lines).
pub fn style(c: *ui.Context, size: f32, line: f32, base: ui.TextStyle) ui.TextStyle {
    var s = base;
    s.size = size;
    s.leading = 1;
    const natural = c.text.lineHeight(s);
    s.leading = if (natural > 0) line / natural else 1;
    return s;
}

pub const IconButton = struct {
    size: f32 = 24,
    radius: f32 = 6,
    icon: f32 = 16,
    color: ?ui.Color = null,
    /// Drawn behind it while its menu or panel is open.
    on: bool = false,
    disabled: bool = false,
};

/// A square button holding one icon; true when clicked.
pub fn iconButton(c: *ui.Context, k: theme.Colors, name: icons.Name, o: IconButton) bool {
    var b = ui.div(c).row().size(o.size, o.size).center().rounded(o.radius);
    if (o.on) b = b.bg(k.hover) else if (!o.disabled) b = b.hover(k.hover);
    defer b.end();
    const clicked = b.clicked() and !o.disabled;
    const color = o.color orelse k.muted;
    icons.icon(c, name, o.icon, if (o.disabled) color.alpha(color.a * 0.35) else color, 0);
    return clicked;
}

/// `s` in one line at most `max_w` wide: as is when it fits, else cut and
/// faded over its last 20 points (`fade_title`, crates/ui/src/shell.rs).
pub fn fadeText(c: *ui.Context, s: []const u8, st: ui.TextStyle, max_w: f32) void {
    const base = st.color orelse c.theme.text;
    if (max_w <= 0) return;
    const total = c.text.width(s, st);
    if (total <= max_w) return ui.text(c, s, st);
    // GPUI's `edge_faded` label: a 20-point ramp to the box's right edge,
    // pushed out past it while the text barely overflows
    // (`label_fade_outset`), the glyph cut by the box. GPUI fades each
    // pixel; here each glyph takes the alpha at its middle.
    const band: f32 = 20;
    const p = std.math.clamp((total - max_w) / band, 0, 1);
    const right = max_w + band * (1 - p * p * (3 - 2 * p));
    var spans: std.ArrayList(ui.Span) = .empty;
    var at: usize = 0;
    var x0: f32 = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |cp| {
        if (x0 >= max_w) break;
        const x1 = c.text.width(s[0 .. at + cp.len], st);
        const t = std.math.clamp((right - (x0 + x1) / 2) / band, 0, 1);
        if (t < 1) spans.append(c.alloc(), .{ .start = @intCast(at), .end = @intCast(at + cp.len), .color = base.alpha(base.a * t) }) catch break;
        at += cp.len;
        x0 = x1;
    }
    const box = ui.div(c).row().w(max_w).clip();
    defer box.end();
    var plain = st;
    plain.color = base;
    ui.richText(c, s[0..at], spans.items, plain);
}

/// `s` in one line at most `max_w` wide, cut with an ellipsis (the tab
/// list's titles).
pub fn ellipsisText(c: *ui.Context, s: []const u8, st: ui.TextStyle, max_w: f32) void {
    if (c.text.width(s, st) <= max_w) return ui.text(c, s, st);
    ui.text(c, c.print("{s}…", .{s[0..truncateAt(c, s, st, max_w)]}), st);
}

/// Where GPUI cuts `s` for an ellipsis (`LineWrapper::should_truncate_line`):
/// each character's own width added up, the cut at the last character
/// before which the text and the ellipsis still come in under `max_w`.
pub fn truncateAt(c: *ui.Context, s: []const u8, st: ui.TextStyle, max_w: f32) usize {
    const suffix = c.text.width("…", st);
    var width: f32 = 0;
    var cut: usize = 0;
    var at: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepointSlice()) |cp| {
        if (width + suffix < max_w) cut = at;
        width += c.text.width(cp, st);
        if (@floor(width) > max_w) return cut;
        at += cp.len;
    }
    return s.len;
}

/// The 2×3 "snake" a working session shows: rows in the accent's three
/// tones, lit clockwise at 15 Hz (`loaders.rs`). Asks for its next frame.
pub fn snake(c: *ui.Context, k: theme.Colors) void {
    const order = [_][2]u8{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 1, 2 }, .{ 0, 2 }, .{ 0, 1 } };
    const step: usize = @intFromFloat(@mod(@floor(c.time * 15), 6));
    const box = ui.div(c).column().size(5, 8).gap(1);
    defer box.end();
    for (0..3) |row| {
        const r = ui.div(c).row().gap(1);
        defer r.end();
        for (0..2) |col| {
            var lit: f32 = 0.22;
            for (0..3) |back| {
                const p = order[(step + 6 - back) % 6];
                if (p[0] == col and p[1] == row) {
                    lit = @max(lit, 1.0 - @as(f32, @floatFromInt(back)) * 0.3);
                }
            }
            _ = c.leaf(.{ .width = .{ .px = 2 }, .height = .{ .px = 2 }, .background = k.glyph[row].alpha(lit) }, .none, null);
        }
    }
    c.frameIn(1.0 / 15.0);
}

/// A small round dot.
pub fn dot(c: *ui.Context, size: f32, color: ui.Color) void {
    _ = c.leaf(.{ .width = .{ .px = size }, .height = .{ .px = size }, .radius = size / 2, .background = color }, .none, null);
}

/// GPUI's `shadow_lg` (Tailwind's): two faint layers, with a nanoui that
/// has layered shadows (justrach/nanoui#21); its own large one before.
/// A right-click on `d` (its context menu), with a nanoui that has them
/// (justrach/nanoui secondary clicks); never, before.
pub fn secondaryClicked(d: ui.Div) bool {
    if (comptime @hasDecl(ui.Div, "secondaryClicked")) return d.secondaryClicked();
    return false;
}

pub fn shadowLg(d: ui.Div) ui.Div {
    if (comptime @hasDecl(ui.Shadow, "lg")) return d.shadows(&ui.Shadow.lg);
    return d.shadowLg();
}
