//! The window's open chats, listed at the top of the sidebar
//! (crates/ui/src/shell/chat_tabs.rs). Choosing a session shows it in the
//! current tab, or switches to the tab already showing it; "+" opens a new
//! chat in a tab of its own; back and forward step through the tabs.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Tabs = struct {
    gpa: Allocator,
    /// Each tab's chat (owned); null is a new chat not yet sent.
    items: std.ArrayList(?[]u8) = .empty,
    active: usize = 0,

    pub fn init(gpa: Allocator) Tabs {
        var t: Tabs = .{ .gpa = gpa };
        t.items.append(gpa, null) catch {};
        return t;
    }

    pub fn deinit(t: *Tabs) void {
        for (t.items.items) |c| if (c) |id| t.gpa.free(id);
        t.items.deinit(t.gpa);
    }

    pub fn current(t: *const Tabs) ?[]const u8 {
        if (t.items.items.len == 0) return null;
        return t.items.items[t.active];
    }

    /// Shows `id`: the tab showing it, else in the current tab.
    pub fn show(t: *Tabs, id: []const u8) void {
        for (t.items.items, 0..) |c, i| if (c) |have| if (std.mem.eql(u8, have, id)) {
            t.active = i;
            return;
        };
        t.setCurrent(id);
    }

    /// The current tab now shows `id` (a new chat was just sent).
    pub fn setCurrent(t: *Tabs, id: ?[]const u8) void {
        const copy = if (id) |c| t.gpa.dupe(u8, c) catch return else null;
        if (t.items.items.len == 0) {
            t.items.append(t.gpa, copy) catch {};
            t.active = 0;
            return;
        }
        if (t.items.items[t.active]) |old| t.gpa.free(old);
        t.items.items[t.active] = copy;
    }

    /// A new chat in a tab of its own, after the current one.
    pub fn newTab(t: *Tabs) void {
        const at = @min(t.active + 1, t.items.items.len);
        t.items.insert(t.gpa, at, null) catch return;
        t.active = at;
    }

    /// Closes tab `i`; the last tab left becomes a new chat instead.
    pub fn close(t: *Tabs, i: usize) void {
        if (i >= t.items.items.len) return;
        if (t.items.items.len == 1) return t.setCurrent(null);
        if (t.items.orderedRemove(i)) |id| t.gpa.free(id);
        if (t.active > i or t.active == t.items.items.len) t.active -|= 1;
    }

    pub fn canStep(t: *const Tabs, by: i32) bool {
        const to = @as(i64, @intCast(t.active)) + by;
        return to >= 0 and to < t.items.items.len;
    }

    pub fn step(t: *Tabs, by: i32) void {
        if (!t.canStep(by)) return;
        t.active = @intCast(@as(i64, @intCast(t.active)) + by);
    }

    /// A chat went away (deleted, or archived elsewhere): its tabs close.
    pub fn forget(t: *Tabs, id: []const u8) void {
        var i = t.items.items.len;
        while (i > 0) {
            i -= 1;
            if (t.items.items[i]) |have| if (std.mem.eql(u8, have, id)) t.close(i);
        }
    }
};

const testing = std.testing;

test "show switches to an open tab, else replaces the current one" {
    var t: Tabs = .init(testing.allocator);
    defer t.deinit();
    t.show("a");
    try testing.expectEqualStrings("a", t.current().?);
    t.newTab();
    try testing.expect(t.current() == null);
    t.show("b");
    try testing.expectEqual(@as(usize, 2), t.items.items.len);
    t.show("a");
    try testing.expectEqual(@as(usize, 0), t.active);
    try testing.expect(!t.canStep(-1));
    t.step(1);
    try testing.expectEqualStrings("b", t.current().?);
}

test "closing keeps a tab, and the active one stays in range" {
    var t: Tabs = .init(testing.allocator);
    defer t.deinit();
    t.show("a");
    t.newTab();
    t.show("b");
    t.close(1);
    try testing.expectEqualStrings("a", t.current().?);
    t.close(0);
    try testing.expectEqual(@as(usize, 1), t.items.items.len);
    try testing.expect(t.current() == null);
    t.show("c");
    t.forget("c");
    try testing.expect(t.current() == null);
}
