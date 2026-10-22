//! Synthetic split-pane link ownership regressions; no engine or network needed.
#![cfg(any(target_os = "macos", target_os = "linux"))]

use super::*;
use crate::markdown::render::{LinkAction, LinkActivation, LinkOutcome, LinkTarget};
use crate::pickers::{CanvasDraft, CanvasInput, CanvasTarget};
use gpui::{AppContext, TestAppContext};

const URL: &str = "https://example.com/split-links";

fn activation(source: Option<&str>, action: LinkAction) -> LinkActivation {
    LinkActivation {
        target: LinkTarget::new("Synthetic documentation", URL),
        source_session: source.map(str::to_owned),
        action,
    }
}

/// Three visible panes, with either an existing chat or a canvas focused in
/// the last slot. Seeding rows lets the ordinary pane-switch path run without
/// an engine, rather than mocking the ownership transition under test.
fn with_link_panes(
    cx: &mut TestAppContext,
    owner: Option<&str>,
    run: impl FnOnce(&mut Shell, &mut Window, &mut Context<Shell>),
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
    });
    let window = cx.add_window(|_, cx| {
        let state = cx.new(|_| AppState::new());
        state.update(cx, |state, cx| {
            state.chats = ["owner", "peer-a", "peer-b", "parked"]
                .into_iter()
                .map(|id| {
                    serde_json::from_value(serde_json::json!({
                        "id": id, "deviceId": "local", "title": "Synthetic session",
                        "cwd": "/workspace/link-tests", "archived": false,
                        "createdAt": Utc::now(),
                    }))
                    .unwrap()
                })
                .collect();
            state.select_chat(owner.map(str::to_owned), cx);
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
        shell.route = Route::Chat;
        shell.active_chat = owner.unwrap_or_default().into();
        shell.chat_split_selected = owner.map(str::to_owned);
        let split =
            chat_split::ChatSplit::split(None, SplitAxis::Horizontal, Some("peer-a".into()), None);
        shell.chat_split =
            chat_split::ChatSplit::split(split, SplitAxis::Horizontal, Some("peer-b".into()), None);
        shell.sync_chat_panes(cx);
        shell
    });
    window.update(cx, run).unwrap();
    cx.run_until_parked();
}

/// Check more than tab counts: rejection/external routing must not select a
/// peer, park a draft, reveal a panel, change its active tab, or open a file.
#[derive(Debug, PartialEq)]
struct LinkState {
    active: String,
    selected: Option<String>,
    route: Route,
    split: Option<chat_split::ChatSplit>,
    draft: CanvasDraft,
    browser_seq: u64,
    browsers: Vec<u64>,
    file_surfaces: Vec<u64>,
    file_explorers: usize,
    tabs: std::collections::HashMap<String, Vec<RightSurface>>,
    panels: std::collections::HashMap<String, ChatPanels>,
    peers: Vec<String>,
    notice: Option<SharedString>,
}

fn link_state(shell: &Shell, cx: &App) -> LinkState {
    let mut browsers: Vec<_> = shell.browsers.keys().copied().collect();
    browsers.sort_unstable();
    let mut file_surfaces: Vec<_> = shell.file_surfaces.keys().copied().collect();
    file_surfaces.sort_unstable();
    let mut peers: Vec<_> = shell.peer_chat_views.keys().cloned().collect();
    peers.sort();
    LinkState {
        active: shell.active_chat.clone(),
        selected: shell.state.read(cx).selected_chat.clone(),
        route: shell.route,
        split: shell.chat_split.clone(),
        draft: shell.current_canvas_draft(cx),
        browser_seq: shell.browser_seq,
        browsers,
        file_surfaces,
        file_explorers: shell.files.len(),
        tabs: shell.right_tabs.clone(),
        panels: shell.panels.map.clone(),
        peers,
        notice: shell.sidebar_notice.clone(),
    }
}

fn assert_rejected_unchanged(
    shell: &mut Shell,
    activation: &LinkActivation,
    window: &mut Window,
    cx: &mut Context<Shell>,
) {
    let before = link_state(shell, cx);
    assert_eq!(
        shell.activate_session_link(activation, window, cx),
        LinkOutcome::Rejected,
        "{activation:?}"
    );
    assert_eq!(link_state(shell, cx), before, "{activation:?}");
}

#[gpui::test]
fn split_links_require_a_nonempty_source_and_a_live_unfocused_peer(cx: &mut TestAppContext) {
    with_link_panes(cx, Some("owner"), |shell, window, cx| {
        for source in [None, Some(""), Some("deleted-session"), Some("parked")] {
            assert_rejected_unchanged(shell, &activation(source, LinkAction::Internal), window, cx);
        }

        let link = activation(Some("peer-a"), LinkAction::Internal);
        // A layout entry alone is not an authorization: its view may already
        // have been released while an old callback is still in flight.
        let view = shell.peer_chat_views.remove("peer-a").unwrap();
        assert_rejected_unchanged(shell, &link, window, cx);
        shell.peer_chat_views.insert("peer-a".into(), view);

        // Conversely, a cached view or a parked tab is not a visible pane.
        shell.chat_tabs = vec![
            chat_tabs::ChatTab::default(),
            chat_tabs::ChatTab {
                selected: Some("peer-a".into()),
                ..Default::default()
            },
        ];
        let split = shell.chat_split.as_mut().unwrap();
        split.panes[0] = None;
        split.vanished[0] = Some("peer-a".into());
        assert!(shell.peer_chat_views.contains_key("peer-a"));
        assert_rejected_unchanged(shell, &link, window, cx);

        // The focused slot is a placeholder, never a second source of truth
        // for the selected chat, even if it temporarily retains a stale id.
        let split = shell.chat_split.as_mut().unwrap();
        split.panes[split.focus] = Some("peer-a".into());
        assert_rejected_unchanged(shell, &link, window, cx);
    });
}

#[gpui::test]
fn split_links_reject_selection_handoffs_including_canvas_mismatches(cx: &mut TestAppContext) {
    with_link_panes(cx, Some("owner"), |shell, window, cx| {
        let link = activation(Some("peer-a"), LinkAction::Internal);
        for (active, selected) in [
            ("owner", None),
            ("owner", Some("peer-b")),
            ("", Some("owner")),
            ("", Some("peer-a")),
        ] {
            shell.active_chat = active.into();
            shell.state.update(cx, |state, _| {
                state.selected_chat = selected.map(str::to_owned);
            });
            assert_rejected_unchanged(shell, &link, window, cx);
        }
    });
}

#[gpui::test]
fn unsafe_split_links_never_fall_back_to_files_or_promote_a_canvas(cx: &mut TestAppContext) {
    with_link_panes(cx, Some("owner"), |shell, window, cx| {
        // Cover both the focused workspace-file fallback and the canvas peer
        // promotion boundary, without multiplying every URL by every action.
        let cases = [
            ("javascript:alert(1)", LinkAction::Internal),
            ("data:text/html,synthetic", LinkAction::Primary),
            ("mailto:synthetic@example.com", LinkAction::External),
            ("https://user:pass@example.com/", LinkAction::Internal),
            ("https://", LinkAction::Primary),
            ("https://example.com/%GG", LinkAction::External),
        ];
        for canvas in [false, true] {
            shell.active_chat = if canvas { "" } else { "owner" }.into();
            shell.state.update(cx, |state, _| {
                state.selected_chat = (!canvas).then(|| "owner".into());
            });
            for (url, action) in cases {
                let mut link = activation(Some(if canvas { "peer-b" } else { "owner" }), action);
                link.target = LinkTarget::new("Untrusted destination", url);
                assert!(link.target.navigation.is_err(), "{url}");
                assert_rejected_unchanged(shell, &link, window, cx);
            }
        }
    });
}

#[gpui::test]
fn multi_peer_links_follow_preferences_and_internal_tabs_belong_to_the_source(
    cx: &mut TestAppContext,
) {
    with_link_panes(cx, Some("owner"), |shell, window, cx| {
        let peer_a = shell.peer_chat_views["peer-a"].transcript.entity_id();
        let peer_b = shell.peer_chat_views["peer-b"].transcript.entity_id();
        for (source, prefer_internal, action, internal) in [
            ("peer-a", false, LinkAction::Primary, false),
            ("peer-b", false, LinkAction::Internal, true),
            ("peer-a", true, LinkAction::Primary, true),
            ("peer-b", true, LinkAction::External, false),
        ] {
            settings::update(settings::SavePolicy::Immediate, cx, |settings| {
                settings.open_web_links_in_harness = prefer_internal;
            });
            let before = link_state(shell, cx);
            let outcome =
                shell.activate_session_link(&activation(Some(source), action), window, cx);
            if internal {
                assert_eq!(outcome, LinkOutcome::Internal);
                assert_eq!(shell.browsers.len(), before.browsers.len() + 1);
                let id = shell.browser_seq;
                assert_eq!(
                    shell.right_tabs[source].last(),
                    Some(&RightSurface::Browser(id))
                );
                assert_eq!(shell.browsers[&id].read(cx).page.url.as_deref(), Some(URL));
                assert_eq!(shell.active_chat, source);
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), Some(source));
                assert!(shell.right_pane_open(cx));
                assert_eq!(
                    shell.transcript.entity_id(),
                    if source == "peer-a" { peer_a } else { peer_b }
                );
            } else {
                assert_eq!(outcome, LinkOutcome::External(URL.into()));
                assert_eq!(link_state(shell, cx), before);
            }
            assert!(!shell.right_tabs.contains_key("owner"));
        }
        assert_eq!(shell.right_tabs["peer-a"].len(), 1);
        assert_eq!(shell.right_tabs["peer-b"].len(), 1);

        // Reuse a source callback after another pane takes focus. Navigation
        // must reveal the source's own tab, not strand it in the old host.
        let link = activation(Some("peer-a"), LinkAction::Internal);
        assert!(shell.select_chat_pane(1, cx));
        shell.on_state_changed(&shell.state.clone(), cx);
        assert_eq!(shell.active_chat, "peer-b");
        assert_eq!(shell.transcript.entity_id(), peer_b);
        for count in 2..=3 {
            assert_eq!(
                shell.activate_session_link(&link, window, cx),
                LinkOutcome::Internal
            );
            assert_eq!(shell.right_tabs["peer-a"].len(), count);
            assert_eq!(shell.right_tabs["peer-b"].len(), 1);
            assert_eq!(shell.active_chat, "peer-a");
            assert!(shell.right_pane_open(cx));
            assert_eq!(shell.transcript.entity_id(), peer_a);
        }
    });
}

