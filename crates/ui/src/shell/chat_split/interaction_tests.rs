use super::*;
use crate::markdown::{render, selection};
use gpui::{MouseButton, MouseDownEvent, MouseUpEvent, Point, ScrollDelta, ScrollWheelEvent};
use harness_doc::{MessagePart, MessageRole, MessageStatus, SessionMessageEntry};
use harness_proto::ToolCall;

/// Keep the real Shell and peer-pane capture handlers, transcript, markdown and
/// tool controls, without booting an engine or rendering unrelated chrome.
struct InteractionPanes(Entity<Shell>);

impl Render for InteractionPanes {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.0.update(cx, |shell, cx| {
            let theme = Theme::of(cx).clone();
            let focus = shell.chat_split.as_ref().unwrap().focus;
            div().size_full().flex().children((0..2).map(|ix| {
                let pane = if ix == focus {
                    // Match the peer's geometry when its entity is promoted.
                    div()
                        .size_full()
                        .flex()
                        .flex_col()
                        .pt(px(Theme::TITLEBAR_HEIGHT))
                        .child(
                            div()
                                .flex_none()
                                .px(px(14.0))
                                .pb(px(6.0))
                                .text_size(crate::typography::ui_rems(12.0))
                                .child(SharedString::from("Session")),
                        )
                        .child(div().flex_1().min_h_0().child(shell.transcript.clone()))
                        .into_any_element()
                } else {
                    let id = shell.chat_split.as_ref().unwrap().panes[ix].clone();
                    shell.render_peer_chat_pane(ix, id.as_deref(), &theme, cx)
                };
                div()
                    .w(px(480.0))
                    .h_full()
                    .flex_none()
                    .debug_selector(move || {
                        if ix == 0 {
                            "peer-column"
                        } else {
                            "current-column"
                        }
                        .into()
                    })
                    .child(pane)
            }))
        })
    }
}

fn reply(text: &str) -> SessionMessageEntry {
    SessionMessageEntry {
        id: "reply".into(),
        role: MessageRole::Assistant,
        parts: vec![MessagePart::Text {
            id: "text".into(),
            text: text.into(),
        }],
        created_at: 0,
        device_id: "local".into(),
        status: Some(MessageStatus::Complete),
        continuation_of: None,
        duration_ms: None,
    }
}

fn with_panes(
    cx: &mut gpui::TestAppContext,
    entries: Vec<SessionMessageEntry>,
    run: impl FnOnce(
        Entity<Shell>,
        Entity<Transcript>,
        Entity<Transcript>,
        &mut gpui::VisualTestContext,
    ),
) {
    let dir = tempfile::tempdir().unwrap();
    cx.update(|cx| {
        gpui_base::init(cx);
        cx.set_global(Theme::default());
        crate::app_menus::init(cx);
        crate::history::init(
            Default::default(),
            Default::default(),
            Default::default(),
            Default::default(),
            cx,
        );
        settings::init(settings::UiSettings::default(), dir.path(), cx);
        crate::motion::set_reduced_motion(cx, true);
    });
    let (host, cx) = cx.add_window_view(|_, cx| {
        InteractionPanes(cx.new(|cx| {
            let state = cx.new(|_| AppState::new());
            state.update(cx, |state, cx| {
                state.chats = ["current", "peer"]
                    .map(|id| {
                        serde_json::from_value(serde_json::json!({
                            "id": id, "deviceId": "local", "title": "Session",
                            "archived": false, "createdAt": Utc::now(),
                        }))
                        .unwrap()
                    })
                    .into();
                state.select_chat(Some("current".into()), cx);
                let mut current =
                    reply("Current response must not be selected instead of the peer.");
                current.id = "current-reply".into();
                state.transcript = vec![current];
                state.transcript_replayed = true;
                state.transcript_revision += 1;
                state.set_subagent_snapshot("peer".into(), entries);
            });
            let mut shell = Shell::new(
                state,
                EngineBootConfig {
                    data_dir: dir.path().into(),
                    ipc_port: 0,
                    edge_url: "http://127.0.0.1:1".into(),
                    edge_token: None,
                    org_id: None,
                    codegraff_client_id: None,
                    default_harness: harness_proto::HarnessId::Mock,
                },
                cx,
            );
            shell.chat_split =
                ChatSplit::split(None, SplitAxis::Horizontal, Some("peer".into()), None);
            shell.sync_chat_panes(cx);
            shell
                .transcript
                .update(cx, |transcript, cx| transcript.set_rail_enabled(false, cx));
            shell
        }))
    });
    cx.simulate_resize(gpui::size(px(960.0), px(640.0)));
    draw(cx);
    let shell = host.read_with(cx, |host, _| host.0.clone());
    let (peer, current) = shell.read_with(cx, |shell, _| {
        (
            shell.peer_chat_views["peer"].transcript.clone(),
            shell.transcript.clone(),
        )
    });
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.chat_split.as_ref().unwrap().focus, 1);
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("current")
        );
    });
    run(shell, peer, current, cx);
    // Parameterized gestures create multiple windows with fixture row IDs.
    // Release their painted selection owners before the next window starts.
    cx.update(|window, _| window.remove_window());
    drop(host);
    cx.run_until_parked();
}

