//! Native regression probes use synthetic Markdown and the real layout/selection registry.
use super::*;
use crate::markdown::{
    parser::{BlockTree, parse_full},
    selection,
};
use gpui::{Context, Render, TestAppContext, Window, point, size};

struct FlowHarness {
    tree: BlockTree,
}
impl Render for FlowHarness {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        div()
            .size_full()
            .flex()
            .flex_col()
            .child(render::selection_frame_reset())
            .child(render::render_tree(
                &self.tree,
                &RenderOptions::settled("flow-test".into()),
                &theme,
                window,
                &|_| None,
            ))
    }
}

fn entries(
    cx: &mut TestAppContext,
    source: &str,
    width: f32,
) -> Vec<(String, String, gpui::Bounds<gpui::Pixels>)> {
    cx.update(|cx| cx.set_global(Theme::dark()));
    let tree = parse_full(source);
    let (_, cx) = cx.add_window_view(|_, _| FlowHarness { tree });
    cx.simulate_resize(size(px(width), px(600.)));
    cx.update(|window, cx| {
        window.refresh();
        let _ = window.draw(cx);
    });
    render::selection_test_entries()
}

#[gpui::test]
fn native_math_flow_long_inline_equation_stays_inside_pane(cx: &mut TestAppContext) {
    let _guard = selection::test_state_lock();
    let source = format!("Before ${}x$ after.", "x+".repeat(30));
    let entries = entries(cx, &source, 180.);
    let equation = entries
        .iter()
        .find(|(_, text, _)| text.starts_with('$'))
        .expect("equation");
    assert!(
        equation.2.right() <= px(180.),
        "equation selection/hit target escaped its pane: {:?}",
        equation.2
    );
    let after = entries
        .iter()
        .find(|(_, text, _)| text == "after.")
        .expect("following prose");
    assert!(
        after.2.right() <= px(180.),
        "following prose must remain visible"
    );
}

#[gpui::test]
fn native_math_flow_scrolled_equation_still_selects_atomic_source(cx: &mut TestAppContext) {
    let _guard = selection::test_state_lock();
    cx.update(|cx| cx.set_global(Theme::dark()));
    for display in [false, true] {
        let delimiter = if display { "$$" } else { "$" };
        let latex = format!("{delimiter}{}z{delimiter}", "x+".repeat(30));
        let copied = if display {
            format!("\n{latex}\n")
        } else {
            latex.clone()
        };
        let tree = parse_full(&format!("Before {latex} after."));
        let (_, cx) = cx.add_window_view(|_, _| FlowHarness { tree });
        cx.simulate_resize(size(px(180.), px(240.)));
        cx.update(|window, cx| {
            window.refresh();
            let _ = window.draw(cx);
        });
        let entries = render::selection_test_entries();
        let equation = entries.iter().find(|(_, text, _)| text == &copied).unwrap();
        let key = equation.0.clone();
        let original = cx.debug_bounds("math-flow-equation").unwrap();
        cx.simulate_event(gpui::MouseMoveEvent {
            position: equation.2.center(),
            ..Default::default()
        });
        cx.simulate_event(gpui::ScrollWheelEvent {
            position: equation.2.center(),
            delta: gpui::ScrollDelta::Pixels(point(px(-10000.), px(0.))),
            ..Default::default()
        });
        cx.update(|window, cx| {
            window.refresh();
            let _ = window.draw(cx);
        });
        let scrolled = cx.debug_bounds("math-flow-equation").unwrap();
        assert!(
            scrolled.left() < original.left() - px(100.),
            "the probe must actually scroll"
        );
        let entries = render::selection_test_entries();
        let equation = entries
            .iter()
            .find(|(candidate, _, _)| candidate == &key)
            .unwrap();
        assert!(equation.2.left() >= px(0.) && equation.2.right() <= px(180.));
        cx.simulate_event(gpui::MouseDownEvent {
            button: gpui::MouseButton::Left,
            position: equation.2.center(),
            click_count: 2,
            ..Default::default()
        });
        assert_eq!(selection::selected_text().as_deref(), Some(copied.as_str()));
        selection::end_active_drag();
        selection::clear_if_owner(&key);
    }
}

