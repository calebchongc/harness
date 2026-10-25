//! Settings › Accounts' cloud sandboxes card, as the GPUI app's
//! (`render_codegraff_sandboxes` in settings/accounts.rs, the list as
//! state/cloud_sandboxes.rs keeps it): each sandbox with Copy ID, Start or
//! Set up Harness, Keep running, Turn off and Delete (asking first), then
//! "Harness cloud" with its sizes and Create, and "Temporary sandbox" with
//! Create temporary. Shown only when the list says it's enabled; read when
//! the page loads and every 60 seconds while one runs. The calls are never
//! retargeted: the sandboxes belong to this device's Codegraff sign-in.
const std = @import("std");
const json = std.json;
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const kit = @import("view_kit.zig");
const set = @import("view_settings.zig");
const rpc = @import("rpc.zig");
const sandboxes = @import("sandboxes.zig");
const rows = @import("view_settings_accounts_rows.zig");
const page = @import("view_settings_accounts.zig");
const App = @import("app.zig").App;
const Allocator = std.mem.Allocator;

const st = rows.st;

/// How often a running sandbox's state is read again (`REFRESH_EVERY`).
const refresh_s: f64 = 60;

/// The card's own state; the list is the page's `sandboxes` slot.
pub const Cloud = struct {
    next_read: ?f64 = null,
    /// The sandbox with an action in flight, and which (`start`, `stop`,
    /// `keep-running-on`, `delete`).
    busy: ?[]u8 = null,
    busy_action: []const u8 = "",
    /// Delete asks for a second click.
    confirm_delete: ?[]u8 = null,
    creating: bool = false,
    /// The size picked for the next sandbox (null: the default).
    size: ?[]u8 = null,
    /// The strip's Turn off is in flight, and how many pauses it waits for.
    turning_off: usize = 0,

    pub fn deinit(cl: *Cloud, gpa: Allocator) void {
        inline for (.{ "busy", "confirm_delete", "size" }) |f| if (@field(cl, f)) |x| gpa.free(x);
    }
};

fn cloud(a: *App) *Cloud {
    return &a.view.accounts.cloud;
}

/// The list, when there is one to show.
fn list(a: *App) ?sandboxes.List {
    const l = (a.view.accounts.sandboxes.get() orelse return null) orelse return null;
    return if (l.enabled) l else null;
}

/// Read the list now (`refresh_cloud_sandboxes`).
pub fn refresh(a: *App) void {
    if (!page.engineUp(a)) return;
    cloud(a).next_read = null;
    const s = &a.view.accounts.sandboxes;
    s.call = a.engine.call("CodegraffSandboxes", rpc.empty, .of(App, a, onList));
}

fn onList(a: *App, id: u64, r: rpc.Reply) void {
    const s = &a.view.accounts.sandboxes;
    if (id != 0 and s.call != id) return;
    s.call = null;
    switch (r) {
        .ok => |v| page.feedSandboxes(a, v),
        // A failed read keeps the last answer, and tries again on the timer.
        else => schedule(a),
    }
    a.redraw();
}

/// One timer while anything runs; none otherwise.
pub fn schedule(a: *App) void {
    const l = (a.view.accounts.sandboxes.get() orelse null) orelse {
        cloud(a).next_read = null;
        return;
    };
    cloud(a).next_read = if (sandboxes.needsRefresh(l)) a.now + refresh_s else null;
}

/// From the page's frame: read again when it's time.
pub fn tick(c: *ui.Context, a: *App) void {
    const t = cloud(a).next_read orelse return;
    if (c.time >= t) return refresh(a);
    c.frameIn(@floatCast(t - c.time));
}

/// Start, Turn off, Keep running or Delete (`CodegraffSandboxAction`).
fn act(a: *App, id: []const u8, action: []const u8) void {
    if (!page.engineUp(a)) return;
    const cl = cloud(a);
    page.replace(a.gpa, &cl.busy, id);
    cl.busy_action = action;
    page.replace(a.gpa, &cl.confirm_delete, null);
    a.view.accounts.notice.clearRetainingCapacity();
    a.call("CodegraffSandboxAction", .{ .id = id, .action = action }, .of(App, a, onDone));
}

