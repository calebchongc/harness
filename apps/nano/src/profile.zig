//! `harness-nano-profile replay.json out-dir`: the GPUI app's UI-only
//! resource replay (crates/ui/examples/macos-resource-profile.rs) for
//! harness-nano, so the two can be measured side by side by the same
//! sampler (bench/resource.py): one 1320 by 880 window at 2x, offscreen,
//! with real CoreText and Metal and real clocks; the replay's transcript
//! frames applied when their time comes, a frame built and drawn (into a
//! texture kept across frames, as a window's drawable, never read back)
//! only when something changed or moves, polled every 8 ms as GPUI's is;
//! then 15 seconds settled. `phase=replay` and `phase=settled` on stderr
//! mark the phases; `complete.png` is the settled frame.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const App = @import("app.zig").App;
const theme = @import("theme.zig");
const json = std.json;

pub fn main(init: std.process.Init) !void {
    theme.registerFonts();
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: harness-nano-profile replay.json out-dir\n", .{});
        return error.Usage;
    }
    const out = args[2];
    try std.Io.Dir.cwd().createDirPath(io, out);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(256 << 20));
    defer gpa.free(text);
    const parsed = try json.parseFromSlice(json.Value, gpa, text, .{});
    defer parsed.deinit();
    const frames = parsed.value.array.items;

    var a: App = .init(gpa, io, 1);
    defer a.deinit();
    a.offscreen = true;
    a.dark = true;
    a.new_harness = try gpa.dupe(u8, "claude-code");
    // The GPUI profile's one project and chat.
    const setup = try json.parseFromSlice(json.Value, gpa,
        \\{"spaces":[{"id":"project","deviceId":"local","path":"/tmp/resource-profile","gitDetected":true,"createdAt":"2026-09-05T00:00:00Z"}],
        \\ "chats":[{"id":"profile","deviceId":"local","spaceId":"project","title":"Resource profile","archived":false,"createdAt":"2026-09-05T00:00:00Z",
        \\   "config":{"harness":"claude-code","model":"claude-haiku-4-5","reasoning":null,"modelOptions":{},"sandbox":"workspace-write"}}]}
    , .{});
    defer setup.deinit();
    try a.spaces.replace(setup.value.object.get("spaces").?);
    try a.chats.replace(setup.value.object.get("chats").?);
    a.openChat("profile", null);

    const size: ui.Size = .{ .w = 1320, .h = 880 };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&a, @import("view.zig").view), .{ .width = size.w, .height = size.h, .scale = 2, .dark = true, .theme = theme.ui(true) });
    defer t.deinit();
    const Draw = struct {
        target: if (has_target) nanoui.objc.Object else void,
        frames: u64 = 0,
        build_ms: f64 = 0,
        encode_ms: f64 = 0,
        gpu_ms: f64 = 0,
    };
    // Pictures go straight to the GPU, as a window's do (surface.zig):
    // without the sink first, the image atlas keeps a 16 MB copy in memory.
    // The tester's own first frame packed them before the sink: that copy
    // goes, and they pack again through it.
    if (has_target) {
        const im = &t.text.images;
        im.sink = .{ .ctx = &t.renderer, .upload = @FieldType(ui.Tester, "renderer").uploadImage };
        if (im.pixels.len > 0) gpa.free(im.pixels);
        im.pixels = &.{};
        im.entries.clearRetainingCapacity();
        im.shelf_x = 0;
        im.shelf_y = 0;
        im.shelf_h = 0;
    }
    var draw: Draw = .{ .target = if (has_target) t.renderer.newTarget(size, 2) else {} };
    defer if (has_target) nanoui.objc.release(draw.target);

    const clock = std.Io.Clock.awake;
    const start = clock.now(io).toNanoseconds();
    const ms = struct {
        fn since(i: std.Io, s: i96) f64 {
            return @as(f64, @floatFromInt(clock.now(i).toNanoseconds() - s)) / 1e6;
        }
    };
    std.debug.print("pid={d} phase=replay\n", .{std.c.getpid()});
    const first_at = frames[0].object.get("at").?.integer;
    var next: usize = 0;
    var dirty = true;
    var wake_at: ?f64 = null;
    var completed: ?f64 = null;
    var last_frame_ms: f64 = 0;
    while (true) {
        const elapsed = ms.since(io, start);
        while (next < frames.len and @as(f64, @floatFromInt(frames[next].object.get("at").?.integer - first_at)) <= elapsed) : (next += 1) {
            a.transcript.apply(frames[next].object.get("frame").?) catch |e| {
                std.debug.print("frame {d}: {t}\n", .{ next, e });
                return e;
            };
            dirty = true;
        }
        if (wake_at) |w| if (elapsed >= w) {
            dirty = true;
        };
        if (dirty) {
            dirty = false;
            wake_at = null;
            // Real time, as a window's frames have it.
            t.dt = @floatCast(@max(0.001, (elapsed - last_frame_ms) / 1000));
            t.time = @floatCast(elapsed / 1000);
            last_frame_ms = elapsed;
            const b0 = ms.since(io, start);
            t.frame();
            draw.build_ms += ms.since(io, start) - b0;
            if (has_target) {
                t.renderer.syncImages(&t.text.images);
                t.renderer.textures = t.ctx.textures.items;
                const timing = t.renderer.drawTimed(draw.target, t.instances.items, t.text.texture(), size, t.theme.background);
                draw.encode_ms += timing.encode_ms;
                draw.gpu_ms += timing.gpu_ms;
            }
            draw.frames += 1;
            if (t.ctx.animating) dirty = true else if (t.ctx.frame_in) |s| {
                wake_at = elapsed + s * 1000;
            }
        }
        if (next >= frames.len and completed == null) {
            completed = elapsed;
            std.debug.print("phase=settled elapsed={d:.0}ms\n", .{elapsed});
            var buf: [1024]u8 = undefined;
            t.screenshot(try std.fmt.bufPrint(&buf, "{s}/complete.png", .{out})) catch {};
        }
        if (completed) |c| if (elapsed - c > 15_000) break;
        std.Io.sleep(io, .fromMilliseconds(8), .awake) catch {};
    }
    var buf: [1024]u8 = undefined;
    const stats = try std.fmt.bufPrint(&buf, "{{\"framesDrawn\":{d},\"buildMs\":{d:.1},\"encodeMs\":{d:.1},\"gpuMs\":{d:.1},\"replayFrames\":{d}}}\n", .{ draw.frames, draw.build_ms, draw.encode_ms, draw.gpu_ms, frames.len });
    var path_buf: [1024]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.bufPrint(&path_buf, "{s}/nano-stats.json", .{out}), .data = stats });
    std.debug.print("{s}", .{stats});
}

/// A nanoui with targets kept across frames (the fork's benchmark draw).
const has_target = @hasField(ui.Tester, "renderer") and @hasDecl(@FieldType(ui.Tester, "renderer"), "drawTimed");
