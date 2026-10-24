//! Native, bounded presentation of an isolated Luau visual. No browser or network surface.
//!
//! Construct with `cx.new(|cx| VisualView::new(title, script, cx))` and retain the entity
//! for the lifetime of a transcript row. The fixed outer height keeps virtual-list
//! measurements stable while state changes; only the inner document scrolls.
use std::{
    cell::Cell,
    rc::Rc,
    sync::{Arc, Mutex},
};

use gpui::{
    AnyElement, Bounds, Context, FontWeight, KeyDownEvent, MouseButton, Pixels, Render, Window,
    div, prelude::*, px, relative,
};
use harness_visual::{Input, Kind, Node, Visual};

use crate::{theme::Theme, typography::ui_rems};

pub const VISUAL_HEIGHT: f32 = 700.0;
const MAX_DEPTH: usize = 24;
const MAX_NODES: usize = 512;
const CHART_BARS: usize = 12;

type Runtime = Arc<Mutex<Option<Visual>>>;

pub struct VisualView {
    title: String,
    runtime: Runtime,
    node: Option<Node>,
    error: Option<String>,
    busy: bool,
    revision: u64,
}

impl VisualView {
    pub fn new(title: String, script: String, cx: &mut Context<Self>) -> Self {
        #[cfg(feature = "appshots-fixture")]
        cx.set_global(FixtureVisual(cx.weak_entity()));
        let runtime = Arc::new(Mutex::new(None));
        let worker = runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    let mut visual = Visual::new(&script)?;
                    let node = visual.render()?;
                    *worker
                        .lock()
                        .map_err(|_| "Visual worker is unavailable".to_string())? = Some(visual);
                    Ok(node)
                })
                .await;
            let _ = this.update(cx, |view, cx| view.finish(result, cx));
        })
        .detach();
        Self {
            title: plain(&title, 160),
            runtime,
            node: None,
            error: None,
            busy: true,
            revision: 0,
        }
    }

    /// Same dispatch as pointer, keyboard and accessibility controls. Finds a currently
    /// rendered control by its readable label; no handlers or runtime escape the view.
    /// Returns immediately; wait until `is_busy()` is false before observing the result.
    pub fn interact(
        &mut self,
        label: &str,
        input: Input,
        cx: &mut Context<Self>,
    ) -> Result<(), String> {
        if self.busy {
            return Err("Visual is busy".into());
        }
        let node = self
            .node
            .as_ref()
            .and_then(|root| find_control(root, label))
            .ok_or_else(|| "No active visual control has that label".to_string())?;
        let handler = node
            .handler
            .ok_or_else(|| "Visual control is read-only".to_string())?;
        let valid = match (&input, node.kind) {
            (Input::Click, Kind::Button) | (Input::Bool(_), Kind::Toggle) => true,
            (Input::Number(value), Kind::Slider) => {
                value.is_finite() && *value >= node.min && *value <= node.max
            }
            _ => false,
        };
        if !valid {
            return Err("Input does not match the visual control".into());
        }
        self.dispatch(self.revision, handler, input, cx);
        Ok(())
    }

    pub fn is_busy(&self) -> bool {
        self.busy
    }
    pub fn error(&self) -> Option<&str> {
        self.error.as_deref()
    }
    pub fn snapshot(&self) -> Option<&Node> {
        self.node.as_ref()
    }
    pub fn revision(&self) -> u64 {
        self.revision
    }

    fn dispatch(&mut self, revision: u64, handler: u64, input: Input, cx: &mut Context<Self>) {
        // Listeners from the preceding frame may still be queued after a completed call.
        // Reject both those stale callbacks and repeated input while a worker owns Lua.
        if self.busy || revision != self.revision || self.error.is_some() {
            return;
        }
        self.busy = true;
        cx.notify();
        let runtime = self.runtime.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_executor()
                .spawn(async move {
                    let mut slot = runtime
                        .lock()
                        .map_err(|_| "Visual worker is unavailable".to_string())?;
                    slot.as_mut()
                        .ok_or_else(|| "Visual is not ready".to_string())?
                        .call(handler, input)
                })
                .await;
            let _ = this.update(cx, |view, cx| view.finish(result, cx));
        })
        .detach();
    }

    fn finish(&mut self, result: Result<Node, String>, cx: &mut Context<Self>) {
        self.busy = false;
        self.revision = self.revision.saturating_add(1);
        match result {
            Ok(node) => {
                self.node = Some(node);
                self.error = None;
            }
            Err(error) => {
                // Handler tables are invalid after errors. Never leave live-looking stale controls.
                self.node = None;
                self.error = Some(plain(&error, 360));
            }
        }
        cx.notify();
    }

    fn render_node(
        &self,
        node: &Node,
        depth: usize,
        count: &mut usize,
        theme: &Theme,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        *count += 1;
        if depth > MAX_DEPTH || *count > MAX_NODES {
            return div()
                .text_color(theme.danger)
                .child("Visual display limit reached")
                .into_any_element();
        }
        // Positional IDs intentionally survive rerenders, unlike runtime callback IDs.
        let id = *count;
        match node.kind {
            Kind::Column | Kind::Row => {
                let mut container = div().min_w_0().flex().gap(px(14.0));
                if node.kind == Kind::Column {
                    container = container.flex_col().w_full();
                } else {
                    container = container.flex_row().flex_wrap().items_center();
                }
                for child in node.children.iter().take(MAX_NODES) {
                    if *count >= MAX_NODES {
                        break;
                    }
                    container =
                        container.child(self.render_node(child, depth + 1, count, theme, cx));
                }
                container.into_any_element()
            }
            Kind::Text => div()
                .id(("visual-text", id))
                .role(gpui::Role::Label)
                .aria_label(node.text.clone())
                .min_w_0()
                .child(node.text.clone())
                .into_any_element(),
            Kind::Stat => div()
                .id(("visual-stat", id))
                .role(gpui::Role::Label)
                .aria_label(node.text.clone())
                .min_w(px(150.0))
                .flex_1()
                .p(px(16.0))
                .rounded(px(10.0))
                .border_1()
                .border_color(theme.border)
                .bg(theme.bg)
                .font_weight(FontWeight::SEMIBOLD)
                .text_size(ui_rems(20.0))
                .child(node.text.clone())
                .into_any_element(),
            Kind::Rule => div()
                .w_full()
                .h(px(1.0))
                .bg(theme.border)
                .into_any_element(),
            Kind::Chart => self.chart(node, id, theme),
            Kind::Button | Kind::Toggle => self.button(node, id, theme, cx),
            Kind::Slider => self.slider(node, id, theme, cx),
        }
    }

    fn button(&self, node: &Node, id: usize, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let toggle = node.kind == Kind::Toggle;
        let on = node.value != 0.0;
        let active = !self.busy && node.handler.is_some();
        let revision = self.revision;
        let handler = node.handler.unwrap_or(0);
        let label = control_label(node);
        let mut control = div()
            .id(("visual-control", id))
            .min_h(px(38.0))
            .px(px(14.0))
            .py(px(9.0))
            .rounded(px(8.0))
            .border_1()
            .border_color(theme.border_strong)
            .flex()
            .items_center()
            .gap(px(10.0))
            .role(if toggle {
                gpui::Role::Switch
            } else {
                gpui::Role::Button
            })
            .aria_label(label.clone())
            .font_weight(FontWeight::MEDIUM)
            .bg(if toggle {
                theme.bg
            } else {
                theme.accent_strong
            })
            .text_color(if active {
                if toggle { theme.text } else { theme.on_accent }
            } else {
                theme.text_muted
            });
        if toggle {
            control = control
                .aria_toggled(if on {
                    gpui::Toggled::True
                } else {
                    gpui::Toggled::False
                })
                .child(
                    div()
                        .w(px(30.0))
                        .h(px(18.0))
                        .rounded_full()
                        .bg(if on {
                            theme.accent_strong
                        } else {
                            theme.border_strong
                        })
                        .flex()
                        .items_center()
                        .px(px(3.0))
                        .when(on, |el| el.justify_end())
                        .child(div().size(px(12.0)).rounded_full().bg(theme.solid)),
                );
        }
        control = control
            .child(label)
            .when(toggle, |el| el.child(if on { "On" } else { "Off" }));
        if active {
            let a11y_view = cx.weak_entity();
            control = control
                .cursor_pointer()
                .tab_index(0)
                .focus_visible(|s| s.border_color(theme.accent))
                .hover(|s| s.border_color(theme.accent))
                .on_click(cx.listener(move |view, _, _, cx| {
                    cx.stop_propagation();
                    view.dispatch(
                        revision,
                        handler,
                        if toggle {
                            Input::Bool(!on)
                        } else {
                            Input::Click
                        },
                        cx,
                    );
                }))
                .on_key_down(cx.listener(move |view, event: &KeyDownEvent, window, cx| {
                    if matches!(event.keystroke.key.as_str(), "enter" | "space" | " ") {
                        cx.stop_propagation();
                        window.prevent_default();
                        view.dispatch(
                            revision,
                            handler,
                            if toggle {
                                Input::Bool(!on)
                            } else {
                                Input::Click
                            },
                            cx,
                        );
                    }
                }))
                .on_a11y_action(gpui::AccessibleAction::Click, move |_, _, cx| {
                    let _ = a11y_view.update(cx, |view, cx| {
                        view.dispatch(
                            revision,
                            handler,
                            if toggle {
                                Input::Bool(!on)
                            } else {
                                Input::Click
                            },
                            cx,
                        );
                    });
                });
        }
        control.into_any_element()
    }

    fn slider(&self, node: &Node, id: usize, theme: &Theme, cx: &mut Context<Self>) -> AnyElement {
        let min = node.min;
        let max = node.max;
        let value = node.value.clamp(min, max);
        let span = max - min;
        let fraction = if span.is_finite() && span > 0.0 {
            ((value - min) / span) as f32
        } else {
            0.0
        };
        let step = span / 100.0;
        let active = !self.busy && node.handler.is_some() && span.is_finite() && span > 0.0;
        let revision = self.revision;
        let handler = node.handler.unwrap_or(0);
        let bounds: Rc<Cell<Option<Bounds<Pixels>>>> = Rc::new(Cell::new(None));
        let measured = bounds.clone();
        let mut control = div()
            .id(("visual-control", id))
            .role(gpui::Role::Slider)
            .aria_label(control_label(node))
            .aria_numeric_value(value)
            .aria_min_numeric_value(min)
            .aria_max_numeric_value(max)
            .aria_numeric_value_step(step)
            .aria_description("Use arrow keys to adjust; Home and End select the limits.")
            .min_w(px(180.0))
            .w_full()
            .flex()
            .flex_col()
            .gap(px(5.0))
            .rounded(px(8.0))
            .border_1()
            .border_color(theme.border)
            .p(px(12.0))
            .child(
                div()
                    .flex()
                    .justify_between()
                    .gap(px(12.0))
                    .child(control_label(node))
                    .child(number(value)),
            )
            .child(
                div()
                    .relative()
                    .h(px(28.0))
                    .w_full()
                    .child(
                        gpui::canvas(move |rect, _, _| measured.set(Some(rect)), |_, _, _, _| {})
                            .absolute()
                            .size_full(),
                    )
                    .child(
                        div()
                            .absolute()
                            .left_0()
                            .right_0()
                            .top(px(12.0))
                            .h(px(4.0))
                            .rounded_full()
                            .bg(theme.border_strong)
                            .child(
                                div()
                                    .h_full()
                                    .w(relative(fraction))
                                    .rounded_full()
                                    .bg(theme.accent),
                            )
                            .child(
                                div()
                                    .absolute()
                                    .top(px(-5.0))
                                    .left(relative(fraction))
                                    .ml(px(-7.0))
                                    .size(px(14.0))
                                    .rounded_full()
                                    .bg(theme.accent),
                            ),
                    ),
            )
            .child(
                div()
                    .flex()
                    .justify_between()
                    .text_size(ui_rems(11.0))
                    .text_color(theme.text_muted)
                    .child(number(min))
                    .child(number(max)),
            );
        if active {
            let increment_view = cx.weak_entity();
            let decrement_view = increment_view.clone();
            let set_value_view = increment_view.clone();
            control = control
                .tab_index(0)
                .cursor_pointer()
                .focus_visible(|s| s.border_color(theme.accent))
                .on_mouse_down(
                    MouseButton::Left,
                    cx.listener(move |view, event: &gpui::MouseDownEvent, _, cx| {
                        let Some(rect) = bounds.get() else {
                            return;
                        };
                        if !rect.contains(&event.position) || rect.size.width <= px(0.0) {
                            return;
                        }
                        let ratio = ((event.position.x - rect.left()) / rect.size.width)
                            .clamp(0.0, 1.0) as f64;
                        cx.stop_propagation();
                        view.dispatch(
                            revision,
                            handler,
                            Input::Number((min + ratio * span).clamp(min, max)),
                            cx,
                        );
                    }),
                )
                .on_key_down(cx.listener(move |view, event: &KeyDownEvent, window, cx| {
                    let next = match event.keystroke.key.as_str() {
                        "left" | "down" => value - step,
                        "right" | "up" => value + step,
                        "home" => min,
                        "end" => max,
                        _ => return,
                    };
                    cx.stop_propagation();
                    window.prevent_default();
                    view.dispatch(revision, handler, Input::Number(next.clamp(min, max)), cx);
                }))
                .on_a11y_action(gpui::AccessibleAction::Increment, move |_, _, cx| {
                    let _ = increment_view.update(cx, |view, cx| {
                        view.dispatch(
                            revision,
                            handler,
                            Input::Number((value + step).clamp(min, max)),
                            cx,
                        );
                    });
                })
                .on_a11y_action(gpui::AccessibleAction::Decrement, move |_, _, cx| {
                    let _ = decrement_view.update(cx, |view, cx| {
                        view.dispatch(
                            revision,
                            handler,
                            Input::Number((value - step).clamp(min, max)),
                            cx,
                        );
                    });
                })
                .on_a11y_action(gpui::AccessibleAction::SetValue, move |data, _, cx| {
                    if let Some(gpui::accesskit::ActionData::NumericValue(next)) = data {
                        if next.is_finite() {
                            let next = next.clamp(min, max);
                            let _ = set_value_view.update(cx, |view, cx| {
                                view.dispatch(revision, handler, Input::Number(next), cx);
                            });
                        }
                    }
                });
        }
        control.into_any_element()
    }

    fn chart(&self, node: &Node, id: usize, theme: &Theme) -> AnyElement {
        // Normalize before subtraction so even extreme finite data cannot overflow layout.
        let scale = node
            .values
            .iter()
            .fold(0.0_f64, |a, v| a.max(v.abs()))
            .max(f64::MIN_POSITIVE);
        let lo = node.values.iter().fold(0.0_f64, |a, v| a.min(v / scale));
        let hi = node.values.iter().fold(0.0_f64, |a, v| a.max(v / scale));
        let range = (hi - lo).max(f64::MIN_POSITIVE);
        let zero = (-lo / range) as f32;
        let mut chart = div()
            .id(("visual-chart", id))
            .role(gpui::Role::Group)
            .aria_label(if node.text.is_empty() {
                "Bar chart".to_string()
            } else {
                node.text.clone()
            })
            .w_full()
            .min_w_0()
            .p(px(16.0))
            .rounded(px(10.0))
            .border_1()
            .border_color(theme.border)
            .bg(theme.bg)
            .flex()
            .flex_col()
            .gap(px(10.0))
            .child(
                div()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child(if node.text.is_empty() {
                        "Chart".to_string()
                    } else {
                        node.text.clone()
                    }),
            );
        if node.values.is_empty() {
            chart = chart.child("No data yet");
        }
        for (index, value) in node.values.iter().take(CHART_BARS).enumerate() {
            let label = node
                .labels
                .get(index)
                .filter(|label| !label.is_empty())
                .cloned()
                .unwrap_or_else(|| format!("{}", index + 1));
            let end = ((value / scale - lo) / range) as f32;
            chart = chart.child(
                div()
                    .id(("bar", index))
                    .role(gpui::Role::Label)
                    .aria_label(format!("{label}: {}", number(*value)))
                    .flex()
                    .items_center()
                    .gap(px(12.0))
                    .min_h(px(24.0))
                    .child(
                        div()
                            .w(px(82.0))
                            .flex_none()
                            .text_size(ui_rems(12.0))
                            .text_color(theme.text_muted)
                            .child(label),
                    )
                    .child(
                        div()
                            .relative()
                            .h(px(18.0))
                            .flex_1()
                            .min_w(px(20.0))
                            .bg(theme.surface)
                            .rounded(px(3.0))
                            .overflow_hidden()
                            .child(
                                div()
                                    .absolute()
                                    .left(relative(zero.min(end)))
                                    .w(relative((end - zero).abs()))
                                    .h_full()
                                    .rounded(px(3.0))
                                    .bg(theme.accent),
                            )
                            .child(
                                div()
                                    .absolute()
                                    .left(relative(zero))
                                    .w(px(1.0))
                                    .h_full()
                                    .bg(theme.text_faint),
                            ),
                    )
                    .child(
                        div()
                            .w(px(64.0))
                            .flex_none()
                            .text_size(ui_rems(12.0))
                            .child(number(*value)),
                    ),
            );
        }
        if node.values.len() > CHART_BARS {
            chart = chart.child(
                div()
                    .text_size(ui_rems(11.0))
                    .text_color(theme.text_muted)
                    .child(format!(
                        "Showing the first {CHART_BARS} of {} values",
                        node.values.len()
                    )),
            );
        }
        chart.into_any_element()
    }
}