/// Create (a Harness device, at the size picked) or Create temporary.
fn create(a: *App, temporary: bool) void {
    if (!page.engineUp(a)) return;
    const cl = cloud(a);
    cl.creating = true;
    a.view.accounts.notice.clearRetainingCapacity();
    if (temporary) return a.call("CodegraffCreateTemporarySandbox", rpc.empty, .of(App, a, onDone));
    const size: ?[]const u8 = if (list(a)) |l| (if (sandboxes.selectedSize(l.sizes, cl.size)) |s| s.id else null) else null;
    a.call("CodegraffCreateSandbox", .{ .size = size }, .of(App, a, onDone));
}

fn onDone(a: *App, _: u64, r: rpc.Reply) void {
    const cl = cloud(a);
    page.replace(a.gpa, &cl.busy, null);
    cl.creating = false;
    if (r == .err) page.setNotice(a, page.why(r.err));
    refresh(a);
    a.redraw();
}

/// The card (`render_codegraff_sandboxes`): nothing while signed out or
/// where it isn't offered.
pub fn card(c: *ui.Context, a: *App, k: theme.Colors) void {
    const l = list(a) orelse return;
    const cl = cloud(a);
    const now = a.nowMs();
    set.space(c, 16);
    ui.text(c, "Cloud sandboxes", st(c, 12, .{ .weight = .medium, .color = k.muted }));
    const cd = rows.card(c, k, 8);
    defer cd.end();
    for (l.sandboxes, 0..) |s, ix| {
        ui.key(c, c.print("codegraff-sandbox-{d}", .{ix}));
        if (ix > 0) rows.line(c, k);
        sandboxRow(c, a, k, s, now);
    }
    if (l.sandboxes.len > 0) rows.line(c, k);
    {
        ui.key(c, "codegraff-sandbox-create-row");
        const create_g: rows.Ghost = .{ .label = if (cl.creating) "Creating…" else "Create", .dim = cl.creating };
        const r = ui.div(c).row().wFull().px(20).py(10).gap(12).itemsCenter();
        defer r.end();
        const w = rows.rowInner() - 12 - rows.ghostW(c, create_g);
        {
            const col = ui.div(c).column().w(w);
            defer col.end();
            rows.title(c, k, "Harness cloud", w);
            set.space(c, 2);
            ui.text(c, "A machine that runs Harness for you and shows up in your devices. " ++ sandboxes.create_copy, st(c, 11.5, .{ .wrap = true, .color = k.muted }));
            if (l.sizes.len > 0) sizeChoice(c, a, k, l.sizes, w);
        }
        if (rows.ghost(c, k, create_g) and !cl.creating) create(a, false);
    }
    rows.line(c, k);
    ui.key(c, "codegraff-temporary-sandbox-create-row");
    const temp_g: rows.Ghost = .{ .label = if (cl.creating) "Creating…" else "Create temporary", .dim = cl.creating };
    const r = ui.div(c).row().wFull().px(20).py(12).gap(12).itemsCenter();
    defer r.end();
    const w = rows.rowInner() - 12 - rows.ghostW(c, temp_g);
    {
        const col = ui.div(c).column().w(w);
        defer col.end();
        rows.title(c, k, "Temporary sandbox", w);
        set.space(c, 2);
        ui.text(c, sandboxes.temporary_copy, st(c, 11.5, .{ .wrap = true, .color = k.muted }));
    }
    if (rows.ghost(c, k, temp_g) and !cl.creating) create(a, true);
}

