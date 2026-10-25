//! `zig build snap -- scene.json out-dir`: the window drawn offscreen from a
//! made-up scene, a PNG per `snap` step, with no window on screen and no
//! engine. Steps press shortcuts, click and type as a person would
//! (nanoui's Tester), and `expect` fails the run when text isn't drawn.
//!
//!     {"width": 1200, "height": 780, "dark": false, "scale": 2,
//!      "spaces": [...], "chats": [...], "devices": [...], "sessions": [...],
//!      "open": "chat id",                      // opened from the sidebar
//!      "workspaceScope": "local", "auth": {...}, "codegraff": {...},
//!      "transcripts": {"chat id": [entry, ...]},  // as a doc reset's
//!      "steps": [{"press": "cmd+d"}, {"composer": "hey"}, {"type": "x"},
//!                {"click": "visible text"}, {"clickAt": [x, y]},
//!                {"hover": [x, y]}, {"drag": [x1, y1, x2, y2]},
//!                {"resize": [w, h]}, {"wait": 0.5},
//!                {"expect": "text"}, {"expectNot": "text"},
//!                {"snap": "name"}]}
//!
//! Without a `snap` step it saves the last frame as `final.png`.
//!
//! A scene with a `name` is the GPUI renderer's instead
//! (crates/ui/examples/ui-scenes.rs): the same state set up as it sets it
//! up, the same steps (`{"do": "click", "x", "y"}`, `hover`, `key` with
//! `keys`, `type` with `text`, `scroll` with `dy`, `wait` with `ms`), and
//! the same files, `<name>.png` then `<name>-NN.png` after each step, so
//! apps/nano/parity/check.py can set the two side by side.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const json = std.json;

pub fn main(init: std.process.Init) !void {
    theme.registerFonts();
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: harness-nano-snap scene.json out-dir\n", .{});
        return error.Usage;
    }
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], gpa, .limited(64 << 20));
    defer gpa.free(text);
    const parsed = try json.parseFromSlice(json.Value, gpa, text, .{});
    defer parsed.deinit();
    const scene = parsed.value.object;
    const out = args[2];
    try std.Io.Dir.cwd().createDirPath(init.io, out);
    if (str(scene, "name")) |name| return parity(init, scene, name, out);

    var a: App = .init(gpa, init.io, 1);
    defer a.deinit();
    a.new_harness = try gpa.dupe(u8, str(scene, "harness") orelse "graff");
    const dark = flag(scene, "dark");
    a.dark = dark;
    inline for (.{ .{ "spaces", &a.spaces }, .{ "chats", &a.chats }, .{ "devices", &a.devices }, .{ "sessions", &a.sessions } }) |l| {
        if (scene.get(l[0])) |v| try l[1].replace(v);
    }
    @import("workspace.zig").sortChats(a.chats.items);
    // The account badge's: "workspaceScope", "auth" (an AuthStatus item),
    // "codegraff" (a CodegraffAuthStatus reply).
    const acct = @import("app_account.zig");
    a.account.scope = acct.readScope(scene);
    if (scene.get("auth")) |v| a.account.user = try acct.readUser(gpa, v);
    if (scene.get("codegraff")) |v| a.account.codegraff = try acct.readCodegraff(gpa, v);
    if (str(scene, "open")) |id| a.openChat(id, null);

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, @import("view.zig").view), .{
        .width = num(scene, "width") orelse 1200,
        .height = num(scene, "height") orelse 780,
        .scale = num(scene, "scale") orelse 2,
        .dark = dark,
        .theme = theme.ui(dark),
    });
    defer t.deinit();
    const transcripts = if (scene.get("transcripts")) |v| (if (v == .object) v.object else null) else null;
    settle(&t, &a, transcripts, init.arena.allocator());

    var snaps: usize = 0;
    const steps = if (scene.get("steps")) |v| (if (v == .array) v.array.items else &.{}) else &.{};
    for (steps, 1..) |step, n| {
        if (step != .object) continue;
        const o = step.object;
        if (str(o, "press")) |combo| {
            const s = parseShortcut(combo) orelse return fail(n, "no such shortcut: {s}", .{combo});
            _ = t.shortcut(s);
        } else if (str(o, "composer")) |s| {
            a.composer.set(s);
        } else if (str(o, "type")) |s| {
            t.typeText(s);
        } else if (str(o, "click")) |s| {
            t.clickText(s) catch return fail(n, "no text to click: {s}", .{s});
        } else if (point(o, "clickAt")) |p| {
            t.click(p[0], p[1]);
        } else if (point(o, "hover")) |p| {
            t.moveTo(p[0], p[1]);
        } else if (o.get("drag")) |v| {
            const p = floats(v, 4) orelse return fail(n, "drag takes [x1, y1, x2, y2]", .{});
            t.drag(p[0], p[1], p[2], p[3]);
        } else if (point(o, "resize")) |p| {
            t.resize(p[0], p[1]);
        } else if (num(o, "wait")) |s| {
            t.advance(s);
        } else if (str(o, "expect")) |s| {
            if (!t.containsText(s)) return fail(n, "not drawn: {s}", .{s});
        } else if (str(o, "expectNot")) |s| {
            if (t.containsText(s)) return fail(n, "drawn, and shouldn't be: {s}", .{s});
        } else if (str(o, "snap")) |name| {
            snaps += 1;
            try save(&t, out, snaps, name);
            continue;
        }
        settle(&t, &a, transcripts, init.arena.allocator());
    }
    if (snaps == 0) try save(&t, out, 0, "final");
}