#[gpui::test]
fn canvas_link_promotion_parks_the_draft_and_repeated_links_keep_the_new_owner(
    cx: &mut TestAppContext,
) {
    with_link_panes(cx, None, |shell, window, cx| {
        shell.adopt_canvas_draft(
            Some(CanvasDraft {
                harness: Some(harness_proto::HarnessId::Mock),
                model: Some("synthetic-model".into()),
                reasoning: Some(harness_proto::ReasoningLevel::High),
                target: Some(CanvasTarget {
                    space: None,
                    no_project: true,
                    device: Some("local".into()),
                }),
                input: Some(CanvasInput {
                    text: "Unsent synthetic canvas draft".into(),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            cx,
        );
        let draft = shell.current_canvas_draft(cx);
        assert_eq!(draft.model.as_deref(), Some("synthetic-model"));
        assert_eq!(
            draft.input.as_ref().unwrap().text,
            "Unsent synthetic canvas draft"
        );
        let peer_a = shell.peer_chat_views["peer-a"].transcript.entity_id();
        let peer_b = shell.peer_chat_views["peer-b"].transcript.entity_id();
        let link = activation(Some("peer-b"), LinkAction::Primary);

        settings::update(settings::SavePolicy::Immediate, cx, |settings| {
            settings.open_web_links_in_harness = false;
        });
        let before = link_state(shell, cx);
        assert_eq!(
            shell.activate_session_link(&link, window, cx),
            LinkOutcome::External(URL.into())
        );
        assert_eq!(
            link_state(shell, cx),
            before,
            "external links must leave the canvas live"
        );

        settings::update(settings::SavePolicy::Immediate, cx, |settings| {
            settings.open_web_links_in_harness = true;
        });
        assert_eq!(
            shell.activate_session_link(&link, window, cx),
            LinkOutcome::Internal
        );
        assert_eq!(shell.active_chat, "peer-b");
        assert_eq!(
            shell.state.read(cx).selected_chat.as_deref(),
            Some("peer-b")
        );
        assert_eq!(shell.transcript.entity_id(), peer_b);
        assert_eq!(
            shell.peer_chat_views["peer-a"].transcript.entity_id(),
            peer_a
        );
        let split = shell.chat_split.as_ref().unwrap();
        assert_eq!(
            split.focus, 1,
            "promote the source, not the first available peer"
        );
        assert_eq!(split.panes, vec![Some("peer-a".into()), None, None]);
        assert_eq!(split.drafts[2].as_ref(), Some(&draft));
        assert!(!shell.right_tabs.contains_key(""));
        assert!(!shell.right_tabs.contains_key("peer-a"));
        assert_eq!(shell.right_tabs["peer-b"].len(), 1);
        let first = shell.browser_seq;

        let layout = shell.chat_split.clone();
        assert_eq!(
            shell.activate_session_link(&link, window, cx),
            LinkOutcome::Internal
        );
        assert_ne!(shell.browser_seq, first);
        assert_eq!(shell.right_tabs["peer-b"].len(), 2);
        assert_eq!(
            shell.chat_split, layout,
            "repeat activation must not park the draft again"
        );

        assert!(shell.select_chat_pane(2, cx));
        shell.on_state_changed(&shell.state.clone(), cx);
        assert!(shell.active_chat.is_empty());
        assert!(shell.state.read(cx).selected_chat.is_none());
        assert_eq!(shell.current_canvas_draft(cx), draft);
        assert_eq!(shell.right_tabs["peer-b"].len(), 2);
        assert!(!shell.right_pane_open(cx));
    });
}
