//! The app's state: the engine connection, the sidebar's spaces, chats and
//! sessions, the open chat's transcript, and the composer.
//!
//! On connect it watches what the GPUI app watches in `attach_engine`
//! (crates/ui/src/state.rs): spaces, chats and sessions, each item the whole
//! list. Opening a chat focuses it, marks it seen and watches its transcript
//! (`select_chat`). Sending mints the chat's id when it is new, creates it,
//! then queues a `run` command (`Composer::send`, crates/ui/src/composer.rs).
const std = @import("std");
const nanoui = @import("nanoui");
const rpc = @import("rpc.zig");
const engine_mod = @import("engine.zig");
const workspace = @import("workspace.zig");
const Transcript = @import("transcript.zig").Transcript;
const Allocator = std.mem.Allocator;

/// A stream the app keeps open, and when to open it again once it ended.
const Watch = struct {
    id: ?u64 = null,
    retry_at: ?f64 = null,
};

/// Seconds before a stream that ended is opened again, as the GPUI app.
const retry_s = 2.0;

pub const App = struct {
    gpa: Allocator,
    io: std.Io,
    engine: engine_mod.Engine,
    window: ?*nanoui.Window = null,
    spaces: workspace.Spaces,
    chats: workspace.Chats,
    sessions: workspace.Sessions,
    w_spaces: Watch = .{},
    w_chats: Watch = .{},
    w_sessions: Watch = .{},
    w_doc: Watch = .{},
    /// The open chat (owned), and the space a new chat starts in.
    selected: ?[]u8 = null,
    space: ?[]u8 = null,
    transcript: Transcript,
    composer: nanoui.ui.TextBuffer = .{},
    /// The last error the engine gave, shown under the composer.
    notice: [200]u8 = undefined,
    notice_len: usize = 0,
    /// The view's clock, as of its last frame.
    now: f64 = 0,
    dark: ?bool = null,
    /// This engine's device: a space added here is this device's folder.
    device_id: ?[]u8 = null,
    /// The agents to pick from, and the models the picked one offers.
    harnesses: workspace.Harnesses,
    models: workspace.Models,
    /// The agent and model a new chat runs (owned); `HARNESS_NANO_HARNESS`
    /// starts with another agent (`mock` against a test engine).
    new_harness: []u8 = &.{},
    new_model: ?[]u8 = null,
    /// Which picker is open over the composer.
    picker: enum { none, harness, model } = .none,
    /// The newest Harness release, asked of GitHub over HTTP/2.
    release: @import("release.zig").Check,

    pub fn init(gpa: Allocator, io: std.Io, port: u16) App {
        return .{
            .gpa = gpa,
            .io = io,
            .engine = .init(gpa, io, port),
            .spaces = .init(gpa),
            .chats = .init(gpa),
            .sessions = .init(gpa),
            .transcript = .{ .gpa = gpa },
            .harnesses = .init(gpa),
            .models = .init(gpa),
            .release = .{ .gpa = gpa, .io = io },
        };
    }

    /// Starts the connection; `a` must stay where it is from now on.
    pub fn start(a: *App) !void {
        a.engine.events = .{ .ctx = a, .state = stateChanged };
        try a.engine.start();
    }

    pub fn deinit(a: *App) void {
        a.engine.deinit();
        a.spaces.deinit();
        a.chats.deinit();
        a.sessions.deinit();
        a.transcript.deinit();
        if (a.selected) |s| a.gpa.free(s);
        if (a.space) |s| a.gpa.free(s);
        if (a.device_id) |d| a.gpa.free(d);
        if (a.new_model) |m| a.gpa.free(m);
        a.gpa.free(a.new_harness);
        a.harnesses.deinit();
        a.models.deinit();
    }

    /// The agent new chats start with.
    pub fn setHarness(a: *App, id: []const u8) void {
        const copy = a.gpa.dupe(u8, id) catch return;
        a.gpa.free(a.new_harness);
        a.new_harness = copy;
        a.setModel(null);
        a.models.replace(.{ .array = .init(a.gpa) }) catch {};
        a.picker = .none;
        if (a.engine.state == .connected) a.call("ListModels", .{ .harness = id }, .of(App, a, onModels));
        a.redraw();
    }

    /// The model new chats start with; null is the agent's default.
    pub fn setModel(a: *App, id: ?[]const u8) void {
        if (a.new_model) |m| a.gpa.free(m);
        a.new_model = if (id) |m| a.gpa.dupe(u8, m) catch null else null;
        a.picker = .none;
        a.redraw();
    }

    pub fn harnessName(a: *const App, id: []const u8) []const u8 {
        for (a.harnesses.items) |h| if (std.mem.eql(u8, h.id, id)) return h.name;
        return id;
    }

    pub fn modelLabel(a: *const App, id: ?[]const u8) []const u8 {
        const want = id orelse return "Default model";
        for (a.models.items) |m| if (std.mem.eql(u8, m.id, want)) return m.label;
        return want;
    }

    /// Asks for a folder and adds it as a space on this device, as the
    /// GPUI app's "Add folder" does (`createSpace`).
    pub fn addFolder(a: *App) void {
        const device = a.device_id orelse return a.setNotice("The engine hasn't said which device it is yet.");
        const picked = nanoui.dialog.open(a.gpa, .{ .title = "Add a folder", .button = "Add", .files = false, .directories = true }) catch return;
        const paths = picked orelse return;
        defer nanoui.dialog.freePaths(a.gpa, paths);
        if (paths.len == 0) return;
        var buf: [36]u8 = undefined;
        const id = uuid(a.io, &buf);
        var git_buf: [4096]u8 = undefined;
        const git_path = std.fmt.bufPrint(&git_buf, "{s}/.git", .{paths[0]}) catch "";
        const git = std.Io.Dir.cwd().access(a.io, git_path, .{}) != error.FileNotFound;
        a.call("Mutate", .{ .op = "createSpace", .spaceId = id, .deviceId = device, .path = paths[0], .gitDetected = git }, .of(App, a, onNotice));
        a.select(null, id);
    }

    pub fn releaseCame(ctx: *anyopaque) void {
        const a: *App = @ptrCast(@alignCast(ctx));
        a.redraw();
    }

    fn redraw(a: *App) void {
        if (a.window) |w| w.redraw();
    }

    fn stateChanged(ctx: ?*anyopaque, s: engine_mod.State) void {
        const a: *App = @ptrCast(@alignCast(ctx.?));
        switch (s) {
            .connected => {
                a.call("EngineInfo", rpc.empty, .of(App, a, onEngineInfo));
                a.call("ListHarnesses", rpc.empty, .of(App, a, onHarnesses));
                a.call("ListModels", .{ .harness = a.new_harness }, .of(App, a, onModels));
                a.call("EngineReady", rpc.empty, .of(App, a, onNotice));
                a.watchSidebar();
                if (a.selected != null) a.watchDoc(true);
            },
            .disconnected, .connecting => {
                // Every stream ended with the socket; they open on reconnect.
                a.w_spaces = .{};
                a.w_chats = .{};
                a.w_sessions = .{};
                a.w_doc = .{};
            },
        }
        a.redraw();
    }

    fn call(a: *App, method: []const u8, params: anytype, h: rpc.Handler) void {
        _ = a.engine.call(method, params, h);
    }

    fn watchSidebar(a: *App) void {
        if (a.w_spaces.id == null) a.w_spaces = .{ .id = a.engine.call("WatchSpaces", rpc.empty, .of(App, a, onSpaces)) };
        if (a.w_chats.id == null) a.w_chats = .{ .id = a.engine.call("WatchChats", rpc.empty, .of(App, a, onChats)) };
        if (a.w_sessions.id == null) a.w_sessions = .{ .id = a.engine.call("WatchSessions", rpc.empty, .of(App, a, onSessions)) };
    }

    /// Streams to open again, now that it's time; the seconds until the next.
    pub fn tick(a: *App, now: f64) ?f32 {
        a.now = now;
        var next: ?f64 = null;
        inline for (.{ "w_spaces", "w_chats", "w_sessions", "w_doc" }) |name| {
            const w = &@field(a, name);
            if (w.retry_at) |t| {
                if (now >= t) {
                    w.* = .{};
                    if (comptime std.mem.eql(u8, name, "w_doc")) a.watchDoc(false) else a.watchSidebar();
                } else next = if (next) |n| @min(n, t) else t;
            }
        }
        return if (next) |n| @floatCast(n - now) else null;
    }

    /// A stream ended or failed: try again soon, while connected.
    fn ended(a: *App, w: *Watch) void {
        w.id = null;
        if (a.engine.state == .connected) w.retry_at = a.now + retry_s;
    }

    fn onSpaces(a: *App, _: u64, r: rpc.Reply) void {
        switch (r) {
            .item => |v| a.spaces.replace(v) catch {},
            .done, .err => a.ended(&a.w_spaces),
            .ok => {},
        }
        a.redraw();
    }

    fn onChats(a: *App, _: u64, r: rpc.Reply) void {
        switch (r) {
            .item => |v| {
                a.chats.replace(v) catch {};
                workspace.sortChats(a.chats.items);
            },
            .done, .err => a.ended(&a.w_chats),
            .ok => {},
        }
        a.redraw();
    }

    fn onSessions(a: *App, _: u64, r: rpc.Reply) void {
        switch (r) {
            .item => |v| a.sessions.replace(v) catch {},
            .done, .err => a.ended(&a.w_sessions),
            .ok => {},
        }
        a.redraw();
    }

    fn onDoc(a: *App, id: u64, r: rpc.Reply) void {
        if (a.w_doc.id != id) return;
        switch (r) {
            .item => |v| a.transcript.apply(v) catch {
                // Out of step: start over from a fresh reset.
                a.engine.cancel(id);
                a.w_doc = .{};
                a.watchDoc(false);
            },
            .done, .err => a.ended(&a.w_doc),
            .ok => {},
        }
        a.redraw();
    }

    fn onEngineInfo(a: *App, _: u64, r: rpc.Reply) void {
        const v = switch (r) {
            .ok => |v| v,
            else => return,
        };
        if (v != .object) return;
        const id = v.object.get("deviceId") orelse return;
        if (id != .string) return;
        if (a.device_id) |d| a.gpa.free(d);
        a.device_id = a.gpa.dupe(u8, id.string) catch null;
    }

    fn onHarnesses(a: *App, _: u64, r: rpc.Reply) void {
        switch (r) {
            .ok => |v| a.harnesses.replace(v) catch {},
            .err => |e| a.setNotice(e),
            else => {},
        }
        a.redraw();
    }

    fn onModels(a: *App, _: u64, r: rpc.Reply) void {
        switch (r) {
            .ok => |v| a.models.replace(v) catch {},
            else => {},
        }
        a.redraw();
    }

    fn onNotice(a: *App, _: u64, r: rpc.Reply) void {
        switch (r) {
            .err => |e| {
                if (std.mem.startsWith(u8, e, "unknown method")) return;
                a.setNotice(e);
                a.redraw();
            },
            else => {},
        }
    }

    fn setNotice(a: *App, text: []const u8) void {
        const n = @min(text.len, a.notice.len);
        @memcpy(a.notice[0..n], text[0..n]);
        a.notice_len = n;
    }

    pub fn noticeText(a: *const App) ?[]const u8 {
        return if (a.notice_len == 0) null else a.notice[0..a.notice_len];
    }

    fn watchDoc(a: *App, opening: bool) void {
        const chat = a.selected orelse return;
        a.w_doc = .{ .id = a.engine.call("WatchDocMessages", .{ .chatId = chat, .openingTail = opening }, .of(App, a, onDoc)) };
    }

    /// Opens `chat_id`, or (null) a new chat in `space_id`.
    pub fn select(a: *App, chat_id: ?[]const u8, space_id: ?[]const u8) void {
        if (a.w_doc.id) |id| a.engine.cancel(id);
        a.w_doc = .{};
        a.transcript.clear();
        a.notice_len = 0;
        if (a.selected) |s| a.gpa.free(s);
        a.selected = if (chat_id) |c| a.gpa.dupe(u8, c) catch null else null;
        if (space_id) |s| {
            if (a.space) |old| a.gpa.free(old);
            a.space = a.gpa.dupe(u8, s) catch null;
        }
        const chat = a.selected orelse return a.redraw();
        a.call("FocusChat", .{ .chatId = chat }, .of(App, a, onNotice));
        a.call("Mutate", .{ .op = "markChatSeen", .chatId = chat }, .of(App, a, onNotice));
        a.watchDoc(true);
        a.redraw();
    }

    pub fn findChat(a: *const App, id: []const u8) ?workspace.Chat {
        for (a.chats.items) |c| if (std.mem.eql(u8, c.id, id)) return c;
        return null;
    }

    pub fn findSpace(a: *const App, id: ?[]const u8) ?workspace.Space {
        const want = id orelse return null;
        for (a.spaces.items) |s| if (std.mem.eql(u8, s.id, want)) return s;
        return null;
    }

    pub fn selectedStatus(a: *const App) workspace.Status {
        const id = a.selected orelse return .idle;
        return workspace.statusOf(a.sessions.items, id);
    }

    /// Sends what the composer holds: to the open chat, or to a new one.
    pub fn send(a: *App) void {
        const prompt = std.mem.trim(u8, a.composer.text(), " \n\t");
        if (prompt.len == 0 or a.engine.state != .connected) return;
        var chat_buf: [36]u8 = undefined;
        var message_buf: [36]u8 = undefined;
        const message_id = uuid(a.io, &message_buf);
        var harness: ?[]const u8 = null;
        var model: ?[]const u8 = null;
        var cwd: []const u8 = "~";
        const chat_id = if (a.selected) |id| blk: {
            if (a.findChat(id)) |c| {
                harness = c.harness;
                model = c.model;
                if (c.cwd) |d| cwd = d;
            }
            break :blk id;
        } else blk: {
            const id = uuid(a.io, &chat_buf);
            const space = a.findSpace(a.space) orelse if (a.spaces.items.len > 0) a.spaces.items[0] else null;
            if (space) |s| cwd = s.path;
            harness = a.new_harness;
            model = a.new_model;
            a.call("Mutate", .{
                .op = "createChat",
                .chatId = id,
                .spaceId = if (space) |s| s.id else null,
                .config = .{ .harness = a.new_harness, .model = a.new_model, .modelOptions = rpc.empty, .sandbox = "workspace-write" },
            }, .of(App, a, onNotice));
            break :blk id;
        };
        a.call("QueueCommand", .{
            .chatId = chat_id,
            .command = .{
                .kind = "run",
                .messageId = message_id,
                .request = .{
                    .prompt = prompt,
                    .turnOrigin = "human",
                    .harness = harness,
                    .model = model,
                    .modelOptions = rpc.empty,
                    .cwd = cwd,
                    .sandbox = "workspace-write",
                    .autoApprove = false,
                },
            },
        }, .of(App, a, onNotice));
        if (a.selected == null) a.select(chat_id, null);
        a.composer.clear();
        a.redraw();
    }

    /// Stops the open chat's turn.
    pub fn interrupt(a: *App) void {
        const chat = a.selected orelse return;
        a.call("QueueCommand", .{ .chatId = chat, .command = .{ .kind = "interrupt" } }, .of(App, a, onNotice));
    }
};

/// A version 4 UUID, as the GPUI app mints chat and message ids.
pub fn uuid(io: std.Io, out: *[36]u8) []const u8 {
    var b: [16]u8 = undefined;
    io.random(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const hex = "0123456789abcdef";
    var o: usize = 0;
    for (b, 0..) |x, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[o] = '-';
            o += 1;
        }
        out[o] = hex[x >> 4];
        out[o + 1] = hex[x & 15];
        o += 2;
    }
    return out;
}

test "uuids are version 4" {
    var buf: [36]u8 = undefined;
    const u = uuid(std.testing.io, &buf);
    try std.testing.expectEqual(@as(u8, '4'), u[14]);
    try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", u[19]) != null);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, u, "-"));
}
