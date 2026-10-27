//! The GPUI app's Symbols file/folder theme, from its original manifest and
//! SVGs. Resolve names without allocating; rasterize only identities shown.
const std = @import("std");
const ui = @import("nanoui").ui;
const data = @import("file_icons_data");

pub fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[slash + 1 ..];
}

pub fn asset(path: []const u8, directory: bool) *const data.Asset {
    const name = basename(path);
    if (directory) return &data.assets[data.folders.get(name) orelse data.folder];
    if (data.names.get(name)) |id| return &data.assets[id];
    // Exact names win; the earliest dot gives the longest compound suffix.
    for (name, 0..) |ch, i| if (ch == '.' and i + 1 < name.len) {
        if (data.extensions.get(name[i + 1 ..])) |id| return &data.assets[id];
    };
    return &data.assets[data.file];
}

pub fn icon(c: *ui.Context, path: []const u8, directory: bool, dark: bool, size: f32) void {
    const identity = asset(path, directory);
    _ = ui.svg(c, .{
        .key = c.print("file-icons/{s}{s}", .{ if (dark) "dark/" else "", identity.path }),
        .bytes = if (dark) identity.dark else identity.light,
        .size = size,
        // No monochrome tint: keep the authored colors as GPUI's img does.
    });
}

test "file identities use Harness's exact names, compound extensions and fallbacks" {
    const cases = [_][2][]const u8{
        .{ "/work/demo/README.md", "files/markdown.svg" },
        .{ "C:\\demo\\MAIN.RS", "files/rust.svg" },
        .{ "main.zig", "files/zig.svg" },
        .{ "TSCONFIG.JSON", "files/tsconfig.svg" },
        .{ ".prettierrc.json", "files/prettier.svg" },
        .{ "test.ts", "files/ts-test.svg" },
        .{ "widget.test.ts", "files/ts-test.svg" },
        .{ "widget.ts", "files/ts.svg" },
        .{ "style.less", "files/brackets-sky.svg" },
        .{ "config.yml", "files/yaml.svg" },
        .{ "unknown.synthetic-extension", "files/document.svg" },
        .{ "trailing.", "files/document.svg" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case[1], asset(case[0], false).path);
    try std.testing.expectEqualStrings("folders/folder-orange-code.svg", asset("/work/demo/SRC", true).path);
    try std.testing.expectEqualStrings("folders/folder.svg", asset("other", true).path);
}

fn sheet(dark: *bool, c: *ui.Context) void {
    const row = ui.div(c).row().gap(4);
    defer row.end();
    for ([_][]const u8{ "main.rs", "main.zig", "main.ts", "README.md", "unknown" }) |path|
        icon(c, path, false, dark.*, 14);
    icon(c, "src", true, dark.*, 14);
}

test "identity SVGs keep their colors, density, dark palette and cache" {
    for ([_]f32{ 1, 2 }) |scale| {
        var dark = false;
        var t: ui.Tester = undefined;
        try t.init(std.testing.allocator, .init(&dark, sheet), .{ .scale = scale });
        defer t.deinit();
        for ([_]bool{ false, true }) |appearance| {
            dark = appearance;
            t.frame();
            var count: usize = 0;
            for (t.ctx.nodes.items) |node| switch (node.content) {
                .image => |im| {
                    try std.testing.expect(im.tint == null);
                    const decoded = t.text.images.decoded.get(im.key).?.?;
                    try std.testing.expectEqual(@as(u32, @intFromFloat(14 * scale)), decoded.width);
                    try std.testing.expectEqual(decoded.width, decoded.height);
                    try std.testing.expectEqual(@as(f32, 14), node.rect.w);
                    count += 1;
                },
                else => {},
            };
            try std.testing.expectEqual(@as(usize, 6), count);
            const cached = t.text.images.decoded.count();
            t.frame();
            try std.testing.expectEqual(cached, t.text.images.decoded.count());
        }
    }
    const rust = asset("main.rs", false);
    try std.testing.expect(!std.mem.eql(u8, rust.light, rust.dark));
}