fn draw(cx: &mut gpui::VisualTestContext) {
    cx.run_until_parked();
    cx.update(|window, cx| {
        window.refresh();
        let _ = window.draw(cx);
    });
}

fn key(_transcript: &Entity<Transcript>, row_key: &str) -> String {
    row_key.to_owned()
}

fn text_point(transcript: &Entity<Transcript>, row_key: &str) -> Point<gpui::Pixels> {
    render::selection_test_bounds(&key(transcript, row_key)).origin + gpui::point(px(2.0), px(9.0))
}

fn assert_peer_active(
    shell: &Entity<Shell>,
    peer: &Entity<Transcript>,
    current: &Entity<Transcript>,
    cx: &mut gpui::VisualTestContext,
) {
    draw(cx);
    shell.read_with(cx, |shell, cx| {
        assert_eq!(shell.chat_split.as_ref().unwrap().focus, 0);
        assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some("peer"));
        assert_eq!(
            shell.transcript.entity_id(),
            peer.entity_id(),
            "activation must promote the interacted-with entity, not replace it"
        );
        assert_eq!(
            shell.peer_chat_views["current"].transcript.entity_id(),
            current.entity_id(),
            "the outgoing pane must retain its entity too"
        );
    });
}

#[derive(Clone, Copy, Debug)]
enum SelectionGesture {
    Drag,
    DoubleClick,
    Multiline,
    Code,
    LongPress,
}

