//! Rules the sidebar and composer share with the GPUI app, as pure
//! functions: when a row's time reads "now" or "3d"
//! (crates/proto/src/view.rs), a project's monogram and its colour
//! (crates/ui/src/shell/project_icon.rs), and a reasoning level's label.
const std = @import("std");
const Color = @import("nanoui").ui.Color;

/// Milliseconds since the epoch for an RFC 3339 time in UTC
/// ("2026-10-24T12:59:20.412Z", or with an offset), else null.
pub fn parseTime(s: []const u8) ?i64 {
    if (s.len < 19 or s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != ' ') or s[13] != ':' or s[16] != ':') return null;
    const n = struct {
        fn n(t: []const u8) ?i64 {
            return std.fmt.parseInt(i64, t, 10) catch null;
        }
    }.n;
    const y = n(s[0..4]) orelse return null;
    const mo = n(s[5..7]) orelse return null;
    const d = n(s[8..10]) orelse return null;
    const h = n(s[11..13]) orelse return null;
    const mi = n(s[14..16]) orelse return null;
    const sec = n(s[17..19]) orelse return null;
    var i: usize = 19;
    var ms: i64 = 0;
    if (i < s.len and s[i] == '.') {
        i += 1;
        var scale: i64 = 100;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            ms += (s[i] - '0') * scale;
            scale = @divTrunc(scale, 10);
        }
    }
    var offset_min: i64 = 0;
    if (i < s.len and (s[i] == '+' or s[i] == '-') and s.len >= i + 6) {
        const oh = n(s[i + 1 .. i + 3]) orelse return null;
        const om = n(s[i + 4 .. i + 6]) orelse return null;
        offset_min = (oh * 60 + om) * (if (s[i] == '-') @as(i64, -1) else 1);
    }
    // Days from the civil date (Howard Hinnant's algorithm).
    const yy = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(mo + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return ((days * 24 + h) * 60 + mi - offset_min) * 60_000 + sec * 1000 + ms;
}

/// How long ago, as a session row reads it: "now", "5m", "2h", "3d", "2w",
/// "4mo", "1y" (`relative_time`).
pub fn relativeTime(buf: []u8, now_ms: i64, then_ms: i64) []const u8 {
    const s = @divFloor(@max(now_ms - then_ms, 0), 1000);
    const m = @divFloor(s, 60);
    const h = @divFloor(m, 60);
    const d = @divFloor(h, 24);
    const out = if (s < 60)
        std.fmt.bufPrint(buf, "now", .{})
    else if (m < 60)
        std.fmt.bufPrint(buf, "{d}m", .{m})
    else if (h < 24)
        std.fmt.bufPrint(buf, "{d}h", .{h})
    else if (d < 7)
        std.fmt.bufPrint(buf, "{d}d", .{d})
    else if (d < 35)
        std.fmt.bufPrint(buf, "{d}w", .{@divFloor(d, 7)})
    else if (@divFloor(d, 30) < 12)
        std.fmt.bufPrint(buf, "{d}mo", .{@divFloor(d, 30)})
    else
        std.fmt.bufPrint(buf, "{d}y", .{@divFloor(d, 365)});
    return out catch "";
}

/// The monogram palette: slate, blue, violet, rose, amber, emerald, teal,
/// orange; dark then light.
const palette = [8][2]u24{
    .{ 0x94a3b8, 0x475569 }, .{ 0x93c5fd, 0x2563eb }, .{ 0xc4b5fd, 0x7c3aed }, .{ 0xfda4af, 0xbe123c },
    .{ 0xfcd34d, 0xa16207 }, .{ 0x6ee7b7, 0x047857 }, .{ 0x5eead4, 0x0f766e }, .{ 0xfdba74, 0xc2410c },
};

pub const Monogram = struct { letter: u8, color: Color };

/// A project's badge without artwork: its name's first letter, and a
/// colour picked by FNV-1a of its path ("home" without a project).
pub fn monogram(name: []const u8, path: ?[]const u8, dark: bool) Monogram {
    const seed = path orelse "home";
    var hash: u32 = 2166136261;
    for (seed) |b| {
        hash ^= b;
        hash *%= 16777619;
    }
    const first = if (name.len > 0) name[0] else 'H';
    return .{
        .letter = std.ascii.toUpper(first),
        .color = .hex(palette[hash % 8][if (dark) 0 else 1]),
    };
}