#[gpui::test]
fn native_math_flow_reverse_drag_preserves_unicode_and_hard_break_copy(cx: &mut TestAppContext) {
    let _guard = selection::test_state_lock();
    cx.update(|cx| cx.set_global(Theme::dark()));
    let tree = parse_full("前置 $x_i$ café.  \n終了 $y^2$ tail.");
    let (_, cx) = cx.add_window_view(|_, _| FlowHarness { tree });
    cx.simulate_resize(size(px(200.), px(240.)));
    cx.update(|window, cx| {
        window.refresh();
        let _ = window.draw(cx);
    });
    let entries = render::selection_test_entries();
    let first = entries.iter().find(|(_, text, _)| text == "前置 ").unwrap();
    let last = entries.iter().find(|(_, text, _)| text == "tail.").unwrap();
    // The transcript's right-gutter path anchors after the last glyph. A
    // click inside the final glyph correctly anchors before that character.
    assert!(render::begin_drag_in_whitespace(
        0,
        point(last.2.right() + px(1.), last.2.center().y)
    ));
    cx.simulate_event(gpui::MouseMoveEvent {
        position: point(first.2.left(), first.2.center().y),
        pressed_button: Some(gpui::MouseButton::Left),
        ..Default::default()
    });
    assert_eq!(
        selection::selected_text().as_deref(),
        Some("前置 $x_i$ café.\n終了 $y^2$ tail.")
    );
    selection::end_active_drag();
    selection::clear_if_owner(&last.0);
}

#[gpui::test]
fn native_math_flow_tiny_viewports_keep_visible_hit_bounds_clipped(cx: &mut TestAppContext) {
    let _guard = selection::test_state_lock();
    for width in [1., 12., 24.] {
        let entries = entries(cx, "Prose $\\frac{1}{x}$ tail.", width);
        assert!(
            entries
                .iter()
                .any(|(_, text, bounds)| text.starts_with('$') && bounds.size.width > px(0.))
        );
        for (_, text, bounds) in entries {
            if bounds.size.width > px(0.) && bounds.size.height > px(0.) {
                assert!(
                    bounds.left() >= px(0.) && bounds.right() <= px(width),
                    "{text}: {bounds:?}"
                );
            }
        }
    }
}

#[gpui::test]
fn native_math_flow_right_aligned_table_keeps_alignment(cx: &mut TestAppContext) {
    let _guard = selection::test_state_lock();
    let entries = entries(cx, "| Formula |\n|---:|\n| $x^2$ |", 320.);
    let equation = entries
        .iter()
        .find(|(_, text, _)| text == "$x^2$")
        .expect("equation");
    assert!(
        equation.2.left() > px(200.),
        "right aligned math must not become left aligned: {:?}",
        equation.2
    );
}

#[gpui::test]
fn native_math_flow_hard_break_moves_to_next_line(cx: &mut TestAppContext) {
    let _guard = selection::test_state_lock();
    let entries = entries(cx, "First $x$ end.  \nNext $y$ tail.", 400.);
    let first = entries
        .iter()
        .find(|(_, text, _)| text == "First ")
        .unwrap();
    let next = entries.iter().find(|(_, text, _)| text == "Next ").unwrap();
    assert!(
        next.2.top() >= first.2.bottom(),
        "hard break must create another visual row"
    );
}

#[gpui::test]
fn native_math_flow_drag_copies_prose_and_atomic_latex(cx: &mut TestAppContext) {
    let _guard = selection::test_state_lock();
    cx.update(|cx| cx.set_global(Theme::dark()));
    let tree = parse_full(r"Before $\frac{1}{n}$ after.");
    let (_, cx) = cx.add_window_view(|_, _| FlowHarness { tree });
    cx.simulate_resize(size(px(400.), px(200.)));
    cx.update(|window, cx| {
        window.refresh();
        let _ = window.draw(cx);
    });
    let entries = render::selection_test_entries();
    let first = entries
        .iter()
        .find(|(_, text, _)| text == "Before ")
        .unwrap();
    let last = entries
        .iter()
        .find(|(_, text, _)| text == "after.")
        .unwrap();
    cx.simulate_event(gpui::MouseDownEvent {
        button: gpui::MouseButton::Left,
        position: first.2.origin + point(px(0.1), px(8.)),
        click_count: 1,
        ..Default::default()
    });
    cx.simulate_event(gpui::MouseMoveEvent {
        position: point(last.2.right(), last.2.center().y),
        pressed_button: Some(gpui::MouseButton::Left),
        ..Default::default()
    });
    assert_eq!(
        selection::selected_text().as_deref(),
        Some(r"Before $\frac{1}{n}$ after.")
    );
    selection::end_active_drag();
    selection::clear_if_owner(&first.0);
}

