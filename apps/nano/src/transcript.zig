//! A chat's transcript as `WatchDocMessages` sends it
//! (crates/doc/src/transcript_delta.rs): a `reset` with every entry first,
//! then deltas of `remove`d ids, `upsert`ed entries placed after an anchor,
//! and text `append`ed to a text or reasoning part, with the byte length and
//! entry count they must reach. A delta that doesn't fit is
//! `error.Desync`: the caller resubscribes for a fresh reset, as
//! `apply_transcript_frame` asks of the GPUI app.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

pub const Role = enum { user, assistant, system };
pub const EntryStatus = enum { streaming, complete, aborted };

pub const PartKind = enum { text, reasoning, tool, image, visual, delegation, input, @"error", other };

pub const Part = struct {
    id: []u8,
    kind: PartKind,
    /// Text and reasoning: their text. A tool: what it ran (`exec · cargo
    /// test`). An error: its message.
    text: std.ArrayList(u8) = .empty,
    /// A tool has finished, or an input request was answered.
    resolved: bool = false,
    is_error: bool = false,

    fn deinit(p: *Part, gpa: Allocator) void {
        gpa.free(p.id);
        p.text.deinit(gpa);
    }
};

pub const Entry = struct {
    id: []u8,
    role: Role,
    status: EntryStatus,
    parts: std.ArrayList(Part) = .empty,

    fn deinit(e: *Entry, gpa: Allocator) void {
        gpa.free(e.id);
        for (e.parts.items) |*p| p.deinit(gpa);
        e.parts.deinit(gpa);
    }
};

pub const Transcript = struct {
    gpa: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// A reset has come that holds the whole history (not only the tail an
    /// `openingTail` watch sends first).
    complete: bool = false,
    /// The context window used, from the last frame that said.
    tokens: ?u64 = null,
    window: ?u64 = null,

    pub fn deinit(t: *Transcript) void {
        t.clear();
        t.entries.deinit(t.gpa);
    }

    pub fn clear(t: *Transcript) void {
        for (t.entries.items) |*e| e.deinit(t.gpa);
        t.entries.clearRetainingCapacity();
        t.complete = false;
        t.tokens = null;
        t.window = null;
    }

    /// Applies one `TranscriptUpdate`.
    pub fn apply(t: *Transcript, frame: json.Value) !void {
        const o = switch (frame) {
            .object => |o| o,
            else => return error.Desync,
        };
        defer if (o.get("contextUsage")) |u| if (u == .object) {
            t.tokens = uint(u.object.get("tokens"));
            t.window = uint(u.object.get("window"));
        };
        if (o.get("reset")) |r| {
            const pending = if (o.get("historyPending")) |h| h == .bool and h.bool else false;
            // The tail again once the whole history is here: nothing new.
            if (pending and t.complete) return;
            t.clear();
            for (array(r)) |v| try t.entries.append(t.gpa, try parseEntry(t.gpa, v));
            t.complete = !pending;
            return;
        }
        for (array(o.get("remove"))) |v| if (v == .string) if (t.find(v.string)) |i| {
            var gone = t.entries.orderedRemove(i);
            gone.deinit(t.gpa);
        };
        for (array(o.get("upsert"))) |u| {
            if (u != .object) return error.Desync;
            var entry = try parseEntry(t.gpa, u.object.get("entry") orelse return error.Desync);
            errdefer entry.deinit(t.gpa);
            if (t.find(entry.id)) |i| {
                var old = t.entries.orderedRemove(i);
                old.deinit(t.gpa);
            }
            const at: usize = switch (u.object.get("after") orelse .null) {
                .string => |anchor| (t.find(anchor) orelse return error.Desync) + 1,
                else => 0,
            };
            try t.entries.insert(t.gpa, at, entry);
        }
        for (array(o.get("append"))) |a| {
            if (a != .object) return error.Desync;
            const entry_id = string(a.object.get("entry")) orelse return error.Desync;
            const part_id = string(a.object.get("part")) orelse return error.Desync;
            const i = t.find(entry_id) orelse return error.Desync;
            const part = for (t.entries.items[i].parts.items) |*p| {
                if ((p.kind == .text or p.kind == .reasoning) and std.mem.eql(u8, p.id, part_id)) break p;
            } else return error.Desync;
            try part.text.appendSlice(t.gpa, string(a.object.get("text")) orelse "");
            if (part.text.items.len != uint(a.object.get("len")) orelse return error.Desync) return error.Desync;
        }
        if (o.get("count")) |n| if (t.entries.items.len != uint(n) orelse return error.Desync) return error.Desync;
    }

    /// From the back: the target is almost always the live tail entry.
    fn find(t: *Transcript, id: []const u8) ?usize {
        var i = t.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, t.entries.items[i].id, id)) return i;
        }
        return null;
    }
};

