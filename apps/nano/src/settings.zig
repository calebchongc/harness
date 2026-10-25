//! The Settings page's sections (crates/ui/src/shell.rs `SettingsSection`),
//! and the settings both apps keep in `ui-settings.json` in Harness's data
//! folder (crates/ui/src/settings.rs `UiSettings`): the GPUI app's own file,
//! read and written here key by key, so a change made in one app is the
//! other's too. Keys this app doesn't know are kept as they are.
const std = @import("std");
const json = std.json;
const icons = @import("icons.zig");
const Allocator = std.mem.Allocator;

pub const Section = enum {
    appearance,
    notifications,
    shortcuts,
    files,
    harnesses,
    agents,
    mcp,
    github_ci,
    devices,
    appshots,
    archived,

    /// The sidebar's order (`SettingsSection::ALL`).
    pub const all = std.enums.values(Section);

    pub fn label(s: Section) []const u8 {
        return switch (s) {
            .devices => "Devices",
            .harnesses => "Agents",
            .agents => "Accounts",
            .appearance => "Appearance",
            .files => "Files",
            .notifications => "Notifications",
            .shortcuts => "Shortcuts",
            .appshots => "Appshots",
            .archived => "Archived sessions",
            .mcp => "MCP servers",
            .github_ci => "GitHub CI",
        };
    }

    /// The heading it sits under in the sidebar.
    pub fn group(s: Section) []const u8 {
        return switch (s) {
            .appearance, .notifications, .shortcuts, .files => "General",
            .harnesses, .agents, .mcp, .github_ci => "Agents",
            .devices, .appshots, .archived => "Devices and data",
        };
    }

    pub fn icon(s: Section) icons.Name {
        return switch (s) {
            .devices, .appshots => .monitor,
            .harnesses => .widget,
            .agents => .@"key-minimalistic",
            .appearance => .tuning,
            .files => .folder,
            .notifications => .bell,
            .shortcuts => .keyboard,
            .archived => .@"archive-minimalistic",
            .mcp => .@"remote-server",
            .github_ci => .@"pull-request",
        };
    }

    /// As saved in `settingsSection`.
    pub fn key(s: Section) []const u8 {
        return switch (s) {
            .github_ci => "github-ci",
            else => @tagName(s),
        };
    }

    pub fn fromKey(k: []const u8) ?Section {
        for (all) |s| if (std.mem.eql(u8, s.key(), k)) return s;
        return null;
    }
};

/// The switches the Settings page shows, with `UiSettings`'s defaults.
/// Each is saved under its name in camel case (`sound_enabled` as
/// `soundEnabled`).
pub const Prefs = struct {
    sound_enabled: bool = true,
    sound_completion_enabled: bool = true,
    sound_input_enabled: bool = true,
    sound_attention_enabled: bool = true,
    notifications_enabled: bool = true,
    notifications_background_only: bool = true,
    share_performance_stats: bool = true,
    files_autosave_enabled: bool = false,
    files_word_wrap: bool = false,
    files_show_all: bool = false,
    archive_sessions_on_close: bool = false,
};

/// One of `Prefs`'s switches.
pub const Flag = enum {
    sound_enabled,
    sound_completion_enabled,
    sound_input_enabled,
    sound_attention_enabled,
    notifications_enabled,
    notifications_background_only,
    share_performance_stats,
    files_autosave_enabled,
    files_word_wrap,
    files_show_all,
    archive_sessions_on_close,
};

comptime {
    // A switch for every pref, and a pref for every switch.
    for (@typeInfo(Prefs).@"struct".field_names, std.enums.values(Flag)) |name, flag| {
        if (!std.mem.eql(u8, name, @tagName(flag))) @compileError("Flag and Prefs disagree at " ++ name);
    }
}

/// `sound_enabled` → `soundEnabled`.
pub fn camel(comptime name: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    comptime var up = false;
    inline for (name) |ch| {
        if (ch == '_') {
            up = true;
        } else {
            out = out ++ &[_]u8{if (up) std.ascii.toUpper(ch) else ch};
            up = false;
        }
    }
    return out;
}