#[test]
fn inline_math_flow_unsupported_input_preserves_literal_source() {
    let tree = parse_full(r"Before $\def\x{bad}\x$ after.");
    let crate::markdown::Block::Paragraph { runs } = &tree.blocks[0].block else {
        panic!()
    };
    let words = fragments(runs, 14., &Theme::dark());
    let formula = words.iter().flatten().find(|f| f.copy.is_some()).unwrap();
    assert!(
        formula.equation.is_none(),
        "unsupported commands must not silently render different math"
    );
    assert_eq!(formula.runs[0].text, r"$\def\x{bad}\x$");
}

#[test]
fn inline_math_flow_lossy_upstream_forms_keep_literal_source_and_bold_style() {
    for source in [
        r"\binom{n}{k}",
        r"\genfrac{}{}{0pt}{}{n}{k}",
        r"\dfrac{a}{b}",
        r"\tfrac{a}{b}",
        r"a\hspace{0em}+b",
        r"a\,=b",
        r"a=\!b",
        r"x^{a\quad+b}",
    ] {
        let tree = parse_full(&format!("**${source}$**"));
        let crate::markdown::Block::Paragraph { runs } = &tree.blocks[0].block else {
            panic!()
        };
        let words = fragments(runs, 14., &Theme::dark());
        let formula = words
            .iter()
            .flatten()
            .find(|fragment| fragment.copy.is_some())
            .unwrap();
        assert!(
            formula.equation.is_none(),
            "lossy equation must remain literal: {source}"
        );
        assert_eq!(
            formula.copy.as_deref(),
            Some(format!("${source}$").as_str())
        );
        assert_eq!(formula.runs[0].text, format!("${source}$"));
        assert!(formula.runs[0].style.bold);
    }
}

#[gpui::test]
fn native_math_flow_linked_equation_retains_link_interaction(cx: &mut TestAppContext) {
    let _guard = selection::test_state_lock();
    use std::{cell::Cell, rc::Rc};
    fn linked_tree() -> BlockTree {
        // Link labels are deliberately literal in the Markdown preprocessor;
        // exercise the renderer's public AST composition without weakening that
        // URL/code protection rule.
        let mut tree = parse_full("$x^2$");
        let crate::markdown::Block::Paragraph { runs } =
            &mut std::sync::Arc::make_mut(&mut tree.blocks[0]).block
        else {
            panic!()
        };
        runs[0].style.link = Some("https://example.com/equation".into());
        tree
    }
    struct LinkedFlowHarness {
        clicks: Rc<Cell<usize>>,
    }
    impl Render for LinkedFlowHarness {
        fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            let theme = Theme::of(cx).clone();
            let mut opts = RenderOptions::settled("linked-flow-test".into());
            let clicks = self.clicks.clone();
            opts.link = Some(render::LinkUi {
                source_session: None,
                handler: Rc::new(move |activation, _, _| {
                    assert_eq!(activation.target.original, "https://example.com/equation");
                    clicks.set(clicks.get() + 1);
                    render::LinkOutcome::Internal
                }),
            });
            div()
                .size_full()
                .child(render::selection_frame_reset())
                .child(render::render_tree(
                    &linked_tree(),
                    &opts,
                    &theme,
                    window,
                    &|_| None,
                ))
        }
    }
    let parsed = linked_tree();
    let crate::markdown::Block::Paragraph { runs } = &parsed.blocks[0].block else {
        panic!("{parsed:?}")
    };
    assert!(
        runs.iter()
            .any(|run| run.style.math.is_some() && run.style.link.is_some()),
        "linked math metadata: {parsed:?}"
    );
    let clicks = Rc::new(Cell::new(0));
    cx.update(|cx| cx.set_global(Theme::dark()));
    let (_, cx) = cx.add_window_view(|_, _| LinkedFlowHarness {
        clicks: clicks.clone(),
    });
    cx.simulate_resize(size(px(320.), px(160.)));
    cx.update(|window, cx| {
        window.refresh();
        let _ = window.draw(cx);
    });
    let entries = render::selection_test_entries();
    let equation = entries
        .iter()
        .find(|(_, text, _)| text == "$x^2$")
        .expect("linked equation");
    let point = equation.2.center();
    cx.simulate_event(gpui::MouseMoveEvent {
        position: point,
        ..Default::default()
    });
    cx.simulate_event(gpui::MouseDownEvent {
        button: gpui::MouseButton::Left,
        position: point,
        click_count: 1,
        ..Default::default()
    });
    cx.simulate_event(gpui::MouseUpEvent {
        button: gpui::MouseButton::Left,
        position: point,
        click_count: 1,
        ..Default::default()
    });
    assert_eq!(
        clicks.get(),
        1,
        "typesetting must not remove a Markdown link"
    );
    selection::end_active_drag();
    selection::clear_if_owner(&equation.0);
}

