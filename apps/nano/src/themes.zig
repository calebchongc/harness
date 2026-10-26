//! The built-in themes, as the GPUI app offers them: the catalog the phones
//! bundle (apps/ios/Harness/Theme/themes.json, which crates/theme's
//! `builtin_catalog_matches_ios_bundle` keeps in lockstep with the Rust
//! registry), each variant made nano's `theme.Colors` as
//! crates/ui/src/theme.rs derives its roles from the variant.
const std = @import("std");
const nanoui = @import("nanoui");
const Color = nanoui.ui.Color;
const theme = @import("theme.zig");
const json = std.json;

pub const Variant = struct {
    id: []const u8,
    family: []const u8,
    name: []const u8,
    dark: bool,
    colors: theme.Colors,
};

var loaded: ?[]const Variant = null;

/// Every variant, in the catalog's order (family by family).
pub fn all() []const Variant {
    if (loaded) |v| return v;
    loaded = parse(std.heap.page_allocator, @import("themes_json").json) catch &.{};
    return loaded.?;
}

pub fn find(id: []const u8) ?*const Variant {
    for (all()) |*v| if (std.mem.eql(u8, v.id, id)) return v;
    return null;
}

fn parse(gpa: std.mem.Allocator, text: []const u8) ![]const Variant {
    const doc = try json.parseFromSliceLeaky(json.Value, gpa, text, .{});
    var out: std.ArrayList(Variant) = .empty;
    const families = (doc.object.get("families") orelse return error.Catalog).array.items;
    for (families) |f| for ((f.object.get("variants") orelse continue).array.items) |v| {
        const o = v.object;
        const dark = std.mem.eql(u8, str(o, "appearance"), "dark");
        try out.append(gpa, .{
            .id = str(o, "id"),
            .family = str(o, "familyId"),
            .name = str(o, "name"),
            .dark = dark,
            .colors = derive(o, dark) orelse continue,
        });
    };
    return out.items;
}

