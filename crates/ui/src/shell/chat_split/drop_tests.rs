//! Files dropped on an unfocused pane attach there and activate it (#488).

use super::*;
use gpui::{ExternalPaths, FileDropEvent, Point};

/// The real peer pane beside a stand-in for the focused column.
struct DropPanes(Entity<Shell>);

impl Render for DropPanes {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.0.update(cx, |shell, cx| {
            let theme = Theme::of(cx).clone();
            let split = shell.chat_split.clone().unwrap();
            div().size_full().flex().children((0..2).map(|ix| {
                let pane = if ix == split.focus {
                    div().size_full().into_any_element()
                } else {
                    shell.render_peer_chat_pane(ix, split.panes[ix].as_deref(), &theme, cx)
                };
                div()
                    .w(px(480.0))
                    .h_full()
                    .flex_none()
                    .debug_selector(move || format!("drop-column-{ix}"))
                    .child(pane)
            }))
        })
    }
}

fn with_panes(
    cx: &mut gpui::TestAppContext,
    peer: Option<&str>,
    run: impl FnOnce(Entity<Shell>, Point<Pixels>, &mut gpui::VisualTestContext),
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
    let peer = peer.map(str::to_owned);
    let (host, cx) = cx.add_window_view(|_, cx| {
        DropPanes(cx.new(|cx| {
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
            shell.chat_split = ChatSplit::split(None, SplitAxis::Horizontal, peer, None);
            shell.sync_chat_panes(cx);
            shell
        }))
    });
    cx.simulate_resize(gpui::size(px(960.0), px(640.0)));
    cx.run_until_parked();
    let shell = host.read_with(cx, |host, _| host.0.clone());
    let target = cx.debug_bounds("drop-column-0").unwrap().center();
    run(shell, target, cx);
    cx.update(|window, _| window.remove_window());
    drop(host);
    cx.run_until_parked();
}

fn image(dir: &std::path::Path) -> ExternalPaths {
    let path = dir.join("shot.png");
    std::fs::write(&path, b"not decoded while staging").unwrap();
    ExternalPaths(vec![path].into())
}

fn staged(shell: &Entity<Shell>, key: &str, cx: &mut gpui::VisualTestContext) -> usize {
    shell.read_with(cx, |shell, cx| {
        shell
            .composer
            .read(cx)
            .attachments
            .get(key)
            .map_or(0, Vec::len)
    })
}

#[gpui::test]
fn dropping_an_image_on_an_inactive_pane_attaches_it_there(cx: &mut gpui::TestAppContext) {
    for (peer, key) in [(Some("peer"), "peer"), (None, "")] {
        let files = tempfile::tempdir().unwrap();
        with_panes(cx, peer, |shell, target, cx| {
            cx.simulate_event(FileDropEvent::Entered {
                position: target,
                paths: image(files.path()),
            });
            cx.simulate_event(FileDropEvent::Submit { position: target });
            cx.run_until_parked();
            shell.read_with(cx, |shell, cx| {
                assert_eq!(shell.chat_split.as_ref().unwrap().focus, 0, "{key:?}");
                assert_eq!(shell.state.read(cx).selected_chat.as_deref(), peer);
                let composer = shell.composer.read(cx);
                assert_eq!(composer.staged().len(), 1, "the composer shows it");
                assert_eq!(composer.staged()[0].name, "shot.png");
            });
            assert_eq!(staged(&shell, key, cx), 1);
            assert_eq!(
                staged(&shell, "current", cx),
                0,
                "the old session is unchanged"
            );
        });
    }
}

#[gpui::test]
fn a_cancelled_drag_over_an_inactive_pane_changes_nothing(cx: &mut gpui::TestAppContext) {
    let files = tempfile::tempdir().unwrap();
    with_panes(cx, Some("peer"), |shell, target, cx| {
        cx.simulate_event(FileDropEvent::Entered {
            position: target,
            paths: image(files.path()),
        });
        cx.simulate_event(FileDropEvent::Pending {
            position: target + gpui::point(px(10.0), px(10.0)),
        });
        cx.simulate_event(FileDropEvent::Exited);
        cx.run_until_parked();
        shell.read_with(cx, |shell, cx| {
            assert_eq!(shell.chat_split.as_ref().unwrap().focus, 1);
            assert_eq!(
                shell.state.read(cx).selected_chat.as_deref(),
                Some("current")
            );
        });
        assert_eq!(staged(&shell, "peer", cx), 0);
        assert_eq!(staged(&shell, "current", cx), 0);
    });
}