#[gpui::test]
fn native_math_flow_double_click_keeps_styled_unicode_words_whole(cx: &mut TestAppContext) {
    let _guard = selection::test_state_lock();
    for (source, expected, targets) in [
        ("**na**ïve $x$", "naïve", ["na", "ïve "]),
        ("$x$ co**ordi**nate", "coordinate", ["co", "ordi"]),
    ] {
        for target in targets {
            cx.update(|cx| cx.set_global(Theme::dark()));
            let tree = parse_full(source);
            let (_, cx) = cx.add_window_view(|_, _| FlowHarness { tree });
            cx.simulate_resize(size(px(320.), px(200.)));
            cx.update(|window, cx| {
                window.refresh();
                let _ = window.draw(cx);
            });
            let entries = render::selection_test_entries();
            let clicked = entries.iter().find(|(_, text, _)| text == target).unwrap();
            cx.simulate_event(gpui::MouseDownEvent {
                button: gpui::MouseButton::Left,
                position: clicked.2.center(),
                click_count: 2,
                ..Default::default()
            });
            assert_eq!(
                selection::selected_text().as_deref(),
                Some(expected),
                "{source}, target={target}"
            );
            selection::end_active_drag();
            selection::clear_if_owner(&clicked.0);
        }
    }
}

#[gpui::test]
fn native_math_flow_triple_click_selects_the_logical_paragraph(cx: &mut TestAppContext) {
    let _guard = selection::test_state_lock();
    for width in [160., 400.] {
        for target in ["Before ", "$x_i$", "after."] {
            cx.update(|cx| cx.set_global(Theme::dark()));
            let tree = parse_full("Previous paragraph.\n\nBefore $x_i$ after.\n\nNext paragraph.");
            let (_, cx) = cx.add_window_view(|_, _| FlowHarness { tree });
            cx.simulate_resize(size(px(width), px(400.)));
            cx.update(|window, cx| {
                window.refresh();
                let _ = window.draw(cx);
            });
            let entries = render::selection_test_entries();
            let clicked = entries.iter().find(|(_, text, _)| text == target).unwrap();
            cx.simulate_event(gpui::MouseDownEvent {
                button: gpui::MouseButton::Left,
                position: clicked.2.center(),
                click_count: 3,
                ..Default::default()
            });
            assert_eq!(
                selection::selected_text().as_deref(),
                Some("Before $x_i$ after."),
                "width={width}, target={target}: triple-click must not select only one flow fragment"
            );
            cx.simulate_event(gpui::MouseMoveEvent {
                position: clicked.2.center(),
                pressed_button: Some(gpui::MouseButton::Left),
                ..Default::default()
            });
            assert_eq!(
                selection::selected_text().as_deref(),
                Some("Before $x_i$ after.")
            );
            selection::end_active_drag();
            selection::clear_if_owner(&clicked.0);
        }
    }
}