/// A GPUI renderer's scene, drawn as that renderer draws it.
fn parity(init: std.process.Init, scene: json.ObjectMap, name: []const u8, out: []const u8) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    var a: App = .init(gpa, init.io, 1);
    defer a.deinit();
    a.new_harness = try gpa.dupe(u8, "graff");
    const dark = !std.mem.eql(u8, str(scene, "appearance") orelse "dark", "light");
    a.dark = dark;
    inline for (.{ .{ "spaces", &a.spaces }, .{ "chats", &a.chats }, .{ "sessions", &a.sessions } }) |l| {
        if (scene.get(l[0])) |v| try l[1].replace(v);
    }
    @import("workspace.zig").sortChats(a.chats.items);
    // As the GPUI renderer has it: connected, a local workspace, and this
    // device "Studio", the first chat's (or space's).
    a.engine.state = .connected;
    a.account.scope = .local;
    const device = first(scene, "chats", "deviceId") orelse first(scene, "spaces", "deviceId") orelse "local";
    a.device_id = try gpa.dupe(u8, device);
    const devices = try json.parseFromSliceLeaky(json.Value, arena, try std.fmt.allocPrint(arena, "[{{\"id\":\"{s}\",\"name\":\"Studio\"}}]", .{device}), .{});
    try a.devices.replace(devices);
    if (str(scene, "selectedSpace") orelse first(scene, "spaces", "id")) |sp| a.space = try gpa.dupe(u8, sp);
    if (str(scene, "selectedChat")) |id| {
        a.openChat(id, null);
        if (scene.get("transcript")) |v| a.transcript.apply(reset(arena, v) orelse return error.OutOfMemory) catch {};
    }

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, @import("view.zig").view), .{
        .width = num(scene, "width") orelse 1200,
        .height = num(scene, "height") orelse 780,
        .scale = 2,
        .dark = dark,
        .theme = theme.ui(dark),
    });
    defer t.deinit();
    t.settle(1);
    var buf: [4096]u8 = undefined;
    try shot(&t, try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ out, name }));
    const steps = if (scene.get("steps")) |v| (if (v == .array) v.array.items else &.{}) else &.{};
    for (steps, 1..) |step, n| {
        if (step != .object) continue;
        const o = step.object;
        const do = str(o, "do") orelse "";
        const x = num(o, "x") orelse 0;
        const y = num(o, "y") orelse 0;
        if (std.mem.eql(u8, do, "click")) {
            t.click(x, y);
        } else if (std.mem.eql(u8, do, "hover")) {
            t.moveTo(x, y);
        } else if (std.mem.eql(u8, do, "key")) {
            const keys = str(o, "keys") orelse "";
            _ = t.shortcut(parseShortcut(keys) orelse return fail(n, "no such shortcut: {s}", .{keys}));
        } else if (std.mem.eql(u8, do, "type")) {
            // A key at a time, as the input system hands them over.
            const s = str(o, "text") orelse "";
            var i: usize = 0;
            while (i < s.len) {
                const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
                t.textOps(&.{.{ .insert = s[i..@min(s.len, i + len)] }});
                i += len;
            }
        } else if (std.mem.eql(u8, do, "scroll")) {
            t.scroll(x, y, num(o, "dy") orelse 0);
        } else if (std.mem.eql(u8, do, "wait")) {
            t.advance((num(o, "ms") orelse 0) / 1000);
        } else return fail(n, "no such step: {s}", .{do});
        t.settle(1);
        try shot(&t, try std.fmt.bufPrint(&buf, "{s}/{s}-{d:0>2}.png", .{ out, name, n }));
    }
}

fn shot(t: *ui.Tester, path: []const u8) !void {
    try t.screenshot(path);
    std.debug.print("{s}\n", .{path});
}