fn str(o: json.ObjectMap, key: []const u8) []const u8 {
    const v = o.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

/// "#rrggbb" or "#rrggbbaa".
pub fn hex(s: []const u8) ?Color {
    if (s.len != 7 and s.len != 9 or s[0] != '#') return null;
    const n = std.fmt.parseInt(u32, s[1..], 16) catch return null;
    const rgba: u32 = if (s.len == 7) (n << 8) | 0xff else n;
    return .{
        .r = @as(f32, @floatFromInt((rgba >> 24) & 0xff)) / 255,
        .g = @as(f32, @floatFromInt((rgba >> 16) & 0xff)) / 255,
        .b = @as(f32, @floatFromInt((rgba >> 8) & 0xff)) / 255,
        .a = @as(f32, @floatFromInt(rgba & 0xff)) / 255,
    };
}

/// `top` laid over the opaque `base` as the GPU blends it: its alpha in
/// 8 bits, the result to the byte.
pub fn over(base: Color, top: Color) Color {
    const a = @round(top.a * 255) / 255;
    const ch = struct {
        fn f(b: f32, t: f32, al: f32) f32 {
            return @round((b + (t - b) * al) * 255) / 255;
        }
    };
    return .{ .r = ch.f(base.r, top.r, a), .g = ch.f(base.g, top.g, a), .b = ch.f(base.b, top.b, a), .a = 1 };
}

/// A variant's roles, as theme.rs's `apply_model` and the paint helpers
/// derive them (`wash`, `user_bubble_bg`, the composer's flattened input).
fn derive(o: json.ObjectMap, dark: bool) ?theme.Colors {
    const cs = (o.get("colors") orelse return null).object;
    const acc = (o.get("accent") orelse return null).object;
    const term = (o.get("terminal") orelse return null).object;
    const syn = (o.get("syntax") orelse return null).object;
    const col = struct {
        fn get(m: json.ObjectMap, key: []const u8) Color {
            const v = m.get(key) orelse return .{};
            return if (v == .string) hex(v.string) orelse .{} else .{};
        }
    };
    const white: Color = .{ .r = 1, .g = 1, .b = 1 };
    const black: Color = .{};
    // `wash`: near-white (hsl 0.92) in dark, near-black (0.10) in light.
    const wash: Color = if (dark) Color.hex(0xebebeb) else Color.hex(0x1a1a1a);
    const shell = col.get(cs, "shell");
    const background = col.get(cs, "background");
    const muted = col.get(cs, "textMuted");
    var glyph: [3]Color = .{ .{}, .{}, .{} };
    if (acc.get("glyph")) |g| if (g == .array) for (g.array.items[0..@min(3, g.array.items.len)], 0..) |c, i| {
        glyph[i] = if (c == .string) hex(c.string) orelse .{} else .{};
    };
    var ansi: [16]Color = @splat(.{});
    if (term.get("ansi")) |list| if (list == .array) for (list.array.items[0..@min(16, list.array.items.len)], 0..) |c, i| {
        ansi[i] = if (c == .string) hex(c.string) orelse .{} else .{};
    };
    // The Markdown hues come from the appearance's own palette
    // (`SyntaxPalette::dark`/`light`), which a variant's roles leave be.
    const base = theme.builtin(dark).syntax;
    return .{
        .dark = dark,
        .background = background,
        .shell = shell,
        .sidebar = over(shell, wash.alpha(0.05)),
        .raised = col.get(cs, "raised"),
        .text = col.get(cs, "text"),
        .muted = muted,
        .faint = col.get(cs, "textFaint"),
        .subline = over(shell, muted.alpha(0.5)),
        .accent = col.get(acc, "primary"),
        .accent_wash = col.get(acc, "wash"),
        .glyph = glyph,
        .danger = col.get(cs, "danger"),
        .danger_muted = col.get(cs, "dangerMuted"),
        .warning = col.get(cs, "warning"),
        .success = col.get(cs, "success"),
        .success_muted = col.get(cs, "successMuted"),
        .border = col.get(cs, "border"),
        .border_strong = col.get(cs, "borderStrong"),
        .hover = col.get(cs, "hover"),
        .selected = wash.alpha(if (dark) 0.11 else 0.06),
        .user_bubble = over(shell, wash.alpha(if (dark) 0.08 else 0.04)),
        .composer = over(background, col.get(cs, "input")),
        .code_bg = (if (dark) white else black).alpha(0.035),
        .code_header = (if (dark) white else black).alpha(0.02),
        .tone = if (dark) white else black,
        .ansi = ansi,
        .solid = col.get(cs, "solid"),
        .on_solid = col.get(cs, "onSolid"),
        .diff_add = col.get(cs, "diffAdd"),
        .diff_del = col.get(cs, "diffDelete"),
        .syntax = .{
            .comment = col.get(syn, "comment"),
            .keyword = col.get(syn, "keyword"),
            .string = col.get(syn, "string"),
            .number = col.get(syn, "number"),
            .type = col.get(syn, "type"),
            .function = col.get(syn, "function"),
            .property = col.get(syn, "property"),
            .variable = col.get(syn, "variable"),
            .punctuation = col.get(syn, "punctuation"),
            .tag = col.get(syn, "tag"),
            .attribute = col.get(syn, "attribute"),
            .invalid = col.get(syn, "invalid"),
            .markup_heading = base.markup_heading,
            .markup_raw = base.markup_raw,
            .markup_link = base.markup_link,
            .markup_reference = base.markup_reference,
            .markup_emphasis = base.markup_emphasis,
            .markup_strong = base.markup_strong,
        },
    };
}

const testing = std.testing;

fn same(a: Color, b: Color) bool {
    const near = struct {
        fn f(x: f32, y: f32) bool {
            return @abs(x - y) <= 1.5 / 255.0;
        }
    };
    return near.f(a.r, b.r) and near.f(a.g, b.g) and near.f(a.b, b.b) and near.f(a.a, b.a);
}

test "the catalog's Codegraff derives the palette nano draws Codegraff in" {
    inline for (.{ .{ "codegraff-dark", true }, .{ "codegraff-light", false } }) |t| {
        const v = find(t[0]) orelse return error.Missing;
        const want = theme.builtin(t[1]);
        const info = @typeInfo(theme.Colors).@"struct";
        inline for (info.field_names, info.field_types) |name, T| {
            const got = @field(v.colors, name);
            const exp = @field(want, name);
            switch (T) {
                Color => if (!same(got, exp)) {
                    std.debug.print("{s}.{s}: {any} != {any}\n", .{ t[0], name, got, exp });
                    return error.Differs;
                },
                [3]Color, [16]Color => for (got, exp) |g, e| if (!same(g, e)) {
                    std.debug.print("{s}.{s}\n", .{ t[0], name });
                    return error.Differs;
                },
                else => {},
            }
        }
    }
}

test "every built-in variant is offered, Codegraff among them" {
    try testing.expect(all().len >= 30);
    var light: usize = 0;
    for (all()) |v| if (!v.dark) {
        light += 1;
    };
    try testing.expect(light >= 10);
    try testing.expectEqualStrings("Codegraff Dark", find("codegraff-dark").?.name);
}
