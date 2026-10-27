//! Embed Harness's file-theme artwork and compile its manifest into lookup
//! tables. No JSON parsing, SVG rewriting or persistent allocation in the app.
const std = @import("std");

pub fn module(b: *std.Build) *std.Build.Module {
    const files = b.addWriteFiles();
    const manifest = std.json.parseFromSlice(std.json.Value, b.allocator, read(b, "../../crates/ui/src/file-icons.json"), .{}) catch @panic("invalid file-icon manifest");
    const root = manifest.value.object;
    var definitions: std.StringHashMap(u16) = .init(b.allocator);
    var source: std.ArrayList(u8) = .empty;
    append(b, &source,
        \\const std = @import("std");
        \\pub const Asset = struct { path: []const u8, light: []const u8, dark: []const u8 };
        \\pub const assets = [_]Asset{
        \\
    );
    var it = root.get("iconDefinitions").?.object.iterator();
    while (it.next()) |entry| {
        const icon_path = entry.value_ptr.object.get("iconPath").?.string;
        if (!std.mem.startsWith(u8, icon_path, "./icons/")) @panic("invalid file-icon asset path");
        const path = icon_path["./icons/".len..];
        const input = b.fmt("../../crates/ui/assets/file-icons/{s}", .{path});
        const light = b.fmt("light/{s}", .{path});
        _ = files.addCopyFile(b.path(input), light);
        const svg = read(b, input);
        const dark_svg = darkSvg(b, svg);
        const dark = if (std.mem.eql(u8, svg, dark_svg)) light else b.fmt("dark/{s}", .{path});
        if (!std.mem.eql(u8, svg, dark_svg)) _ = files.add(dark, dark_svg);
        append(b, &source, b.fmt("    .{{ .path = {s}, .light = @embedFile({s}), .dark = @embedFile({s}) }},\n", .{ quote(b, path), quote(b, light), quote(b, dark) }));
        definitions.put(entry.key_ptr.*, @intCast(definitions.count())) catch @panic("OOM");
    }
    append(b, &source, "};\n");
    for ([_][2][]const u8{ .{ "fileNames", "names" }, .{ "fileExtensions", "extensions" }, .{ "folderNames", "folders" } }) |table| {
        append(b, &source, b.fmt("pub const {s} = blk: {{\n    @setEvalBranchQuota(200000);\n    break :blk std.StaticStringMapWithEql(u16, std.ascii.eqlIgnoreCase).initComptime(.{{\n", .{table[1]}));
        var entries = root.get(table[0]).?.object.iterator();
        while (entries.next()) |entry| {
            if (definition(&definitions, entry.value_ptr.string)) |id|
                append(b, &source, b.fmt("        .{{ {s}, {d} }},\n", .{ quote(b, entry.key_ptr.*), id }));
        }
        append(b, &source, "    });\n};\n");
    }
    append(b, &source, b.fmt("pub const file: u16 = {d};\npub const folder: u16 = {d};\n", .{
        definition(&definitions, root.get("file").?.string).?,
        definition(&definitions, root.get("folder").?.string).?,
    }));
    return b.createModule(.{ .root_source_file = files.add("file_icons_data.zig", source.items) });
}

fn definition(definitions: *const std.StringHashMap(u16), name: []const u8) ?u16 {
    // The same upstream aliases as crates/ui/src/file_icons.rs.
    const alias = if (std.mem.eql(u8, name, "less")) "brackets-sky" else if (std.mem.eql(u8, name, "yml")) "yaml" else name;
    return definitions.get(alias);
}

fn read(b: *std.Build, path: []const u8) []const u8 {
    const full = b.root.joinString(b.allocator, path) catch @panic("OOM");
    return std.Io.Dir.cwd().readFileAlloc(b.graph.io, full, b.allocator, .limited(8 << 20)) catch @panic("cannot read bundled file icons");
}

fn quote(b: *std.Build, text: []const u8) []const u8 {
    return std.json.Stringify.valueAlloc(b.allocator, text, .{}) catch @panic("OOM");
}

fn append(b: *std.Build, source: *std.ArrayList(u8), text: []const u8) void {
    source.appendSlice(b.allocator, text) catch @panic("OOM");
}

fn darkSvg(b: *std.Build, source: []const u8) []const u8 {
    // GPUI's dark_icon_svg palette: lift dark accents, never tint the artwork.
    var svg = source;
    for ([_][2][]const u8{
        .{ "#64748B", "#CBD5E1" }, .{ "#71717A", "#D4D4D8" },
        .{ "#2563EB", "#60A5FA" }, .{ "#EA580C", "#FB923C" },
        .{ "#16A34A", "#4ADE80" }, .{ "#8B5CF6", "#A78BFA" },
        .{ "#A855F7", "#C084FC" },
    }) |pair| {
        svg = std.mem.replaceOwned(u8, b.allocator, svg, pair[0], pair[1]) catch @panic("OOM");
        const lower = std.ascii.allocLowerString(b.allocator, pair[0]) catch @panic("OOM");
        svg = std.mem.replaceOwned(u8, b.allocator, svg, lower, pair[1]) catch @panic("OOM");
    }
    return svg;
}