#[gpui::test]
fn selecting_in_an_inactive_pane_activates_and_preserves_selection(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for gesture in [
        SelectionGesture::Drag,
        SelectionGesture::DoubleClick,
        SelectionGesture::Multiline,
        SelectionGesture::Code,
        SelectionGesture::LongPress,
    ] {
        let text = if matches!(gesture, SelectionGesture::Code) {
            "```text\nselectable\nsecond\n```"
        } else {
            "Selectable response text.\n\nAnother selectable paragraph."
        };
        with_panes(cx, vec![reply(text)], |shell, peer, current, cx| {
            // The peer is painted before the primary, so this also checks
            // main's existing per-transcript selection-owner isolation.
            let first = if matches!(gesture, SelectionGesture::Code) {
                "reply#text.0-code0-line0"
            } else {
                "reply#text.0:0"
            };
            let start = text_point(&peer, first);
            let count = if matches!(gesture, SelectionGesture::DoubleClick) {
                2
            } else {
                1
            };
            cx.simulate_event(MouseDownEvent {
                button: MouseButton::Left,
                position: start,
                click_count: count,
                ..Default::default()
            });
            let end = match gesture {
                SelectionGesture::DoubleClick => start,
                SelectionGesture::Multiline => {
                    text_point(&peer, "reply#text.1:1") + gpui::point(px(90.0), px(0.0))
                }
                SelectionGesture::Code => {
                    let bounds =
                        render::selection_test_bounds(&key(&peer, "reply#text.0-code0-line1"));
                    gpui::point(bounds.right(), bounds.top() + px(9.0))
                }
                _ => start + gpui::point(px(100.0), px(0.0)),
            };
            if matches!(gesture, SelectionGesture::LongPress) {
                // Desktop long-press selection is a held primary press that
                // becomes a drag, not a separate touch platform event.
                cx.background_executor
                    .advance_clock(std::time::Duration::from_millis(650));
                draw(cx);
            }
            if !matches!(gesture, SelectionGesture::DoubleClick) {
                cx.simulate_mouse_move(end, Some(MouseButton::Left), Default::default());
            }
            let selected = selection::selected_text()
                .unwrap_or_else(|| panic!("{gesture:?} must perform the original selection"));
            assert!(!selected.is_empty(), "{gesture:?}");
            match gesture {
                SelectionGesture::DoubleClick => assert_eq!(selected, "Selectable"),
                SelectionGesture::Multiline => assert!(selected.contains("\n"), "{selected:?}"),
                SelectionGesture::Code => assert_eq!(selected, "selectable\nsecond"),
                _ => assert!(selected.starts_with("Selectable"), "{selected:?}"),
            }
            cx.simulate_event(MouseUpEvent {
                button: MouseButton::Left,
                position: end,
                click_count: count,
                ..Default::default()
            });
            assert_peer_active(&shell, &peer, &current, cx);
            assert_eq!(
                selection::selected_text(),
                Some(selected),
                "{gesture:?}: activation must not discard the completed selection"
            );
            selection::end_active_drag();
            selection::clear_if_owner(&key(&peer, first));
        });
    }
}

#[gpui::test]
fn every_mouse_button_activates_an_inactive_pane_on_release(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    for button in [MouseButton::Left, MouseButton::Right, MouseButton::Middle] {
        with_panes(
            cx,
            vec![reply("Selectable response text.")],
            |shell, peer, current, cx| {
                // Use actual selectable text rather than an inert test-only button.
                let point = text_point(&peer, "reply#text.0:0");
                cx.simulate_mouse_down(point, button, Default::default());
                cx.simulate_mouse_up(point, button, Default::default());
                assert_peer_active(&shell, &peer, &current, cx);
                selection::end_active_drag();
                selection::clear_if_owner(&key(&peer, "reply#text.0:0"));
            },
        );
    }
}

#[gpui::test]
fn an_old_highlight_does_not_block_a_click_in_another_pane(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    with_panes(
        cx,
        vec![reply("Selectable response text.")],
        |shell, peer, current, cx| {
            let start = text_point(&current, "current-reply#text.0:0");
            let end = start + gpui::point(px(90.0), px(0.0));
            cx.simulate_mouse_down(start, MouseButton::Left, Default::default());
            cx.simulate_mouse_move(end, Some(MouseButton::Left), Default::default());
            cx.simulate_mouse_up(end, MouseButton::Left, Default::default());
            assert!(selection::selected_text().is_some());
            let pane = cx.debug_bounds("peer-column").unwrap();
            cx.simulate_click(
                pane.origin + gpui::point(px(100.0), px(Theme::TITLEBAR_HEIGHT + 6.0)),
                Default::default(),
            );
            assert_peer_active(&shell, &peer, &current, cx);
            selection::clear_if_owner(&key(&current, "current-reply#text.0:0"));
        },
    );
}

