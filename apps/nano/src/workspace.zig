//! The sidebar's rows, as `WatchSpaces`, `WatchChats` and `WatchSessions`
//! send them (crates/proto/src/entities.rs): each item is the whole list
//! again, so a list is replaced, never patched. Fields are read by name and
//! the rest ignored, so a newer engine's additions don't break the client.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;

pub const Space = struct {
    id: []const u8,
    path: []const u8,
    /// `name`, else the last part of `path`, as the GPUI app shows it.
    name: []const u8,
};

pub const Chat = struct {
    id: []const u8,
    title: ?[]const u8,
    space_id: ?[]const u8,
    archived: bool,
    /// RFC 3339 in UTC: orders as text.
    last_message_at: []const u8,
    preview: ?[]const u8,
    harness: ?[]const u8,
    model: ?[]const u8,
    cwd: ?[]const u8,
};

pub const Status = enum { idle, working, awaiting_input, errored };

pub const Session = struct {
    chat_id: []const u8,
    status: Status,
};

/// A list replaced whole by each item, its strings in an arena of its own.
pub fn List(comptime T: type, comptime parse: fn (Allocator, json.ObjectMap) ?T) type {
    return struct {
        const Self = @This();
        arena: std.heap.ArenaAllocator,
        items: []T = &.{},

        pub fn init(gpa: Allocator) Self {
            return .{ .arena = .init(gpa) };
        }

        pub fn deinit(l: *Self) void {
            l.arena.deinit();
        }

        pub fn replace(l: *Self, value: json.Value) !void {
            const arr = switch (value) {
                .array => |a| a.items,
                else => return error.BadItem,
            };
            var next: std.heap.ArenaAllocator = .init(l.arena.child_allocator);
            errdefer next.deinit();
            const a = next.allocator();
            var out: std.ArrayList(T) = try .initCapacity(a, arr.len);
            for (arr) |v| if (v == .object) if (parse(a, v.object)) |t| out.appendAssumeCapacity(t);
            l.arena.deinit();
            l.arena = next;
            l.items = out.items;
        }
    };
}

pub const Spaces = List(Space, parseSpace);
pub const Chats = List(Chat, parseChat);
pub const Sessions = List(Session, parseSession);

pub fn str(a: Allocator, o: json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return switch (v) {
        .string => |s| a.dupe(u8, s) catch null,
        else => null,
    };
}

fn parseSpace(a: Allocator, o: json.ObjectMap) ?Space {
    const path = str(a, o, "path") orelse return null;
    return .{
        .id = str(a, o, "id") orelse return null,
        .path = path,
        .name = str(a, o, "name") orelse std.fs.path.basename(path),
    };
}

fn parseChat(a: Allocator, o: json.ObjectMap) ?Chat {
    const config = if (o.get("config")) |c| (if (c == .object) c.object else null) else null;
    return .{
        .id = str(a, o, "id") orelse return null,
        .title = str(a, o, "title"),
        .space_id = str(a, o, "spaceId"),
        .archived = if (o.get("archived")) |v| v == .bool and v.bool else false,
        .last_message_at = str(a, o, "lastMessageAt") orelse str(a, o, "createdAt") orelse "",
        .preview = str(a, o, "lastMessagePreview"),
        .harness = if (config) |c| str(a, c, "harness") else null,
        .model = if (config) |c| str(a, c, "model") else null,
        .cwd = str(a, o, "cwd"),
    };
}

fn parseSession(a: Allocator, o: json.ObjectMap) ?Session {
    const s = if (o.get("status")) |v| (if (v == .string) v.string else "") else "";
    return .{
        .chat_id = str(a, o, "chatId") orelse return null,
        .status = if (std.mem.eql(u8, s, "working"))
            .working
        else if (std.mem.eql(u8, s, "awaitingInput"))
            .awaiting_input
        else if (std.mem.eql(u8, s, "errored"))
            .errored
        else
            .idle,
    };
}

/// Chats newest first, as the sidebar lists them.
pub fn sortChats(chats: []Chat) void {
    std.mem.sort(Chat, chats, {}, struct {
        fn lt(_: void, x: Chat, y: Chat) bool {
            return std.mem.order(u8, x.last_message_at, y.last_message_at) == .gt;
        }
    }.lt);
}

pub fn statusOf(sessions: []const Session, chat_id: []const u8) Status {
    for (sessions) |s| if (std.mem.eql(u8, s.chat_id, chat_id)) return s.status;
    return .idle;
}

const testing = std.testing;

test "a chats item replaces the list, reading only what it knows" {
    var chats: Chats = .init(testing.allocator);
    defer chats.deinit();
    const text =
        \\[{"id":"a","deviceId":"d","title":null,"archived":false,"cwd":"/r","branch":null,"checkoutId":null,
        \\  "config":{"harness":"graff","model":"m1","reasoning":null,"modelOptions":{},"sandbox":"workspace-write"},
        \\  "lastMessagePreview":"hi","lastMessageAt":"2026-10-01T00:00:00Z","createdAt":"2026-09-01T00:00:00Z","future":1},
        \\ {"id":"b","title":"Second","archived":true,"lastMessageAt":"2026-10-02T00:00:00Z","spaceId":"s1"}]
    ;
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, text, .{});
    defer parsed.deinit();
    try chats.replace(parsed.value);
    try testing.expectEqual(@as(usize, 2), chats.items.len);
    try testing.expectEqualStrings("graff", chats.items[0].harness.?);
    try testing.expect(chats.items[0].title == null);
    sortChats(chats.items);
    try testing.expectEqualStrings("b", chats.items[0].id);
    try testing.expectEqualStrings("s1", chats.items[0].space_id.?);
    try testing.expect(chats.items[0].archived);
}

test "a space without a name takes its folder's" {
    var spaces: Spaces = .init(testing.allocator);
    defer spaces.deinit();
    var parsed = try json.parseFromSlice(json.Value, testing.allocator,
        \\[{"id":"s","deviceId":"d","path":"/Users/x/harness","gitDetected":true,"createdAt":"t"}]
    , .{});
    defer parsed.deinit();
    try spaces.replace(parsed.value);
    try testing.expectEqualStrings("harness", spaces.items[0].name);
}

test "sessions map statuses" {
    var sessions: Sessions = .init(testing.allocator);
    defer sessions.deinit();
    var parsed = try json.parseFromSlice(json.Value, testing.allocator,
        \\[{"chatId":"a","status":"working"},{"chatId":"b","status":"awaitingInput"}]
    , .{});
    defer parsed.deinit();
    try sessions.replace(parsed.value);
    try testing.expectEqual(Status.working, statusOf(sessions.items, "a"));
    try testing.expectEqual(Status.awaiting_input, statusOf(sessions.items, "b"));
    try testing.expectEqual(Status.idle, statusOf(sessions.items, "c"));
}