/// `key` of the first item of the array `list`.
fn first(o: json.ObjectMap, list: []const u8, key: []const u8) ?[]const u8 {
    const v = o.get(list) orelse return null;
    if (v != .array or v.array.items.len == 0 or v.array.items[0] != .object) return null;
    return str(v.array.items[0].object, key);
}

/// Runs frames until the view is still, giving every chat on screen (the
/// open one, its split's other panes) its transcript from the scene.
fn settle(t: *ui.Tester, a: *App, transcripts: ?json.ObjectMap, arena: std.mem.Allocator) void {
    t.settle(1);
    const all = transcripts orelse return;
    var filled = false;
    if (a.selected) |id| if (a.transcript.entries.items.len == 0) if (all.get(id)) |v| {
        a.transcript.apply(reset(arena, v) orelse return) catch {};
        filled = true;
    };
    for (a.peers.items) |*p| if (p.transcript.entries.items.len == 0) if (all.get(p.id)) |v| {
        p.transcript.apply(reset(arena, v) orelse continue) catch {};
        filled = true;
    };
    if (filled) t.settle(1);
}

/// `{"reset": entries}`, as the engine's first doc frame, in the run's
/// arena: the transcript copies what it keeps.
fn reset(gpa: std.mem.Allocator, entries: json.Value) ?json.Value {
    var o: json.ObjectMap = .empty;
    o.put(gpa, "reset", entries) catch return null;
    return .{ .object = o };
}

fn save(t: *ui.Tester, out: []const u8, n: usize, name: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{d:0>2}-{s}.png", .{ out, n, name });
    try t.screenshot(path);
    std.debug.print("{s}\n", .{path});
}

fn fail(step: usize, comptime f: []const u8, args: anytype) error{StepFailed} {
    std.debug.print("step {d}: " ++ f ++ "\n", .{step} ++ args);
    return error.StepFailed;
}

/// "cmd+shift+d", "alt+cmd+left", "ctrl+cmd+=", "cmd+shift+enter".
pub fn parseShortcut(combo: []const u8) ?ui.Shortcut {
    const S = ui.Shortcut;
    var s: S = .{ .key = 0 };
    // "cmd++": the plus key itself.
    const plus = std.mem.endsWith(u8, combo, "++");
    if (plus) s.key = '+';
    var it = std.mem.splitScalar(u8, if (plus) combo[0 .. combo.len - 2] else combo, '+');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "cmd")) s.cmd = true else if (std.mem.eql(u8, part, "shift")) s.shift = true else if (std.mem.eql(u8, part, "alt")) s.alt = true else if (std.mem.eql(u8, part, "ctrl")) s.ctrl = true else {
            const names = .{ .{ "enter", S.enter }, .{ "escape", S.escape }, .{ "tab", S.tab }, .{ "up", S.up }, .{ "down", S.down }, .{ "left", S.left }, .{ "right", S.right } };
            s.key = inline for (names) |x| {
                if (std.mem.eql(u8, part, x[0])) break x[1];
            } else blk: {
                if (part.len != 1) return null;
                break :blk std.ascii.toLower(part[0]);
            };
        }
    }
    return if (s.key == 0) null else s;
}

fn str(o: json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn flag(o: json.ObjectMap, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return v == .bool and v.bool;
}

fn num(o: json.ObjectMap, key: []const u8) ?f32 {
    return float(o.get(key) orelse return null);
}

fn float(v: json.Value) ?f32 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => null,
    };
}

fn floats(v: json.Value, comptime n: usize) ?[n]f32 {
    if (v != .array or v.array.items.len != n) return null;
    var out: [n]f32 = undefined;
    for (v.array.items, 0..) |x, i| out[i] = float(x) orelse return null;
    return out;
}

fn point(o: json.ObjectMap, key: []const u8) ?[2]f32 {
    return floats(o.get(key) orelse return null, 2);
}

test "shortcuts as the scenes write them" {
    const S = ui.Shortcut;
    try std.testing.expectEqual(S{ .key = 'd', .cmd = true, .shift = true }, parseShortcut("cmd+shift+d").?);
    try std.testing.expectEqual(S{ .key = S.left, .cmd = true, .alt = true }, parseShortcut("alt+cmd+left").?);
    try std.testing.expectEqual(S{ .key = '=', .cmd = true, .ctrl = true }, parseShortcut("ctrl+cmd+=").?);
    try std.testing.expectEqual(S{ .key = '+', .cmd = true }, parseShortcut("cmd++").?);
    try std.testing.expect(parseShortcut("cmd+") == null);
    try std.testing.expect(parseShortcut("cmd+nope") == null);
}