/// One sandbox: its title and detail, then the actions it offers.
fn sandboxRow(c: *ui.Context, a: *App, k: theme.Colors, s: sandboxes.Sandbox, now: i64) void {
    const cl = cloud(a);
    const busy: ?[]const u8 = if (cl.busy) |b| (if (std.mem.eql(u8, b, s.id)) cl.busy_action else null) else null;
    const any = busy != null;
    const confirming = if (cl.confirm_delete) |x| std.mem.eql(u8, x, s.id) else false;
    const start = sandboxes.startLabels(s);
    const G = struct { g: rows.Ghost, what: enum { copy, start, keep, stop, delete } };
    var gs: [5]G = undefined;
    var n: usize = 0;
    if (sandboxes.isTemporary(s)) {
        gs[n] = .{ .g = .{ .label = "Copy ID" }, .what = .copy };
        n += 1;
    }
    if (sandboxes.canStart(s)) {
        gs[n] = .{ .g = .{ .label = if (eqOpt(busy, "start")) start[1] else start[0], .dim = any }, .what = .start };
        n += 1;
    }
    if (sandboxes.canKeepRunning(s)) {
        gs[n] = .{ .g = .{ .label = if (eqOpt(busy, "keep-running-on")) "Keeping running…" else "Keep running", .dim = any }, .what = .keep };
        n += 1;
    }
    if (sandboxes.canStop(s)) {
        gs[n] = .{ .g = .{ .label = if (eqOpt(busy, "stop")) sandboxes.turn_off[1] else sandboxes.turn_off[0], .dim = any }, .what = .stop };
        n += 1;
    }
    gs[n] = .{ .g = .{ .label = if (eqOpt(busy, "delete")) "Deleting…" else if (confirming) "Delete for good?" else "Delete", .dim = any }, .what = .delete };
    n += 1;
    var actions_w: f32 = 0;
    for (gs[0..n]) |x| actions_w += 12 + rows.ghostW(c, x.g);
    const r = ui.div(c).row().wFull().px(20).py(10).gap(12).itemsCenter();
    defer r.end();
    const w = rows.rowInner() - actions_w;
    {
        const col = ui.div(c).column().grow().w(0);
        defer col.end();
        rows.title(c, k, sandboxes.title(s), w);
        set.space(c, 2);
        kit.ellipsisText(c, sandboxes.detail(c.alloc(), s, now) catch "", st(c, 11.5, .{ .color = k.muted }), w);
    }
    for (gs[0..n]) |x| if (rows.ghost(c, k, x.g)) switch (x.what) {
        .copy => c.clipboard.write(c.clipboard.ctx, s.id),
        .start => if (!any) act(a, s.id, "start"),
        .keep => if (!any) act(a, s.id, "keep-running-on"),
        .stop => if (!any) act(a, s.id, "stop"),
        .delete => if (!any) {
            if (confirming) act(a, s.id, "delete") else page.replace(a.gpa, &cl.confirm_delete, s.id);
        },
    };
}

fn eqOpt(x: ?[]const u8, y: []const u8) bool {
    return if (x) |v| std.mem.eql(u8, v, y) else false;
}

/// Standard / Large, what each is and costs, the default preselected:
/// cards at least 180 wide, wrapping 8 apart.
fn sizeChoice(c: *ui.Context, a: *App, k: theme.Colors, sizes: []const sandboxes.Size, w: f32) void {
    const cl = cloud(a);
    const picked = sandboxes.selectedSize(sizes, cl.size);
    set.space(c, 8);
    const box = ui.div(c).column().w(w).gap(8);
    defer box.end();
    var line: ?ui.Div = null;
    var used: f32 = 0;
    for (sizes, 0..) |s, ix| {
        const title = sandboxes.sizeTitle(c.alloc(), s) catch "";
        const detail = sandboxes.sizeDetail(c.alloc(), s) catch "";
        const card_w = @max(180, 2 * 12 + @max(c.text.width(title, .{ .size = 12.5, .weight = .medium }), c.text.width(detail, .{ .size = 11.5 })));
        // `flex_wrap`: a card that doesn't fit starts the next line.
        if (line == null or used + 8 + card_w > w) {
            if (line) |l| l.end();
            line = ui.div(c).row().gap(8);
            used = card_w;
        } else used += 8 + card_w;
        ui.key(c, c.print("codegraff-sandbox-size-{d}", .{ix}));
        const selected = if (picked) |p| std.mem.eql(u8, p.id, s.id) else false;
        var b = ui.div(c).column().w(card_w).px(13).py(9).gap(2).rounded(8).borderW(1)
            .border(if (selected) k.accent.alpha(0.6) else k.border)
            .bg(if (selected) k.accent_wash else k.ink(0.02));
        if (!cl.creating) b = b.hover(k.ink(0.05));
        defer b.end();
        ui.text(c, title, st(c, 12.5, .{ .weight = .medium, .color = k.text }));
        ui.text(c, detail, st(c, 11.5, .{ .color = k.muted }));
        if (!cl.creating and b.clicked()) page.replace(a.gpa, &cl.size, s.id);
    }
    if (line) |l| l.end();
}

