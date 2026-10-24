//! The connection to a Harness engine: the daemon (or `harness headless`)
//! on `ws://127.0.0.1:{HARNESS_IPC_PORT|27664}`.
//!
//! A thread of its own dials and reads; each message reaches the UI thread
//! through `nanoui.App.after` and goes to `rpc.Mux` there. Calls are written
//! from the UI thread. When the socket drops, every call ends with an error
//! and the thread dials again after a pause.
const std = @import("std");
const nanoui = @import("nanoui");
const ws = @import("ws.zig");
const rpc = @import("rpc.zig");
const Allocator = std.mem.Allocator;

pub const default_port: u16 = 27664;

pub const State = enum { connecting, connected, disconnected };

pub const Events = struct {
    ctx: ?*anyopaque = null,
    /// On the UI thread: connected (watches start here) or lost.
    state: ?*const fn (ctx: ?*anyopaque, State) void = null,
};

pub const Engine = struct {
    gpa: Allocator,
    io: std.Io,
    port: u16,
    events: Events = .{},
    mux: rpc.Mux,
    state: State = .connecting,
    /// The client calls are written to, from the `connected` delivery on.
    client: ?*ws.Client = null,
    /// The client the reader thread holds, for `deinit` to wake it.
    live: std.atomic.Value(?*ws.Client) = .init(null),
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: Allocator, io: std.Io, port: u16) Engine {
        return .{ .gpa = gpa, .io = io, .port = port, .mux = .{ .gpa = gpa } };
    }

    /// The port in `HARNESS_IPC_PORT`, else the default.
    pub fn portFrom(env: *const std.process.Environ.Map) u16 {
        const v = env.get("HARNESS_IPC_PORT") orelse return default_port;
        return std.fmt.parseInt(u16, v, 10) catch default_port;
    }

    /// Starts dialing; `e` must stay where it is from now on.
    pub fn start(e: *Engine) !void {
        e.thread = try std.Thread.spawn(.{}, run, .{e});
    }

    pub fn deinit(e: *Engine) void {
        e.stopping.store(true, .release);
        if (e.live.load(.acquire)) |c| c.shutdown();
        if (e.thread) |t| t.join();
        if (e.live.load(.acquire)) |c| c.deinit(e.gpa);
        e.mux.deinit();
    }

    /// Calls `method`; `handler` hears the reply (or each stream item). The
    /// id cancels a stream. Without a connection it fails at once.
    pub fn call(e: *Engine, method: []const u8, params: anytype, handler: rpc.Handler) ?u64 {
        const c = if (e.state == .connected) e.client else null;
        if (c == null) {
            handler.func(handler.ctx, 0, .{ .err = "not connected" });
            return null;
        }
        const req = e.mux.call(method, params, handler) catch return null;
        defer e.gpa.free(req.frame);
        c.?.sendText(req.frame) catch {
            _ = e.mux.pending.remove(req.id);
            handler.func(handler.ctx, req.id, .{ .err = "send failed" });
            return null;
        };
        return req.id;
    }

    pub fn cancel(e: *Engine, id: u64) void {
        const frame = e.mux.cancel(id) catch return;
        defer e.gpa.free(frame);
        if (e.state == .connected) if (e.client) |c| c.sendText(frame) catch {};
    }

    fn run(e: *Engine) void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(e.gpa);
        while (!e.stopping.load(.acquire)) {
            const c = ws.Client.connect(e.gpa, e.io, e.port, "/") catch {
                e.post(.{ .state = .disconnected });
                e.pause();
                continue;
            };
            e.live.store(c, .release);
            e.post(.{ .state = .connected, .client = c });
            while (true) {
                _ = c.readMessage(e.gpa, &buf) catch break;
                const bytes = e.gpa.dupe(u8, buf.items) catch continue;
                e.post(.{ .message = bytes });
            }
            if (e.stopping.load(.acquire)) return;
            e.live.store(null, .release);
            e.post(.{ .state = .disconnected, .client = c });
            e.pause();
        }
    }

    fn pause(e: *Engine) void {
        // Two seconds, as the GPUI app waits before it resubscribes.
        var left: usize = 20;
        while (left > 0 and !e.stopping.load(.acquire)) : (left -= 1)
            std.Io.sleep(e.io, .fromMilliseconds(100), .awake) catch return;
    }

    const Delivery = struct {
        e: *Engine = undefined,
        message: ?[]u8 = null,
        state: ?State = null,
        /// The client the state is about: taken on connect, freed on loss.
        client: ?*ws.Client = null,

        fn run(ctx: ?*anyopaque) callconv(.c) void {
            const d: *Delivery = @ptrCast(@alignCast(ctx.?));
            const e = d.e;
            defer e.gpa.destroy(d);
            if (d.message) |m| {
                defer e.gpa.free(m);
                e.mux.dispatch(m) catch |err| std.log.warn("harness-nano: bad frame: {t}", .{err});
                return;
            }
            const s = d.state orelse return;
            switch (s) {
                .connected => e.client = d.client,
                .disconnected => if (d.client) |c| {
                    if (e.client == c) e.client = null;
                    e.mux.failAll("disconnected");
                    c.deinit(e.gpa);
                },
                .connecting => {},
            }
            if (e.state == s) return;
            e.state = s;
            if (e.events.state) |f| f(e.events.ctx, s);
        }
    };

    fn post(e: *Engine, d: Delivery) void {
        const p = e.gpa.create(Delivery) catch return;
        p.* = d;
        p.e = e;
        nanoui.App.after(0, p, Delivery.run);
    }
};