/// `c` with its HSL lightness moved by `dl`, kept within [lo, hi] (the
/// GPUI app's `hsla.l` edits).
pub fn shiftLightness(c: Color, dl: f32, lo: f32, hi: f32) Color {
    const mx = @max(c.r, @max(c.g, c.b));
    const mn = @min(c.r, @min(c.g, c.b));
    const l = (mx + mn) / 2;
    const d = mx - mn;
    var h: f32 = 0;
    var sat: f32 = 0;
    if (d > 0) {
        sat = d / (1 - @abs(2 * l - 1));
        h = if (mx == c.r) @mod((c.g - c.b) / d, 6) else if (mx == c.g) (c.b - c.r) / d + 2 else (c.r - c.g) / d + 4;
        h /= 6;
    }
    const nl = if (dl >= 0) @min(l + dl, hi) else @max(l + dl, lo);
    const q = (1 - @abs(2 * nl - 1)) * sat;
    const x = q * (1 - @abs(@mod(h * 6, 2) - 1));
    const m = nl - q / 2;
    const rgb: [3]f32 = switch (@as(u3, @intFromFloat(@min(5, @floor(h * 6))))) {
        0 => .{ q, x, 0 },
        1 => .{ x, q, 0 },
        2 => .{ 0, q, x },
        3 => .{ 0, x, q },
        4 => .{ x, 0, q },
        else => .{ q, 0, x },
    };
    return .{ .r = rgb[0] + m, .g = rgb[1] + m, .b = rgb[2] + m, .a = c.a };
}

/// A reasoning level as the model chip names it.
pub fn reasoningLabel(level: []const u8) []const u8 {
    const pairs = .{
        .{ "none", "Off" },        .{ "minimal", "Minimal" }, .{ "low", "Low" },
        .{ "medium", "Medium" },   .{ "high", "High" },       .{ "xhigh", "X-High" },
        .{ "max", "Max" },         .{ "ultra", "Ultra" },     .{ "ultracode", "Ultracode" },
        .{ "ultrathink", "Ultrathink" },
    };
    inline for (pairs) |p| if (std.mem.eql(u8, level, p[0])) return p[1];
    return level;
}

const testing = std.testing;

test "lightness moves in HSL, hue and saturation kept" {
    const c = shiftLightness(.hex(0x3a8a5c), 0.12, 0.15, 0.95);
    // #3a8a5c is hsl(145°, 41%, 38.4%); +0.12 gives about #4db479.
    try testing.expectApproxEqAbs(@as(f32, 0x4d) / 255, c.r, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0xb4) / 255, c.g, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0x79) / 255, c.b, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.95), shiftLightness(.white, 0.12, 0.15, 0.95).r, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.15), shiftLightness(.black, -0.10, 0.15, 0.95).r, 0.001);
}

test "times parse in UTC and with offsets" {
    try testing.expectEqual(@as(?i64, 0), parseTime("1970-01-01T00:00:00Z"));
    try testing.expectEqual(@as(?i64, 1_792_846_760_412), parseTime("2026-10-24T12:59:20.412Z"));
    try testing.expectEqual(parseTime("2026-10-24T12:59:20Z"), parseTime("2026-10-24T20:59:20+08:00"));
    try testing.expectEqual(@as(?i64, null), parseTime("yesterday"));
}

test "relative time reads as the sidebar's" {
    var b: [16]u8 = undefined;
    const now: i64 = 10_000_000_000;
    const cases = .{
        .{ 59, "now" },        .{ 60, "1m" },                  .{ 3599, "59m" },
        .{ 3600, "1h" },       .{ 86_400 * 6, "6d" },          .{ 86_400 * 7, "1w" },
        .{ 86_400 * 34, "4w" }, .{ 86_400 * 35, "1mo" },       .{ 86_400 * 400, "1y" },
    };
    inline for (cases) |cse| try testing.expectEqualStrings(cse[1], relativeTime(&b, now, now - cse[0] * 1000));
}

test "a monogram is the name's letter in a colour fixed by the path" {
    const a = monogram("web-dashboard", "/w/web-dashboard", true);
    try testing.expectEqual(@as(u8, 'W'), a.letter);
    const b = monogram("web-dashboard", "/w/web-dashboard", true);
    try testing.expectEqual(a.color, b.color);
    try testing.expectEqual(@as(u8, 'H'), monogram("", null, false).letter);
}

test "reasoning labels" {
    try testing.expectEqualStrings("Medium", reasoningLabel("medium"));
    try testing.expectEqualStrings("X-High", reasoningLabel("xhigh"));
}