#[test]
fn inline_math_flow_bold_style_is_not_discarded() {
    let tree = parse_full("$x_i$ **$x_i$**");
    let crate::markdown::Block::Paragraph { runs } = &tree.blocks[0].block else {
        panic!()
    };
    let words = fragments(runs, 14., &Theme::dark());
    let equations: Vec<_> = words
        .iter()
        .flatten()
        .filter_map(|fragment| fragment.equation.as_ref())
        .collect();
    assert_eq!(equations.len(), 2);
    assert!(
        !std::sync::Arc::ptr_eq(&equations[0].image, &equations[1].image),
        "bold equations must not reuse the unbold layout"
    );
}

#[gpui::test]
fn native_math_flow_long_literal_token_cannot_capture_neighbouring_pane(cx: &mut TestAppContext) {
    let _guard = selection::test_state_lock();
    let token = "A".repeat(90);
    let entries = entries(cx, &format!("Before $x$ {token}"), 180.);
    let literal = entries.iter().find(|(_, text, _)| text == &token).unwrap();
    assert!(
        literal.2.right() <= px(180.),
        "text fragment selection escaped its scroll viewport: {:?}",
        literal.2
    );
}

#[gpui::test]
fn native_math_flow_alignment_and_font_scale_grid(cx: &mut TestAppContext) {
    let _guard = selection::test_state_lock();
    cx.update(|cx| cx.set_global(Theme::dark()));
    for rem in [12.0, 24.0] {
        for width in [120.0, 320.0] {
            for alignment in [":---", ":---:", "---:"] {
                let source = format!(
                    "| Header |\n|{alignment}|\n| $x^2$ |\n\nProse $\\frac{{1}}{{\\sqrt{{x}}}}$ after."
                );
                let tree = parse_full(&source);
                let (_, view) = cx.add_window_view(|_, _| FlowHarness { tree });
                view.simulate_resize(size(px(width), px(400.)));
                view.update(|window, cx| {
                    window.set_rem_size(px(rem));
                    window.refresh();
                    let _ = window.draw(cx);
                });
                let entries = render::selection_test_entries();
                let formula = entries
                    .iter()
                    .find(|(_, text, _)| text == "$x^2$")
                    .unwrap()
                    .2;
                let actual = match alignment {
                    ":---" => formula.left(),
                    ":---:" => formula.center().x,
                    _ => formula.right(),
                };
                let expected = match alignment {
                    ":---" => px(12.),
                    ":---:" => px(width / 2.),
                    _ => px(width - 12.),
                };
                assert!(
                    f32::from(actual - expected).abs() <= 1.,
                    "alignment={alignment}, rem={rem}, width={width}: {formula:?}"
                );
                for (_, text, bounds) in entries {
                    assert!(
                        bounds.left() >= px(0.) && bounds.right() <= px(width + 1.),
                        "{text:?} escaped viewport at rem={rem}, width={width}: {bounds:?}"
                    );
                }
            }
        }
    }
}

#[gpui::test]
fn native_math_flow_nonbreaking_spaces_keep_words_together(cx: &mut TestAppContext) {
    let _guard = selection::test_state_lock();
    for glue in ['\u{00a0}', '\u{202f}', '\u{2007}'] {
        let word = format!("long{glue}token ");
        let source = format!("{word}$x$");
        let entries = entries(cx, &source, 45.);
        assert!(
            entries.iter().any(|(_, text, _)| text == &word),
            "nonbreaking whitespace split its word: {entries:?}"
        );
    }
}

