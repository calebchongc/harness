//! The composer, as the GPUI composer draws it (crates/ui/src/composer.rs,
//! pickers.rs): one rounded pill with attach and dictate on the left, the
//! input ("Do anything…"), the model chip (the agent's mark, the model,
//! the reasoning level) and a round send button that becomes Stop while a
//! run goes with nothing typed. It expands with a line break, and always on
//! a new chat.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const kit = @import("view_kit.zig");
const rules = @import("rules.zig");
const transcript_view = @import("view_transcript.zig");
const App = @import("app.zig").App;

/// Docked under a chat's transcript.
pub fn docked(c: *ui.Context, a: *App, k: theme.Colors) void {
    const main_w = transcript_view.paneWidth(c, a);
    const w = @min(transcript_view.columnWidth(main_w) + 32, main_w - 32);
    const queue_view = @import("view_queue.zig");
    const queued = a.queue.items.len > 0;
    // 16 points of padding, over the window's 24-point status strip; the
    // pill covers the queue tray's foot, so it moves up as much.
    const outer = ui.div(c).column().wFull().px(16).pb(if (queued) 40 - queue_view.tuck else 40).itemsCenter();
    defer outer.end();
    // Keyed: the tray coming and going must not change the input's id
    // (which would take its focus).
    ui.key(c, "queue-tray");
    _ = queue_view.tray(c, a, k, w);
    ui.key(c, "composer");
    const lift: f32 = if (queued) -queue_view.tuck else 0;
    if (a.wizard != null) {
        const q = ui.div(c).column().offset(0, lift);
        defer q.end();
        return @import("view_question.zig").panel(c, a, k, w);
    }
    const expanded = std.mem.indexOfScalar(u8, a.composer.text(), '\n') != null;
    const p = ui.div(c).column().offset(0, lift);
    defer p.end();
    pill(c, a, k, w, if (expanded) .expanded else .compact, 22);
}

pub const Shape = enum { compact, expanded };

pub fn pill(c: *ui.Context, a: *App, k: theme.Colors, w: f32, shape: Shape, radius: f32) void {
    const p = kit.shadowLg(ui.div(c).w(w).bg(k.composer).border(k.border).borderW(1).rounded(radius));
    const box = if (shape == .compact) p.row().h(49).px(8).itemsCenter() else p.column();
    defer box.end();
    if (c.rects.get(c.node(box.index).id)) |r| a.view.composer_anchor = r;
    if (shape == .compact) {
        attachButtons(c, a, k);
        input(c, a, k, .compact);
        chip(c, a, k);
        send(c, a, k);
        return;
    }
    {
        // At least 76 tall, as GPUI's text area, growing with its lines.
        const area = ui.div(c).row().wFull();
        defer area.end();
        _ = c.leaf(.{ .width = .{ .px = 0 }, .height = .{ .px = 76 } }, .none, null);
        const inner = ui.div(c).column().grow().w(0).px(16).pt(16).pb(4);
        defer inner.end();
        input(c, a, k, .expanded);
    }
    // Expanded, the model sits after the paperclip, at most 45% of the
    // pill; Send keeps the end (`morph_cluster`).
    const actions = ui.div(c).row().wFull().h(42).px(12).pt(2).pb(8).itemsCenter();
    defer actions.end();
    attachButtons(c, a, k);
    {
        const m = ui.div(c).row().pl(2).maxW(w * 0.45).clip();
        defer m.end();
        chip(c, a, k);
    }
    ui.spacer(c);
    send(c, a, k);
}

/// Whether this device can dictate: the mic shows only then, as the GPUI
/// app's does when it detects dictation, which macOS has.
const dictation = @import("builtin").os.tag == .macos;

fn attachButtons(c: *ui.Context, a: *App, k: theme.Colors) void {
    if (kit.iconButton(c, k, .paperclip, .{ .size = 28, .radius = 14, .icon = 18 }))
        a.setNotice("Attachments aren't in Harness Nano yet.");
    if (!dictation) return;
    _ = c.leaf(.{ .width = .{ .px = 2 } }, .none, null);
    if (kit.iconButton(c, k, .microphone, .{ .size = 28, .radius = 14, .icon = 17 }))
        a.setNotice("Dictation isn't in Harness Nano yet.");
}