pub const Store = struct {
    gpa: Allocator,
    io: std.Io,
    /// The file, or none (scenes and tests keep settings in memory).
    path: ?[]u8 = null,
    prefs: Prefs = .{},
    section: Section = .devices,

    pub fn deinit(s: *Store) void {
        if (s.path) |p| s.gpa.free(p);
    }

    /// The file in Harness's data folder: `HARNESS_DATA_DIR`, else
    /// `~/.harness`.
    pub fn open(gpa: Allocator, io: std.Io, env: *const std.process.Environ.Map) Store {
        var s: Store = .{ .gpa = gpa, .io = io };
        const path = if (env.get("HARNESS_DATA_DIR")) |d|
            std.fs.path.join(gpa, &.{ d, "ui-settings.json" })
        else if (env.get("HOME")) |h|
            std.fs.path.join(gpa, &.{ h, ".harness", "ui-settings.json" })
        else
            return s;
        s.path = path catch return s;
        s.load();
        return s;
    }

    /// Reads what the file says; what it doesn't say keeps its default.
    pub fn load(s: *Store) void {
        const path = s.path orelse return;
        const text = std.Io.Dir.cwd().readFileAlloc(s.io, path, s.gpa, .limited(8 << 20)) catch return;
        defer s.gpa.free(text);
        s.apply(text);
    }

    pub fn apply(s: *Store, text: []const u8) void {
        const parsed = json.parseFromSlice(json.Value, s.gpa, text, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const o = parsed.value.object;
        inline for (comptime std.enums.values(Flag)) |flag| {
            if (o.get(comptime camel(@tagName(flag)))) |v| if (v == .bool) {
                @field(s.prefs, @tagName(flag)) = v.bool;
            };
        }
        if (o.get("settingsSection")) |v| if (v == .string) if (Section.fromKey(v.string)) |sec| {
            s.section = sec;
        };
    }

    pub fn get(s: *const Store, comptime flag: Flag) bool {
        return @field(s.prefs, @tagName(flag));
    }

    pub fn set(s: *Store, comptime flag: Flag, on: bool) void {
        @field(s.prefs, @tagName(flag)) = on;
        s.write(comptime camel(@tagName(flag)), .{ .bool = on });
    }

    pub fn toggle(s: *Store, comptime flag: Flag) void {
        s.set(flag, !s.get(flag));
    }

    /// The page last shown, for the next time Settings opens.
    pub fn setSection(s: *Store, sec: Section) void {
        s.section = sec;
        s.write("settingsSection", .{ .string = sec.key() });
    }

    /// Sets one key in the file as it is now (the other app may have
    /// written since), and swaps it in whole.
    fn write(s: *Store, key: []const u8, value: json.Value) void {
        const path = s.path orelse return;
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const text = std.Io.Dir.cwd().readFileAlloc(s.io, path, a, .limited(8 << 20)) catch "{}";
        const out = merged(a, text, key, value) catch return;
        const tmp = std.fmt.allocPrint(a, "{s}.nano-tmp", .{path}) catch return;
        std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = tmp, .data = out }) catch return;
        std.Io.Dir.cwd().rename(tmp, std.Io.Dir.cwd(), path, s.io) catch return;
    }
};

/// `text`'s object with `key` set to `value`, every other key as it was.
pub fn merged(a: Allocator, text: []const u8, key: []const u8, value: json.Value) ![]u8 {
    var root = json.parseFromSliceLeaky(json.Value, a, text, .{}) catch json.Value{ .object = .empty };
    if (root != .object) root = .{ .object = .empty };
    try root.object.put(a, key, value);
    return json.Stringify.valueAlloc(a, root, .{ .whitespace = .indent_2 });
}

const testing = std.testing;

test "sections in the GPUI app's order, groups and saved keys" {
    try testing.expectEqual(Section.appearance, Section.all[0]);
    try testing.expectEqualStrings("Accounts", Section.agents.label());
    try testing.expectEqualStrings("Agents", Section.harnesses.label());
    try testing.expectEqualStrings("Devices and data", Section.archived.group());
    try testing.expectEqual(@as(?Section, .github_ci), Section.fromKey("github-ci"));
    try testing.expectEqual(@as(?Section, null), Section.fromKey("nope"));
    try testing.expectEqualStrings("soundCompletionEnabled", comptime camel("sound_completion_enabled"));
}

test "the file's switches are read, and a change keeps every other key" {
    var s: Store = .{ .gpa = testing.allocator, .io = testing.io };
    s.apply(
        \\{"soundEnabled":false,"filesWordWrap":true,"settingsSection":"files","sidebarWidth":300}
    );
    try testing.expect(!s.get(.sound_enabled));
    try testing.expect(s.get(.files_word_wrap));
    try testing.expect(s.get(.notifications_enabled));
    try testing.expectEqual(Section.files, s.section);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const out = try merged(arena.allocator(),
        \\{"sidebarWidth":300,"keymap":{"x":1},"soundEnabled":true}
    , "soundEnabled", .{ .bool = false });
    const back = try json.parseFromSliceLeaky(json.Value, arena.allocator(), out, .{});
    try testing.expectEqual(false, back.object.get("soundEnabled").?.bool);
    try testing.expectEqual(@as(i64, 300), back.object.get("sidebarWidth").?.integer);
    try testing.expect(back.object.get("keymap").? == .object);
    // A file that isn't there, or isn't JSON, starts from nothing.
    const fresh = try merged(arena.allocator(), "not json", "filesShowAll", .{ .bool = true });
    try testing.expect((try json.parseFromSliceLeaky(json.Value, arena.allocator(), fresh, .{})).object.get("filesShowAll").?.bool);
}
