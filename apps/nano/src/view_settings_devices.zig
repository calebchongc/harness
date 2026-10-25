//! Settings › Devices, as the GPUI app's (settings/devices.rs): this build's
//! version, then a card of the workspace's devices, each with its platform
//! on a tile that carries its presence, a quiet line of platform, version,
//! when it was last seen and added, and its id; this one marked.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const set = @import("view_settings.zig");
const account = @import("app_account.zig");
const workspace = @import("workspace.zig");
const App = @import("app.zig").App;

/// Seen this recently, a device is online (`DEVICE_ONLINE_WINDOW_SECS`).
const online_window_ms: i64 = 70 * 1000;

pub fn online(last_seen_ms: i64, now_ms: i64) bool {
    return last_seen_ms > 0 and now_ms - last_seen_ms <= online_window_ms;
}

/// "just now", "5m ago", "3h ago", "2d ago", or "never seen"
/// (`format_last_seen`).
pub fn lastSeen(buf: []u8, then_ms: i64, now_ms: i64) []const u8 {
    if (then_ms == 0) return "never seen";
    const s = @divFloor(@max(now_ms - then_ms, 0), 1000);
    return (if (s < 60)
        std.fmt.bufPrint(buf, "just now", .{})
    else if (s < 3600)
        std.fmt.bufPrint(buf, "{d}m ago", .{@divFloor(s, 60)})
    else if (s < 86_400)
        std.fmt.bufPrint(buf, "{d}h ago", .{@divFloor(s, 3600)})
    else
        std.fmt.bufPrint(buf, "{d}d ago", .{@divFloor(s, 86_400)})) catch "";
}

/// What the page says the list is (`devices_subtitle`).
pub fn subtitle(scope: ?account.Scope) []const u8 {
    return switch (scope orelse .development) {
        .local => "Manage device details stored in this local workspace.",
        .synced => "Manage device names and inspect synced device metadata.",
        .development => "Manage device names for this workspace.",
    };
}

pub fn platformLabel(p: []const u8) []const u8 {
    const names = .{ .{ "macos", "macOS" }, .{ "darwin", "macOS" }, .{ "linux", "Linux" }, .{ "windows", "Windows" }, .{ "web", "Web" }, .{ "ios", "iOS" }, .{ "android", "Android" } };
    inline for (names) |n| if (std.mem.eql(u8, p, n[0])) return n[1];
    return p;
}

fn platformIcon(p: []const u8) icons.Name {
    if (std.mem.eql(u8, p, "macos") or std.mem.eql(u8, p, "darwin")) return .laptop;
    if (std.mem.eql(u8, p, "web")) return .global;
    if (std.mem.eql(u8, p, "ios") or std.mem.eql(u8, p, "android")) return .smartphone;
    return .monitor;
}

/// The id chip's text: `abcd1234…wxyz` for a long id (`short_id`).
pub fn shortId(buf: []u8, id: []const u8) []const u8 {
    if (id.len <= 12) return id;
    return std.fmt.bufPrint(buf, "{s}…{s}", .{ id[0..8], id[id.len - 4 ..] }) catch id;
}

pub fn page(c: *ui.Context, a: *App, k: theme.Colors) void {
    const devices = a.devices.items;
    set.header(c, k, "Devices", if (devices.len > 0) devices.len else null);
    set.subtitle(c, k, subtitle(a.account.scope), false);
    {
        // This build's version: a row on the page, not in a card. Harness
        // Nano doesn't update itself (`update_summary` without an updater).
        const r = set.row(c, k, true, false);
        defer r.end();
        set.tile(c, k, .refresh);
        set.words(c, k, c.print("Harness v{s}", .{@import("build_info").version}), "This build doesn't update itself. Install the latest release to update.", 0);
    }
    const card = set.card(c, k);
    defer card.end();
    if (devices.len == 0) {
        const e = ui.div(c).row().wFull().px(20).py(40).justifyCenter();
        defer e.end();
        ui.text(c, "No devices registered", set.st(c, 14, .{ .color = k.muted.alpha(0.6) }));
        return;
    }
    const now = a.nowMs();
    for (devices, 0..) |d, ix| {
        ui.key(c, d.id);
        const local = if (a.device_id) |me| std.mem.eql(u8, me, d.id) else false;
        const on = online(d.last_seen_ms, now);
        const r = set.row(c, k, ix == 0, false);
        defer r.end();
        presenceTile(c, k, platformIcon(d.platform), on);
        {
            const w = ui.div(c).column().grow().w(0).gap(1);
            defer w.end();
            ui.text(c, d.name, set.st(c, 13, .{ .weight = .medium, .color = k.text }));
            meta(c, k, d, on, now);
        }
        if (local) ui.text(c, if (a.account.scope == .local) "Local only" else "This device", .{ .size = 10.5, .line_height = 10.5 * 1.618, .color = k.muted });
        if (action(c, k, .pen, "Rename")) a.setNotice("Renaming a device isn't in Harness Nano yet: use Harness.");
        // Only offline devices, never this one: the engine refuses an online
        // one, which would vanish until it restarted.
        if (!on and !local) if (action(c, k, null, "Remove")) a.setNotice("Removing a device isn't in Harness Nano yet: use Harness.");
    }
}

