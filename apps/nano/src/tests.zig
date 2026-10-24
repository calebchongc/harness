//! Every test: `zig build test`.
test {
    _ = @import("ws.zig");
    _ = @import("rpc.zig");
    _ = @import("workspace.zig");
    _ = @import("transcript.zig");
    _ = @import("engine.zig");
    _ = @import("app.zig");
    _ = @import("rules.zig");
    _ = @import("tools.zig");
    _ = @import("icons.zig");
    _ = @import("release.zig");
    _ = @import("view.zig");
    _ = @import("markdown.zig");
    _ = @import("markdown_html.zig");
    _ = @import("highlight.zig");
}