#[gpui::test]
fn native_math_flow_strikethrough_is_painted_over_equation(cx: &mut TestAppContext) {
    let _guard = selection::test_state_lock();
    PAINTED_DECORATIONS.with(|rects| rects.borrow_mut().clear());
    let entries = entries(cx, "Plain $x$ and ~~$x^2$~~.", 320.);
    let bounds = entries
        .iter()
        .find(|(_, text, _)| text == "$x^2$")
        .unwrap()
        .2;
    PAINTED_DECORATIONS.with(|rects| {
        let rects = rects.borrow();
        assert_eq!(
            rects.len(),
            1,
            "strikethrough must result in an actual painted line, not just retained AST flags"
        );
        let stroke = *rects.values().next().unwrap();
        assert!(
            stroke.top() > bounds.top() && stroke.bottom() < bounds.bottom(),
            "stroke must cross equation ink"
        );
        assert!(
            stroke.size.width >= bounds.size.width - px(3.),
            "stroke must span equation width"
        );
    });
}

#[gpui::test]
fn native_math_flow_mixed_image_table_preserves_right_alignment(cx: &mut TestAppContext) {
    let _guard = selection::test_state_lock();
    struct MediaHarness;
    impl Render for MediaHarness {
        fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            let theme = Theme::of(cx).clone();
            let mut opts = RenderOptions::settled("media-flow-test".into());
            opts.media = Some(render::MediaUi {
                diagram: None,
                image: std::rc::Rc::new(|_, _, _| div().w(px(18.)).h(px(18.)).into_any_element()),
            });
            div()
                .size_full()
                .child(render::selection_frame_reset())
                .child(render::render_tree(
                    &parse_full("| Formula |\n|---:|\n| $x^2$ ![sample](synthetic.png) $y^2$ |"),
                    &opts,
                    &theme,
                    window,
                    &|_| None,
                ))
        }
    }
    cx.update(|cx| cx.set_global(Theme::dark()));
    let (_, cx) = cx.add_window_view(|_, _| MediaHarness);
    cx.simulate_resize(size(px(320.), px(200.)));
    cx.update(|window, cx| {
        window.refresh();
        let _ = window.draw(cx);
    });
    let entries = render::selection_test_entries();
    for source in ["$x^2$", "$y^2$"] {
        let formula = entries
            .iter()
            .find(|(_, text, _)| text == source)
            .unwrap()
            .2;
        assert!(
            formula.left() > px(200.),
            "an image must not reset either surrounding formula's alignment: {formula:?}"
        );
    }
}

#[test]
fn inline_math_flow_whitespace_copy_grid_preserves_unicode_and_code() {
    for separator in [
        " ", "\t", "\u{00a0}", "\u{202f}", "\u{2007}", "\u{2003}", "\u{2060}",
    ] {
        let source = format!("before{separator}$x_i${separator}`$literal$`{separator}after");
        let tree = parse_full(&source);
        let crate::markdown::Block::Paragraph { runs } = &tree.blocks[0].block else {
            panic!()
        };
        let copied: String = fragments(runs, 14., &Theme::dark())
            .into_iter()
            .flatten()
            .map(|fragment| {
                fragment
                    .copy
                    .unwrap_or_else(|| fragment.runs.iter().map(|run| run.text.as_str()).collect())
            })
            .collect();
        assert_eq!(
            copied,
            format!("before{separator}$x_i${separator}$literal${separator}after"),
            "separator={separator:?}"
        );
    }
}

#[gpui::test]
fn native_math_flow_bold_strike_geometry_covers_tall_equations(cx: &mut TestAppContext) {
    let _guard = selection::test_state_lock();
    for latex in ["x", r"\frac{a}{b}", r"\sum_{i=1}^{n}x_i"] {
        PAINTED_DECORATIONS.with(|rects| rects.borrow_mut().clear());
        let source = format!("Plain $y$ and **~~${latex}$~~**.");
        let entries = entries(cx, &source, 320.);
        let formula = entries
            .iter()
            .find(|(_, text, _)| text == &format!("${latex}$"))
            .unwrap()
            .2;
        PAINTED_DECORATIONS.with(|rects| {
            let rects = rects.borrow();
            assert_eq!(
                rects.len(),
                1,
                "only the struck equation should paint a line"
            );
            let stroke = *rects.values().next().unwrap();
            assert!(
                stroke.top() > formula.top() && stroke.bottom() < formula.bottom(),
                "{latex}: {stroke:?} outside {formula:?}"
            );
            assert!(stroke.size.width >= formula.size.width - px(3.));
        });
    }
}