impl Render for VisualView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = Theme::of(cx).clone();
        let body = if let Some(error) = &self.error {
            div()
                .p(px(16.0))
                .rounded(px(8.0))
                .bg(theme.danger.opacity(0.08))
                .text_color(theme.danger)
                .flex()
                .flex_col()
                .gap(px(8.0))
                .child(
                    div()
                        .font_weight(FontWeight::SEMIBOLD)
                        .child("This visual could not run"),
                )
                .child(error.clone())
                .into_any_element()
        } else if let Some(node) = &self.node {
            self.render_node(node, 1, &mut 0, &theme, cx)
        } else {
            div()
                .text_color(theme.text_muted)
                .child("Preparing native visual…")
                .into_any_element()
        };
        div()
            .id("native-visual")
            .w_full()
            .h(px(VISUAL_HEIGHT))
            .min_w_0()
            .overflow_hidden()
            .rounded(px(12.0))
            .border_1()
            .border_color(theme.border)
            .bg(theme.surface_card)
            .text_color(theme.text)
            .font_family(theme.font_sans.clone())
            .text_size(ui_rems(13.0))
            .flex()
            .flex_col()
            .on_key_down(cx.listener(|_, event: &KeyDownEvent, window, cx| {
                if event.keystroke.key == "tab"
                    && !event.keystroke.modifiers.control
                    && !event.keystroke.modifiers.alt
                    && !event.keystroke.modifiers.platform
                {
                    if event.keystroke.modifiers.shift {
                        window.focus_prev(cx);
                    } else {
                        window.focus_next(cx);
                    }
                    cx.stop_propagation();
                }
            }))
            .child(
                div()
                    .flex_none()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap(px(12.0))
                    .px(px(18.0))
                    .py(px(13.0))
                    .border_b_1()
                    .border_color(theme.border)
                    .child(
                        div()
                            .min_w_0()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(self.title.clone()),
                    )
                    .child(
                        div()
                            .text_size(ui_rems(11.0))
                            .text_color(theme.text_muted)
                            .child(if self.busy {
                                "Updating…"
                            } else if self.error.is_some() {
                                "Stopped"
                            } else {
                                "Native · Interactive"
                            }),
                    ),
            )
            .child(
                div()
                    .id("visual-document")
                    .flex_1()
                    .min_h_0()
                    .min_w_0()
                    .overflow_y_scroll()
                    .p(px(18.0))
                    .child(body),
            )
            .child(
                div()
                    .flex_none()
                    .px(px(18.0))
                    .py(px(9.0))
                    .border_t_1()
                    .border_color(theme.border)
                    .text_size(ui_rems(11.0))
                    .text_color(theme.text_muted)
                    .child("Isolated Luau · No network or filesystem · Tab to controls"),
            )
    }
}

