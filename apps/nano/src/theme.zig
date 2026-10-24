//! Harness's default palettes, Codegraff Light and Codegraff Dark
//! (crates/theme/src/builtins.rs): warm cream or charcoal, amber for what
//! is chosen; Geist for words, JetBrains Mono for code.
const nanoui = @import("nanoui");
const Color = nanoui.ui.Color;

pub const Colors = struct {
    background: Color,
    /// The sidebar and the composer's frame.
    shell: Color,
    raised: Color,
    card: Color,
    text: Color,
    muted: Color,
    faint: Color,
    accent: Color,
    on_accent: Color,
    danger: Color,
    warning: Color,
    success: Color,
    border: Color,
    hover: Color,
    /// The selected chat in the sidebar.
    selected: Color,
    /// Markdown: code panels and their headers, inline code, a quote's
    /// bar, a table's every other row, and code's colors.
    code_bg: Color,
    code_header: Color,
    code_inline_bg: Color,
    quote: Color,
    zebra: Color,
    syntax: [6]Color,
};

const white: Color = .{ .r = 1, .g = 1, .b = 1 };
const black: Color = .{};

pub fn colors(dark: bool) Colors {
    if (dark) {
        const bg = Color.hex(0x16140f);
        const accent = Color.hex(0xe8a33d);
        return .{
            .background = bg,
            .shell = .hex(0x1f1c16),
            .raised = .hex(0x2a261e),
            .card = .hex(0x1f1c16),
            .text = .hex(0xedeae2),
            .muted = .hex(0x9a9384),
            .faint = .hex(0x5c564b),
            .accent = accent,
            .on_accent = bg,
            .danger = .hex(0xd2674f),
            .warning = .hex(0xd9a441),
            .success = .hex(0x7fa86b),
            .border = bg.mix(white, 0.10),
            .hover = white.alpha(0.05),
            .selected = bg.mix(accent, 0.22),
            .code_bg = bg.mix(black, 0.28),
            .code_header = .hex(0x1f1c16),
            .code_inline_bg = .hex(0x2a261e),
            .quote = .hex(0xbd80e4),
            .zebra = bg.mix(white, 0.07),
            .syntax = .{ .hex(0x5c564b), .hex(0xe8a33d), .hex(0x7fa86b), .hex(0xd9a441), .hex(0xedeae2), .hex(0xe8a33d) },
        };
    }
    const bg = Color.hex(0xfaf8f3);
    const accent = Color.hex(0xc77d20);
    return .{
        .background = bg,
        .shell = .hex(0xf0ece3),
        .raised = .hex(0xe7e1d5),
        .card = .hex(0xf0ece3),
        .text = .hex(0x1a1813),
        .muted = .hex(0x6b6557),
        .faint = .hex(0xa8a090),
        .accent = accent,
        .on_accent = bg,
        .danger = .hex(0xb14228),
        .warning = .hex(0x9a6e1b),
        .success = .hex(0x5c7e47),
        .border = bg.mix(black, 0.10),
        .hover = black.alpha(0.04),
        .selected = bg.mix(accent, 0.12),
        .code_bg = .hex(0xf0ece3),
        .code_header = .hex(0xe7e1d5),
        .code_inline_bg = .hex(0xe7e1d5),
        .quote = .hex(0x7a4ea3),
        .zebra = bg.mix(black, 0.05),
        .syntax = .{ .hex(0xa8a090), .hex(0xc77d20), .hex(0x5c7e47), .hex(0x9a6e1b), .hex(0x1a1813), .hex(0xc77d20) },
    };
}

pub fn ui(dark: bool) nanoui.ui.Theme {
    const k = colors(dark);
    var t = if (dark) nanoui.ui.Theme.dark_theme else nanoui.ui.Theme.light;
    t.background = k.background;
    t.surface = k.card;
    t.surface_hover = k.raised;
    t.text = k.text;
    t.muted = k.muted;
    t.border = k.border;
    t.accent = k.accent;
    t.accent_hover = k.accent.mix(if (dark) white else black, 0.14);
    t.accent_text = k.on_accent;
    t.track = k.raised;
    t.danger = k.danger;
    t.success = k.success;
    t.font = "Geist";
    t.mono_font = "JetBrains Mono";
    return t;
}
