use super::*;

fn arrow(
    cx: &mut gpui::TestAppContext,
    handle: gpui::WindowHandle<Composer>,
    older: bool,
) -> String {
    handle
        .update(cx, |composer, window, cx| {
            composer.input.update(cx, |input, cx| {
                if older {
                    input.up(&Up, window, cx);
                } else {
                    input.down(&Down, window, cx);
                }
            });
        })
        .unwrap();
    cx.run_until_parked();
    handle
        .read_with(cx, |composer, cx| composer.input.read(cx).text().to_owned())
        .unwrap()
}

fn question_entry(resolved: bool) -> SessionMessageEntry {
    let mut row = entry("question", MessageRole::Assistant, "");
    row.status = Some(harness_doc::MessageStatus::Streaming);
    row.parts = vec![MessagePart::Input {
        id: "question-part".into(),
        request_id: "question-request".into(),
        questions: vec![UserInputQuestion {
            id: "q".into(),
            header: "Choice".into(),
            question: "Which option?".into(),
            options: vec!["One".into(), "Two".into()],
            multi_select: false,
            prefill: None,
            multiline: false,
        }],
        resolved,
    }];
    row
}

#[gpui::test]
fn prompt_history_question_interruptions_preserve_the_real_draft(cx: &mut gpui::TestAppContext) {
    let (_dir, state, window) = composer_with_history(cx);
    for edited in [false, true] {
        window
            .update(cx, |composer, window, cx| {
                composer
                    .input
                    .update(cx, |input, cx| input.set_text("unsent draft", cx));
                composer.navigate_prompt_history(-1, cx);
                if edited {
                    composer.input.update(cx, |input, cx| {
                        input.replace_text_in_range(None, " edited", window, cx);
                    });
                }
            })
            .unwrap();
        state.update(cx, |state, _| state.transcript.push(question_entry(false)));
        window
            .update(cx, |composer, _, cx| {
                composer.on_state_changed(cx);
                assert!(composer.wizard.is_some());
                assert!(composer.input.read(cx).text().is_empty());
                // History keys must not pull an old prompt into the answer editor.
                composer.navigate_prompt_history(-1, cx);
                assert!(composer.input.read(cx).text().is_empty());
            })
            .unwrap();
        state.update(cx, |state, _| {
            state.transcript.pop();
            state.transcript.push(question_entry(true));
        });
        window
            .update(cx, |composer, _, cx| {
                composer.on_state_changed(cx);
                assert!(composer.wizard.is_none());
                assert_eq!(
                    composer.input.read(cx).text(),
                    if edited {
                        "Last prompt edited"
                    } else {
                        "unsent draft"
                    }
                );
            })
            .unwrap();
        state.update(cx, |state, _| {
            state.transcript.pop();
        });
    }
}

#[gpui::test]
fn prompt_history_recalled_commands_do_not_capture_following_arrows(cx: &mut gpui::TestAppContext) {
    let (_dir, state, window) = composer_with_history(cx);
    state.update(cx, |state, _| {
        state.transcript = vec![
            entry("first", MessageRole::User, "First prompt"),
            entry("command", MessageRole::User, "/settings"),
        ];
    });
    window
        .update(cx, |composer, _, cx| {
            composer.input.update(cx, |input, cx| input.move_to(0, cx));
        })
        .unwrap();
    assert_eq!(arrow(cx, window, true), "/settings");
    assert_eq!(arrow(cx, window, true), "First prompt");
    assert_eq!(arrow(cx, window, false), "/settings");
    assert_eq!(arrow(cx, window, false), "unsent draft");
}

#[gpui::test]
fn prompt_history_native_key_and_edit_sequences_match_a_draft_stack(cx: &mut gpui::TestAppContext) {
    let (_dir, _state, window) = composer_with_history(cx);
    let history = ["First prompt", "Last prompt"];
    // Every length-six sequence of Up, Down, and a real editor insertion.
    for sequence in 0..729usize {
        let mut code = sequence;
        let mut draft = "draft".to_string();
        let mut cursor: Option<usize> = None;
        let mut expected = draft.clone();
        window
            .update(cx, |composer, _, cx| {
                composer
                    .input
                    .update(cx, |input, cx| input.set_text(&draft, cx));
            })
            .unwrap();
        for step in 0..6 {
            let action = code % 3;
            code /= 3;
            if action == 2 {
                window
                    .update(cx, |composer, window, cx| {
                        composer.input.update(cx, |input, cx| {
                            input.move_to(input.content.len(), cx);
                            input.replace_text_in_range(None, "x", window, cx);
                        });
                    })
                    .unwrap();
                cx.run_until_parked();
                expected.push('x');
                draft = expected.clone();
                cursor = None;
            } else {
                let older = action == 0;
                window
                    .update(cx, |composer, _, cx| {
                        composer.input.update(cx, |input, cx| {
                            input.move_to(if older { 0 } else { input.content.len() }, cx);
                        });
                    })
                    .unwrap();
                cursor = if older {
                    Some(cursor.map_or(history.len() - 1, |index| index.saturating_sub(1)))
                } else {
                    cursor.and_then(|index| (index + 1 < history.len()).then_some(index + 1))
                };
                expected = cursor.map_or_else(|| draft.clone(), |index| history[index].into());
                let actual = arrow(cx, window, older);
                assert_eq!(actual, expected, "sequence {sequence}, step {step}");
            }
        }
    }
}

#[gpui::test]
fn prompt_history_completion_reopens_only_after_a_real_edit(cx: &mut gpui::TestAppContext) {
    let (_dir, state, window) = composer_with_history(cx);
    state.update(cx, |state, _| {
        state.transcript = vec![entry("command", MessageRole::User, "/s")];
    });
    window
        .update(cx, |composer, _, cx| {
            composer.input.update(cx, |input, cx| input.move_to(0, cx));
        })
        .unwrap();
    assert_eq!(arrow(cx, window, true), "/s");
    window
        .update(cx, |composer, window, cx| {
            assert!(
                composer.slash.token.is_none(),
                "recall must not open a completion popup"
            );
            composer.input.update(cx, |input, cx| {
                input.replace_text_in_range(None, "e", window, cx);
            });
        })
        .unwrap();
    cx.run_until_parked();
    window
        .read_with(cx, |composer, _| {
            assert!(
                composer.slash.token.is_some(),
                "typing must still discover commands"
            );
        })
        .unwrap();
}

#[gpui::test]
fn prompt_history_queue_editor_borrowing_restores_the_displaced_draft(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, _state, window) = composer_with_history(cx);
    for edited in [false, true] {
        window
            .update(cx, |composer, window, cx| {
                composer
                    .input
                    .update(cx, |input, cx| input.set_text("queue draft", cx));
                composer.navigate_prompt_history(-1, cx);
                if edited {
                    composer.input.update(cx, |input, cx| {
                        input.replace_text_in_range(None, " edited", window, cx);
                    });
                }
                let draft = composer.take_prompt_draft(cx);
                composer.queue_edit_draft = Some((draft, vec![], vec![]));
                composer.editing_queued = Some("queued-row".into());
                composer
                    .input
                    .update(cx, |input, cx| input.set_text("queued text", cx));
                composer.navigate_prompt_history(-1, cx);
                assert_eq!(composer.input.read(cx).text(), "queued text");
                composer.clear_queue_edit(cx);
                assert_eq!(
                    composer.input.read(cx).text(),
                    if edited {
                        "Last prompt edited"
                    } else {
                        "queue draft"
                    }
                );
                assert!(composer.prompt_history.is_none());
            })
            .unwrap();
    }
}