fn find_control<'a>(node: &'a Node, label: &str) -> Option<&'a Node> {
    if matches!(node.kind, Kind::Button | Kind::Toggle | Kind::Slider) && node.text == label {
        return Some(node);
    }
    node.children
        .iter()
        .find_map(|child| find_control(child, label))
}

fn control_label(node: &Node) -> String {
    if !node.text.trim().is_empty() {
        return node.text.clone();
    }
    match node.kind {
        Kind::Toggle => "Toggle",
        Kind::Slider => "Value",
        _ => "Run",
    }
    .into()
}

fn number(value: f64) -> String {
    if value == 0.0 {
        "0".into()
    } else if value.abs() >= 1_000_000.0 || value.abs() < 0.01 {
        format!("{value:.2e}")
    } else if value.fract().abs() < 0.000_001 {
        format!("{value:.0}")
    } else {
        format!("{value:.2}")
    }
}

fn plain(text: &str, limit: usize) -> String {
    let mut result: String = text
        .chars()
        .filter(|c| !c.is_control() || *c == '\n')
        .take(limit)
        .collect();
    if text.chars().count() > limit {
        result.push('…');
    }
    result
}

/// Shared synthetic scenario for native demos and transcript integration proof.
/// Values are invented, local-only data; the handlers really mutate Luau state.
pub const DEMO_SCRIPT: &str = include_str!("../examples/visuals-demo.luau");

/// Fixture-only access to the actual view mounted by the production transcript.
/// A weak handle avoids keeping discarded transcript rows or Lua states alive.
#[cfg(feature = "appshots-fixture")]
struct FixtureVisual(gpui::WeakEntity<VisualView>);
#[cfg(feature = "appshots-fixture")]
impl gpui::Global for FixtureVisual {}
#[cfg(feature = "appshots-fixture")]
pub fn fixture_view(cx: &gpui::App) -> Option<gpui::Entity<VisualView>> {
    cx.try_global::<FixtureVisual>()?.0.upgrade()
}
