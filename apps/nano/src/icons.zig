//! Harness's icons (crates/ui/assets/icons: Solar Linear, CC BY 4.0, and the
//! agents' marks), rendered once to 64-pixel PNGs in src/icons and tinted
//! as they're drawn, as the GPUI app tints its SVGs with the text colour.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

pub const Name = enum {
    @"action-build",
    @"action-configure",
    @"action-debug",
    @"action-lint",
    @"action-play",
    @"action-test",
    @"alt-arrow-down",
    @"alt-arrow-left",
    @"alt-arrow-right",
    @"antigravity-mark",
    @"archive-minimalistic",
    @"archive-up-minimalistic",
    @"arrow-left",
    @"arrow-right",
    @"arrow-up",
    @"arrow-up-right",
    bell,
    bot,
    calendar,
    @"chat-round-line",
    check,
    checklist,
    @"claude-mark",
    @"clock-circle",
    close,
    copy,
    @"cursor-mark",
    @"danger-triangle",
    @"devin-mark",
    document,
    @"exo-mark",
    eye,
    @"eye-closed",
    @"fast-tier",
    @"file-code",
    @"file-image",
    @"file-tree",
    @"fold-vertical",
    folder,
    @"folder-with-files",
    @"git-branch",
    global,
    globe,
    @"graff-mark",
    @"grok-mark",
    @"hermes-mark",
    @"key-minimalistic",
    keyboard,
    laptop,
    list,
    @"logout-2",
    @"magic-stick-3",
    magnifer,
    microphone,
    monitor,
    moon,
    @"more-horizontal",
    @"openai-mark",
    @"opencode-mark",
    @"palette-search",
    paperclip,
    pen,
    @"pi-mark",
    pin,
    plus,
    @"project-default",
    @"pull-request",
    @"queue-drag-handle",
    refresh,
    @"remote-server",
    restart,
    @"settings-minimalistic",
    @"sidebar-minimalistic",
    @"sidebar-minimalistic-left",
    smartphone,
    @"sort-vertical",
    @"split-columns",
    sun,
    terminal,
    @"trash-bin-minimalistic",
    tuning,
    @"volume-loud",
    widget,
    @"wifi-off",
    @"wrap-text",
};

const png_px = 64;

const bytes: std.EnumArray(Name, []const u8) = blk: {
    var a: std.EnumArray(Name, []const u8) = .initUndefined();
    for (std.enums.values(Name)) |n| a.set(n, @embedFile("icons/" ++ @tagName(n) ++ ".png"));
    break :blk a;
};

/// `name` at `size` points, tinted `color`, centred in a `frame` box (its
/// size when 0).
pub fn icon(c: *ui.Context, name: Name, size: f32, color: ui.Color, frame: f32) void {
    const f = if (frame > 0) frame else size;
    const box = ui.div(c).row().size(f, f).center();
    defer box.end();
    _ = ui.image(c, .{
        .key = @tagName(name),
        .bytes = bytes.get(name),
        .max_width = size,
        .max_height = size,
        .radius = 0,
        .scale = png_px / size,
        .tint = color,
    });
}

/// An agent's mark and the colour it keeps (Claude's, also the mock
/// agent's), else null: tinted like the text around it
/// (`harness_brand_icon`, crates/ui/src/pickers.rs).
pub fn harnessMark(harness: []const u8) struct { name: Name, brand: ?ui.Color } {
    const eq = std.mem.eql;
    if (eq(u8, harness, "claude-code") or eq(u8, harness, "mock")) return .{ .name = .@"claude-mark", .brand = .hex(0xd97757) };
    const name: Name = if (eq(u8, harness, "codex"))
        .@"openai-mark"
    else if (eq(u8, harness, "cursor"))
        .@"cursor-mark"
    else if (eq(u8, harness, "devin"))
        .@"devin-mark"
    else if (eq(u8, harness, "grok"))
        .@"grok-mark"
    else if (eq(u8, harness, "hermes"))
        .@"hermes-mark"
    else if (eq(u8, harness, "pi"))
        .@"pi-mark"
    else if (eq(u8, harness, "opencode"))
        .@"opencode-mark"
    else if (eq(u8, harness, "antigravity"))
        .@"antigravity-mark"
    else if (eq(u8, harness, "exo"))
        .@"exo-mark"
    else
        .@"graff-mark";
    return .{ .name = name, .brand = null };
}

test "every agent has a mark; Claude's and the mock's keep Claude's colour" {
    try std.testing.expectEqual(Name.@"claude-mark", harnessMark("mock").name);
    try std.testing.expect(harnessMark("claude-code").brand != null);
    try std.testing.expectEqual(Name.@"openai-mark", harnessMark("codex").name);
    try std.testing.expect(harnessMark("codex").brand == null);
    try std.testing.expectEqual(Name.@"graff-mark", harnessMark("graff").name);
}
