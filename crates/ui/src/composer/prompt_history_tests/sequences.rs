use super::*;

#[gpui::test]
fn prompt_history_update_matrix_keeps_browsing_stable_until_draft_restore(
    cx: &mut gpui::TestAppContext,
) {
    let (_dir, state, window) = composer_with_history(cx);
    for draft in ["", "草稿 🧪\n  keep whitespace  "] {
        for update in 0..5 {
            state.update(cx, |state, _| {
                state.transcript = vec![
                    entry("first", MessageRole::User, "First prompt"),
                    entry("peer", MessageRole::User, PEER),
                    entry("last", MessageRole::User, "Last prompt"),
                ];
            });
            window
                .update(cx, |composer, _, cx| {
                    composer
                        .input
                        .update(cx, |input, cx| input.set_text(draft, cx));
                    composer.navigate_prompt_history(-1, cx);
                    composer.navigate_prompt_history(-1, cx);
                    assert_eq!(composer.input.read(cx).text(), "First prompt");
                })
                .unwrap();
            state.update(cx, |state, _| match update {
                0 => state
                    .transcript
                    .push(entry("new", MessageRole::User, "Remote prompt")),
                1 => state.transcript.truncate(1),
                2 => state.transcript.clear(),
                3 => {
                    state.transcript =
                        vec![entry("replacement", MessageRole::User, "Replayed prompt")]
                }
                _ => state.transcript = vec![entry("only-peer", MessageRole::User, PEER)],
            });
            window
                .update(cx, |composer, _, cx| {
                    for (delta, expected) in [
                        (-1, "First prompt"),
                        (1, "Last prompt"),
                        (-1, "First prompt"),
                        (1, "Last prompt"),
                        (1, draft),
                        (1, draft),
                    ] {
                        composer.navigate_prompt_history(delta, cx);
                        assert_eq!(composer.input.read(cx).text(), expected, "update {update}");
                    }
                    assert!(composer.prompt_history.is_none());
                    composer.navigate_prompt_history(-1, cx);
                    let expected = match update {
                        0 => "Remote prompt",
                        1 => "First prompt",
                        3 => "Replayed prompt",
                        _ => draft,
                    };
                    assert_eq!(composer.input.read(cx).text(), expected);
                })
                .unwrap();
        }
    }
}

#[gpui::test]
fn prompt_history_selection_and_ime_never_recall_over_active_edits(cx: &mut gpui::TestAppContext) {
    let (_dir, _state, window) = composer_with_history(cx);
    window
        .update(cx, |composer, window, cx| {
            composer.input.update(cx, |input, cx| {
                input.select_all(&SelectAll, window, cx);
                assert!(!input.history_step(-1));
                input.up(&Up, window, cx);
                assert_eq!(input.text(), "unsent draft");
                input.move_to(0, cx);
                input.marked_range = Some(0..0);
                assert!(!input.history_step(-1));
                assert!(!input.history_step(1));
                input.marked_range = None;
                assert!(input.history_step(-1));
            });
        })
        .unwrap();
}

#[test]
fn prompt_history_multipart_and_attachment_only_rows_do_not_leak_peer_text() {
    let (header, body) = PEER.split_once("\n\n").unwrap();
    let mut peer = entry("multipart-peer", MessageRole::User, header);
    peer.parts.push(MessagePart::Text {
        id: "body".into(),
        text: body.into(),
    });
    let attachment_only = format!(
        "{}\n\nAttached images (local files):\n- /synthetic/only.png",
        attachments::ATTACHMENT_ONLY_TEXT
    );
    assert_eq!(
        session_prompts(&[
            peer,
            entry("image-only", MessageRole::User, &attachment_only),
            entry("blank", MessageRole::User, " \t\n "),
            entry("human", MessageRole::User, "  Human prompt  "),
        ]),
        vec!["  Human prompt  "]
    );
}

#[test]
fn prompt_history_room_labels_cannot_escape_delivery_classification() {
    use harness_proto::room_delivery::{self, RoomOrigin};
    for label in ["helper --> suffix", "helper\nnext line", "café 🧪"] {
        let room = room_delivery::format(
            &RoomOrigin {
                room_id: "room-test".into(),
                room_name: label.into(),
                seq: 2,
                from_member: label.into(),
                member_kind: "graff".into(),
                from_user: false,
                framed: false,
                external: false,
                from_display: None,
                from_github: None,
                from_fingerprint: None,
            },
            "Check the tests.",
        );
        assert!(session_prompts(&[entry("room", MessageRole::User, &room)]).is_empty());
    }
}