/// The platform's tile with presence on its corner: a dot ringed in the
/// card's tone, green and glowing online, faint offline.
fn presenceTile(c: *ui.Context, k: theme.Colors, icon: icons.Name, on: bool) void {
    const t = ui.div(c).row().size(36, 36).center().rounded(10).border(k.border).borderW(1).bg(k.ink(0.03));
    defer t.end();
    icons.icon(c, icon, 16, k.muted, 0);
    var dot = ui.div(c).absolute().offset(36 - 9 + 3, 36 - 9 + 3).size(9, 9).roundedFull().border(k.shell).borderW(2);
    dot = if (on) dot.bg(k.success).shadow(.{ .color = k.success.alpha(0.55), .blur = 6 }) else dot.bg(k.ink(0.22));
    dot.end();
}

/// platform · version · last seen (offline) · added · id, quiet, joined by
/// dots fainter still (`meta_line`).
fn meta(c: *ui.Context, k: theme.Colors, d: workspace.Device, on: bool, now: i64) void {
    const line = ui.div(c).row().gap(8).itemsCenter();
    defer line.end();
    const st = set.st(c, 12, .{ .color = k.muted.alpha(0.65) });
    var first = true;
    const Frag = struct {
        fn sep(cx: *ui.Context, kk: theme.Colors, is_first: *bool) void {
            if (!is_first.*) ui.text(cx, "·", set.st(cx, 12, .{ .color = kk.muted.alpha(0.3) }));
            is_first.* = false;
        }
    };
    Frag.sep(c, k, &first);
    ui.text(c, platformLabel(d.platform), st);
    if (d.version) |v| if (v.len > 0) {
        Frag.sep(c, k, &first);
        ui.text(c, c.print("v{s}", .{v}), st);
    };
    var buf: [32]u8 = undefined;
    if (!on) {
        Frag.sep(c, k, &first);
        ui.text(c, c.print("Last seen {s}", .{lastSeen(&buf, d.last_seen_ms, now)}), st);
    }
    if (d.created_ms != 0) {
        Frag.sep(c, k, &first);
        ui.text(c, c.print("Added {s}", .{lastSeen(&buf, d.created_ms, now)}), st);
    }
    Frag.sep(c, k, &first);
    var idb: [64]u8 = undefined;
    ui.text(c, c.print("{s}", .{shortId(&idb, d.id)}), .{ .size = 10.5, .line_height = 12 * 1.618, .mono = true, .color = k.muted.alpha(0.5) });
}

/// `ghost_action` at 70%, full under the pointer.
fn action(c: *ui.Context, k: theme.Colors, icon: ?icons.Name, label: []const u8) bool {
    var b = ui.div(c).row().px(10).py(6).gap(6).itemsCenter().rounded(8).hover(k.ink(0.06));
    const hot = b.hovered();
    b = b.opacity(if (hot) 1 else 0.7);
    defer b.end();
    if (icon) |i| icons.icon(c, i, 14, k.muted, 0);
    ui.text(c, label, set.st(c, 12, .{ .color = if (hot) k.text else k.muted }));
    return b.clicked();
}

const testing = std.testing;

test "presence, last seen, the subtitle and the id chip as the GPUI app's" {
    try testing.expect(online(1_000_000, 1_000_000 + 70_000));
    try testing.expect(!online(1_000_000, 1_000_000 + 71_000));
    try testing.expect(!online(0, 5));
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("never seen", lastSeen(&buf, 0, 1));
    try testing.expectEqualStrings("just now", lastSeen(&buf, 1000, 30_000));
    try testing.expectEqualStrings("5m ago", lastSeen(&buf, 0 + 1, 5 * 60_000 + 1));
    try testing.expectEqualStrings("2d ago", lastSeen(&buf, 1, 2 * 86_400_000 + 1));
    try testing.expectEqualStrings("Manage device details stored in this local workspace.", subtitle(.local));
    try testing.expectEqualStrings("macOS", platformLabel("darwin"));
    try testing.expectEqualStrings("plan9", platformLabel("plan9"));
    try testing.expectEqualStrings("abcdefgh…wxyz", shortId(&buf, "abcdefgh12345678wxyz"));
    try testing.expectEqualStrings("short", shortId(&buf, "short"));
}
