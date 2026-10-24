//! Harness's default palettes, Codegraff Dark and Codegraff Light, as the
//! GPUI app derives its roles from them (crates/theme/src/builtins.rs,
//! crates/ui/src/theme.rs): both are opaque, so the window and the main
//! column are painted in `shell`; the sidebar lays a wash over it. Geist for
//! words, Geist Mono for code.
const nanoui = @import("nanoui");
const Color = nanoui.ui.Color;

pub const Colors = struct {
    dark: bool,
    background: Color,
    /// The window and the main column.
    shell: Color,
    /// The sidebar: shell under wash(0.05).
    sidebar: Color,
    raised: Color,
    text: Color,
    muted: Color,
    faint: Color,
    /// A session row's time and the header's "project @ device".
    subline: Color,
    accent: Color,
    /// Accent behind inline code and selections.
    accent_wash: Color,
    /// The snake spinner's three rows: accent lighter, accent, deeper.
    glyph: [3]Color,
    danger: Color,
    danger_muted: Color,
    warning: Color,
    success: Color,
    border: Color,
    border_strong: Color,
    /// element_hover: a control under the pointer.
    hover: Color,
    /// The selected session row: wash(.11) dark, wash(.06) light.
    selected: Color,
    user_bubble: Color,
    /// The composer's fill: `input` flattened on the background.
    composer: Color,
    /// Code panels.
    code_bg: Color,
    code_header: Color,
    /// white (dark) or black (light): a project badge's tone.
    tone: Color,
    syntax: [6]Color,

    /// White at `a` in dark, black at `a` in light.
    pub fn ink(k: Colors, a: f32) Color {
        return (if (k.dark) white else black).alpha(a);
    }

    /// The near-white (dark) or near-black (light) wash at `a`.
    pub fn wash(k: Colors, a: f32) Color {
        return (if (k.dark) Color.hex(0xebebeb) else Color.hex(0x1a1a1a)).alpha(a);
    }
};

const white: Color = .{ .r = 1, .g = 1, .b = 1 };
const black: Color = .{};

pub fn colors(dark: bool) Colors {
    if (dark) {
        const accent = Color.hex(0xe8a33d);
        const muted = Color.hex(0x9a9384);
        return .{
            .dark = true,
            .background = .hex(0x16140f),
            .shell = .hex(0x1f1c16),
            .sidebar = .hex(0x292721),
            .raised = .hex(0x2a261e),
            .text = .hex(0xedeae2),
            .muted = muted,
            .faint = .hex(0x5c564b),
            .subline = .hex(0x5d584d),
            .accent = accent,
            .accent_wash = accent.alpha(0.22),
            .glyph = .{ .hex(0xeebd73), accent, .hex(0xbe8632) },
            .danger = .hex(0xd2674f),
            .danger_muted = .hex(0xda8c78),
            .warning = .hex(0xd9a441),
            .success = .hex(0x7fa86b),
            .border = white.alpha(0.10),
            .border_strong = white.alpha(0.18),
            .hover = white.alpha(0.11),
            .selected = Color.hex(0xebebeb).alpha(0.11),
            .user_bubble = .hex(0x2f2c27),
            .composer = .hex(0x24211a),
            .code_bg = white.alpha(0.035),
            .code_header = white.alpha(0.02),
            .tone = white,
            .syntax = .{ .hex(0x5c564b), .hex(0xe8a33d), .hex(0x7fa86b), .hex(0xd9a441), .hex(0xedeae2), .hex(0xe8a33d) },
        };
    }
    const accent = Color.hex(0xc77d20);
    return .{
        .dark = false,
        .background = .hex(0xfaf8f3),
        .shell = .hex(0xf0ece3),
        .sidebar = .hex(0xe5e1d9),
        .raised = .hex(0xe7e1d5),
        .text = .hex(0x1a1813),
        .muted = .hex(0x6b6557),
        .faint = .hex(0xa8a090),
        .subline = .hex(0xada89d),
        .accent = accent,
        .accent_wash = accent.alpha(0.12),
        .glyph = .{ .hex(0xd09346), accent, .hex(0x935c18) },
        .danger = .hex(0xb14228),
        .danger_muted = .hex(0x873622),
        .warning = .hex(0x9a6e1b),
        .success = .hex(0x5c7e47),
        .border = black.alpha(0.12),
        .border_strong = black.alpha(0.22),
        .hover = black.alpha(0.06),
        .selected = Color.hex(0x1a1a1a).alpha(0.06),
        .user_bubble = .hex(0xe8e4db),
        .composer = .hex(0xf0ece3),
        .code_bg = black.alpha(0.035),
        .code_header = black.alpha(0.02),
        .tone = black,
        .syntax = .{ .hex(0xa8a090), .hex(0xc77d20), .hex(0x5c7e47), .hex(0x9a6e1b), .hex(0x1a1813), .hex(0xc77d20) },
    };
}

pub fn ui(dark: bool) nanoui.ui.Theme {
    const k = colors(dark);
    var t = if (dark) nanoui.ui.Theme.dark_theme else nanoui.ui.Theme.light;
    t.background = k.shell;
    t.surface = k.composer;
    t.surface_hover = k.hover;
    t.text = k.text;
    t.muted = k.muted;
    t.border = k.border;
    t.accent = k.accent;
    t.accent_hover = k.accent.mix(if (dark) white else black, 0.14);
    t.accent_text = black;
    t.track = k.raised;
    t.danger = k.danger;
    t.success = k.success;
    t.font = "Geist";
    t.mono_font = "Geist Mono";
    return t;
}