#[gpui::test]
fn first_disclosure_click_both_activates_and_toggles_the_real_tool_group(
    cx: &mut gpui::TestAppContext,
) {
    let _selection = selection::test_state_lock();
    let mut entry = reply("");
    entry.parts = vec![MessagePart::Tool {
        id: "call".into(),
        call: ToolCall::Exec {
            command: "pwd".into(),
        },
        is_error: false,
        resolved: true,
        output: None,
        diff: None,
        view: None,
        output_ref: None,
        output_bytes: None,
        diff_ref: None,
        diff_stats: None,
        subagent_ref: None,
        subagent_status: None,
        subagent_tail: None,
    }];
    with_panes(cx, vec![entry], |shell, peer, current, cx| {
        for opening in [true, false] {
            if !opening {
                shell.update(cx, |shell, cx| {
                    assert!(shell.select_chat_pane(1, cx));
                });
                draw(cx);
            }
            let row_id = peer.read_with(cx, |transcript, _| transcript.rows()[0].id.clone());
            let header = cx
                .debug_bounds("transcript-tool-group-header")
                .expect("painted tool header");
            cx.simulate_click(header.center(), Default::default());
            assert_peer_active(&shell, &peer, &current, cx);
            peer.read_with(cx, |transcript, _| {
                assert_eq!(
                    transcript.test_fold_open(&row_id),
                    Some(opening),
                    "the first click must toggle, not merely focus",
                );
            });
        }
    });
}

#[gpui::test]
fn composer_send_targets_the_promoted_transcript(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    with_panes(
        cx,
        vec![reply("Selectable response text.")],
        |shell, peer, current, cx| {
            shell.update(cx, |shell, cx| assert!(shell.select_chat_pane(0, cx)));
            assert_peer_active(&shell, &peer, &current, cx);
            assert!(current.read_with(cx, |transcript, _| transcript.is_pinned()));
            let composer = shell.read_with(cx, |shell, _| shell.composer.clone());
            composer.update(cx, |_, cx| {
                cx.emit(ComposerEvent::Sent {
                    chat_id: "peer".into(),
                    message_id: "new-prompt".into(),
                });
            });
            cx.run_until_parked();
            assert!(
                !peer.read_with(cx, |transcript, _| transcript.is_pinned()),
                "own-send must anchor in the promoted transcript"
            );
            assert!(
                current.read_with(cx, |transcript, _| transcript.is_pinned()),
                "own-send must not target the old primary entity"
            );
        },
    );
}

#[gpui::test]
fn first_jump_click_both_activates_and_scrolls_the_same_transcript(cx: &mut gpui::TestAppContext) {
    let _selection = selection::test_state_lock();
    let text = (0..40)
        .map(|ix| format!("Paragraph {ix} contains enough response text for scrolling.\n\n"))
        .collect::<String>();
    with_panes(cx, vec![reply(&text)], |shell, peer, current, cx| {
        let pane = cx.debug_bounds("peer-column").unwrap();
        cx.simulate_event(ScrollWheelEvent {
            position: pane.center(),
            delta: ScrollDelta::Pixels(gpui::point(px(0.0), px(10000.0))),
            ..Default::default()
        });
        draw(cx);
        peer.read_with(cx, |transcript, _| {
            assert!(
                transcript.jump_button_shown(),
                "scrolling away must expose the real jump control"
            );
            assert!(!transcript.is_pinned());
        });
        let before = peer.read_with(cx, |transcript, _| {
            transcript.list_state().logical_scroll_top()
        });
        // render_peer_chat_pane places its 30px pill 16px above the bottom.
        cx.simulate_click(
            gpui::point(pane.center().x, pane.bottom() - px(31.0)),
            Default::default(),
        );
        assert_peer_active(&shell, &peer, &current, cx);
        peer.read_with(cx, |transcript, _| {
            assert!(
                transcript.is_pinned(),
                "the original jump action must run on the activation click"
            );
            assert!(!transcript.jump_button_shown());
            let after = transcript.list_state().logical_scroll_top();
            assert!(
                after.item_ix > before.item_ix
                    || (after.item_ix == before.item_ix
                        && after.offset_in_item > before.offset_in_item),
                "the click must actually advance the viewport: {before:?} -> {after:?}"
            );
        });
    });
}