/// The "Cloud sandbox running" strip (shell/cloud_sandbox_strip.rs), in
/// the settings sidebar above Back: a live dot, what it costs or why it
/// will pause, and a one-click Turn off. Its label opens Accounts.
pub fn strip(c: *ui.Context, a: *App, k: theme.Colors) void {
    const l = list(a) orelse return;
    const sum = (sandboxes.runningSummary(c.alloc(), l, a.nowMs()) catch return) orelse return;
    const cl = cloud(a);
    const tone = if (sum.warning) k.warning else k.accent;
    const w: f32 = @import("view_sidebar.zig").width - 2 * 8;
    const pad = ui.div(c).column().wFull().px(8).pb(4);
    defer pad.end();
    ui.key(c, "cloud-sandbox-strip");
    const s = ui.div(c).row().w(w).px(9).py(7).gap(8).itemsCenter().rounded(6)
        .bg(if (sum.warning) k.warning.alpha(0.12) else k.accent_wash).border(tone.alpha(0.3)).borderW(1);
    defer s.end();
    const label: []const u8 = if (cl.turning_off > 0) sandboxes.turn_off[1] else if (sum.running_ids.len == 1) sandboxes.turn_off[0] else "Turn off all";
    const button_w: f32 = if (sum.running_ids.len > 0) 8 + 18 + c.text.width(label, .{ .size = 11, .weight = .medium }) else 0;
    const text_w = w - 2 * 9 - button_w;
    {
        const open = ui.div(c).column().w(text_w).gap(1);
        defer open.end();
        {
            const top = ui.div(c).row().gap(6).itemsCenter();
            defer top.end();
            kit.dot(c, 6, tone);
            kit.ellipsisText(c, sum.label, st(c, 11, .{ .weight = .medium, .color = k.text }), text_w - 12);
        }
        {
            const d = ui.div(c).row().pl(12);
            defer d.end();
            kit.ellipsisText(c, sum.detail, st(c, 10.5, .{ .color = if (sum.warning) k.warning else k.muted }), text_w - 12);
        }
        if (open.clicked()) {
            a.settings.setSection(.agents);
            a.redraw();
        }
    }
    if (sum.running_ids.len == 0) return;
    var b = ui.div(c).row().px(9).py(4).rounded(6).border(k.border).borderW(1).bg(k.raised);
    if (cl.turning_off > 0) b = b.opacity(0.6) else b = b.hover(k.raised.mix(k.text, 0.06));
    defer b.end();
    ui.text(c, label, st(c, 11, .{ .weight = .medium, .color = k.text }));
    if (cl.turning_off == 0 and b.clicked() and page.engineUp(a)) {
        // Pause every running one, then read the list again.
        cl.turning_off = sum.running_ids.len;
        for (sum.running_ids) |id| a.call("CodegraffSandboxAction", .{ .id = id, .action = "stop" }, .of(App, a, onTurnedOff));
    }
}

fn onTurnedOff(a: *App, _: u64, r: rpc.Reply) void {
    const cl = cloud(a);
    if (r == .err) {
        var buf: [256]u8 = undefined;
        a.setNotice(std.fmt.bufPrint(&buf, "Couldn't turn off the cloud sandbox: {s}", .{page.why(r.err)}) catch "Couldn't turn off the cloud sandbox");
    }
    cl.turning_off -|= 1;
    if (cl.turning_off == 0) refresh(a);
    a.redraw();
}