fn input(c: *ui.Context, a: *App, k: theme.Colors, shape: Shape) void {
    const box = if (shape == .compact) ui.div(c).row().grow().w(0).px(8).itemsCenter() else ui.div(c).column().wFull();
    defer box.end();
    const placeholder = if (a.engine.state != .connected)
        "Waiting for the engine…"
    else if (a.queue_edit != null)
        "Edit queued message…"
    else
        "Do anything…";
    const at = c.nodes.items.len;
    const r = ui.textField(c, &a.composer, .{
        .placeholder = placeholder,
        .width = .fill,
        .bare = true,
        .size = 14,
        // GPUI's composer: 22.75-point lines, its placeholder faint.
        .line_height = 22.75,
        .placeholder_color = k.faint,
        .multiline = true,
        .max_lines = 11,
    });
    // "Send messages with" (Settings › Shortcuts): Enter sends, or starts a
    // new line and ⌘↩ sends (`composerSendBehavior`).
    const on_enter = @import("view_settings_shortcuts.zig").sendsOnEnter(a);
    if (r.submitted) {
        if (on_enter) a.send() else {
            _ = a.composer.insert(r.caret, "\n");
            a.composer.want_caret = r.caret + 1;
        }
    }
    if (!on_enter and std.mem.trim(u8, a.composer.text(), " \n\t").len > 0 and c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true })) a.send();
    keepFocus(c, a, c.node(@intCast(at)).id);
    // ⌘↩ with nothing typed sends the newest queued message now.
    if (c.shortcut(.{ .key = ui.Shortcut.enter, .cmd = true }) and std.mem.trim(u8, a.composer.text(), " \n\t").len == 0) {
        if (a.queue.items.len > 0) a.queueSendNow(a.queue.items[a.queue.items.len - 1].id);
    }
    if (a.queue_edit != null and c.shortcut(.{ .key = ui.Shortcut.escape })) a.queueFinishEdit(.cancel);
    if (a.noticeText()) |n| {
        const line = ui.div(c).row().pt(4);
        defer line.end();
        ui.text(c, n, .{ .size = 11, .color = k.danger });
    }
}

/// The composer has the keys after the window moves to another chat, pane
/// or tab (`focus_composer`), and keeps them when its field moves in the
/// layout (into a split's pane, or taller with a second line), which
/// gives the field another id.
fn keepFocus(c: *ui.Context, a: *App, id: u64) void {
    const moved = a.view.composer_id != 0 and id != a.view.composer_id and c.focus == a.view.composer_id;
    if (a.view.focus_composer or moved) {
        c.focus = id;
        // Built again at once, focused: the next key finds it.
        c.changed = true;
        a.view.focus_composer = false;
    }
    a.view.composer_id = id;
}

/// The model chip: what the next message runs on.
fn chip(c: *ui.Context, a: *App, k: theme.Colors) void {
    const t = a.target();
    var b = ui.div(c).row().h(32).maxW(248).px(6).gap(6).itemsCenter().rounded(8).clip();
    b = if (a.picker != .none) b.bg(k.hover) else b.hover(k.hover);
    defer b.end();
    if (b.clicked()) a.togglePicker();
    if (c.rects.get(c.node(b.index).id)) |r| a.view.chip_anchor = r;
    // Before the engine lists them: the glyph spinner for an agent not yet
    // known (an open chat's is: its own), a pulsing bar for its model
    // (`trigger_chip` loading, `chip_icon_loading`).
    const chat_harness = if (a.selected) |id| (if (a.findChat(id)) |ch| ch.harness != null else false) else false;
    if (a.harnesses.items.len == 0 and !chat_harness) {
        kit.snake(c, k);
    } else {
        const mark = icons.harnessMark(t.harness);
        icons.icon(c, mark.name, 16, mark.brand orelse k.muted, 0);
    }
    if (a.models.items.len == 0 and t.model == null) return skeleton(c);
    ui.text(c, a.modelLabel(t.model), .{ .size = 12, .line_height = 12 * 1.618, .weight = .medium, .color = k.text.alpha(0.9) });
    if (t.reasoning) |level| ui.text(c, rules.reasoningLabel(level), .{ .size = 12, .line_height = 12 * 1.618, .weight = .medium, .color = k.muted.alpha(0.7) });
}

/// A label still loading: a 56 by 11 bar whose opacity breathes between
/// 0.35 and 0.75 every 2.4 s (popover.rs `skeleton_bar`).
fn skeleton(c: *ui.Context) void {
    const phase = @sin(@as(f32, @floatCast(c.time)) * std.math.tau / 2.4) * 0.5 + 0.5;
    c.frameIn(1.0 / 30.0);
    _ = c.leaf(.{ .width = .{ .px = 56 }, .height = .{ .px = 11 }, .radius = 5.5, .background = .{ .r = 1, .g = 1, .b = 1, .a = 0.08 * (0.35 + 0.4 * phase) } }, .none, null);
}

/// Send (or queue, while a run goes); Stop with nothing typed mid-run.
fn send(c: *ui.Context, a: *App, k: theme.Colors) void {
    const empty = std.mem.trim(u8, a.composer.text(), " \n\t").len == 0;
    const running = a.selectedStatus() == .working;
    const stop = running and empty;
    // Dimmed only when it can't send at all; an empty box just does nothing.
    const blocked = !stop and a.engine.state != .connected;
    const pad = ui.div(c).row().pl(8);
    defer pad.end();
    var b = ui.div(c).row().size(28, 28).center().roundedFull().bg(k.text);
    b = b.opacity(if (blocked) 0.35 else if (b.hovered()) 0.85 else 1);
    defer b.end();
    if (b.clicked() and !blocked and (stop or !empty)) {
        if (stop) a.interrupt() else a.send();
    }
    if (stop) {
        _ = c.leaf(.{ .width = .{ .px = 11 }, .height = .{ .px = 11 }, .radius = 3, .background = k.shell }, .none, null);
    } else {
        icons.icon(c, .@"arrow-up", 14, k.background, 0);
    }
}