fn array(v: ?json.Value) []const json.Value {
    const x = v orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

fn string(v: ?json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn uint(v: ?json.Value) ?u64 {
    const x = v orelse return null;
    return if (x == .integer) std.math.cast(u64, x.integer) else null;
}

fn parseEntry(gpa: Allocator, v: json.Value) !Entry {
    if (v != .object) return error.Desync;
    const o = v.object;
    const role = std.meta.stringToEnum(Role, string(o.get("role")) orelse "") orelse .system;
    const status = std.meta.stringToEnum(EntryStatus, string(o.get("status")) orelse "") orelse .complete;
    var e: Entry = .{ .id = try gpa.dupe(u8, string(o.get("id")) orelse return error.Desync), .role = role, .status = status };
    errdefer e.deinit(gpa);
    for (array(o.get("parts"))) |p| if (p == .object) try e.parts.append(gpa, try parsePart(gpa, p.object));
    return e;
}

fn parsePart(gpa: Allocator, o: json.ObjectMap) !Part {
    const kind = std.meta.stringToEnum(PartKind, string(o.get("kind")) orelse "") orelse .other;
    var p: Part = .{ .id = try gpa.dupe(u8, string(o.get("id")) orelse ""), .kind = kind };
    errdefer p.deinit(gpa);
    switch (kind) {
        .text, .reasoning => try p.text.appendSlice(gpa, string(o.get("text")) orelse ""),
        .@"error" => try p.text.appendSlice(gpa, string(o.get("message")) orelse ""),
        .tool => {
            p.resolved = if (o.get("resolved")) |r| r == .bool and r.bool else false;
            p.is_error = if (o.get("isError")) |r| r == .bool and r.bool else false;
            try toolSummary(gpa, &p.text, o.get("call"));
        },
        .input => p.resolved = if (o.get("resolved")) |r| r == .bool and r.bool else false,
        .image => try p.text.appendSlice(gpa, string(o.get("name")) orelse ""),
        .visual => try p.text.appendSlice(gpa, string(o.get("title")) orelse ""),
        .delegation, .other => {},
    }
    return p;
}

/// One line for a tool call (`ToolCall`, tagged by `kind`): what it ran.
fn toolSummary(gpa: Allocator, out: *std.ArrayList(u8), call: ?json.Value) !void {
    const c = call orelse return;
    if (c != .object) return;
    const kind = string(c.object.get("kind")) orelse "tool";
    const detail = string(c.object.get("command")) orelse
        string(c.object.get("path")) orelse
        string(c.object.get("pattern")) orelse
        string(c.object.get("query")) orelse
        string(c.object.get("url")) orelse
        string(c.object.get("tool")) orelse
        string(c.object.get("name"));
    try out.appendSlice(gpa, kind);
    if (detail) |d| {
        try out.appendSlice(gpa, " · ");
        try out.appendSlice(gpa, d);
    }
}

const testing = std.testing;

fn applyText(t: *Transcript, text: []const u8) !void {
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try t.apply(parsed.value);
}

test "a reset, then an upsert after an anchor, then streamed text" {
    var t: Transcript = .{ .gpa = testing.allocator };
    defer t.deinit();
    try applyText(&t,
        \\{"reset":[{"id":"u1","role":"user","parts":[{"kind":"text","id":"p","text":"hi"}],"createdAt":1,"deviceId":"d"}],
        \\ "contextUsage":{"tokens":10,"window":200}}
    );
    try testing.expect(t.complete);
    try testing.expectEqual(@as(?u64, 200), t.window);
    try applyText(&t,
        \\{"upsert":[{"after":"u1","entry":{"id":"a1","role":"assistant","status":"streaming",
        \\  "parts":[{"kind":"text","id":"t","text":"Hel"}],"createdAt":2,"deviceId":"d"}}],"count":2}
    );
    try applyText(&t,
        \\{"append":[{"entry":"a1","part":"t","text":"lo","len":5}],"count":2}
    );
    try testing.expectEqual(@as(usize, 2), t.entries.items.len);
    try testing.expectEqualStrings("Hello", t.entries.items[1].parts.items[0].text.items);
    try testing.expectEqual(EntryStatus.streaming, t.entries.items[1].status);
}

test "a delta that doesn't fit is a desync" {
    var t: Transcript = .{ .gpa = testing.allocator };
    defer t.deinit();
    try applyText(&t,
        \\{"reset":[{"id":"a","role":"assistant","parts":[{"kind":"text","id":"t","text":"ab"}]}]}
    );
    try testing.expectError(error.Desync, applyText(&t, "{\"append\":[{\"entry\":\"a\",\"part\":\"t\",\"text\":\"c\",\"len\":9}]}"));
    t.clear();
    try applyText(&t, "{\"reset\":[]}");
    try testing.expectError(error.Desync, applyText(&t,
        \\{"upsert":[{"after":"missing","entry":{"id":"x","role":"user","parts":[]}}]}
    ));
    try testing.expectError(error.Desync, applyText(&t, "{\"count\":3}"));
}

test "the tail first, the whole history after, and the tail again ignored" {
    var t: Transcript = .{ .gpa = testing.allocator };
    defer t.deinit();
    try applyText(&t, "{\"reset\":[{\"id\":\"b\",\"role\":\"user\",\"parts\":[]}],\"historyPending\":true}");
    try testing.expect(!t.complete);
    try applyText(&t, "{\"reset\":[{\"id\":\"a\",\"role\":\"user\",\"parts\":[]},{\"id\":\"b\",\"role\":\"user\",\"parts\":[]}]}");
    try applyText(&t, "{\"reset\":[{\"id\":\"b\",\"role\":\"user\",\"parts\":[]}],\"historyPending\":true}");
    try testing.expectEqual(@as(usize, 2), t.entries.items.len);
}

test "remove, a tool's summary, and replacing an entry by id" {
    var t: Transcript = .{ .gpa = testing.allocator };
    defer t.deinit();
    try applyText(&t,
        \\{"reset":[{"id":"a","role":"assistant","parts":[{"kind":"tool","id":"k","resolved":true,"isError":false,
        \\  "call":{"kind":"exec","command":"zig build test"}}]},{"id":"b","role":"user","parts":[]}]}
    );
    try testing.expectEqualStrings("exec · zig build test", t.entries.items[0].parts.items[0].text.items);
    try applyText(&t,
        \\{"remove":["b"],"upsert":[{"after":null,"entry":{"id":"a","role":"assistant","status":"complete","parts":[]}}],"count":1}
    );
    try testing.expectEqual(@as(usize, 0), t.entries.items[0].parts.items.len);
}
