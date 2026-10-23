//! Isolated native visual demo inside the production Harness shell and transcript.
//!
//! Interactive (stays open):
//!   cargo run -p harness-ui --example visuals-fixture --features appshots-fixture
//! Capture real handler changes and exit:
//!   cargo run -p harness-ui --example visuals-fixture --features appshots-fixture -- --capture target/visuals-dev/captures
//! Add --light for a light-theme capture. Uses only synthetic, isolated local data.
use gpui::{AppContext, AsyncApp, Bounds, WindowBounds, WindowOptions, px, size};
use harness_ui::*;
use harness_visual::Input;
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};

async fn pause(cx: &mut AsyncApp, ms: u64) {
    cx.background_executor()
        .timer(Duration::from_millis(ms))
        .await;
}

async fn ready(cx: &mut AsyncApp) -> anyhow::Result<gpui::Entity<visuals::VisualView>> {
    for _ in 0..200 {
        if let Some(view) = cx.update(|cx| visuals::fixture_view(cx)) {
            let status = view.read_with(cx, |view, _| {
                (view.is_busy(), view.error().map(str::to_owned))
            });
            if let Some(error) = status.1 {
                anyhow::bail!("Native visual failed: {error}");
            }
            if !status.0 {
                return Ok(view);
            }
        }
        pause(cx, 25).await;
    }
    anyhow::bail!("Native visual did not become ready within five seconds")
}

fn fingerprint(view: &gpui::Entity<visuals::VisualView>, cx: &AsyncApp) -> String {
    view.read_with(cx, |view, _| format!("{:?}", view.snapshot()))
}

fn capture(
    window: gpui::AnyWindowHandle,
    cx: &mut AsyncApp,
    output: &std::path::Path,
    name: &str,
) -> anyhow::Result<()> {
    window.update(cx, |_, window, cx| -> anyhow::Result<()> {
        window.draw(cx).clear();
        window
            .render_to_image()?
            .save(output.join(format!("{name}.png")))?;
        Ok(())
    })??;
    Ok(())
}

fn port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().with_env_filter("warn").init();
    let args: Vec<String> = std::env::args().skip(1).collect();
    let light = args.iter().any(|arg| arg == "--light");
    let output = args
        .iter()
        .position(|arg| arg == "--capture")
        .map(|index| {
            args.get(index + 1)
                .map(PathBuf::from)
                .ok_or_else(|| anyhow::anyhow!("--capture requires an output directory"))
        })
        .transpose()?;
    if let Some(output) = &output {
        std::fs::create_dir_all(output)?;
    }
    let data = std::env::var_os("HARNESS_VISUALS_DATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("target/visuals-dev/data"));
    std::fs::create_dir_all(&data)?;
    let engine_data = std::env::var_os("HARNESS_VISUALS_ENGINE_DATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| data.join("engine"));
    let replay_chat = std::env::var("HARNESS_VISUALS_CHAT").ok();
    let runtime = tokio::runtime::Runtime::new()?;
    let core = runtime.block_on(async {
        harness_engine::EngineCore::assemble(
            &engine_data,
            Arc::new(harness_engine::default_registry()),
            harness_proto::HarnessId::Graff,
            None,
        )
    })?;
    let chat = replay_chat.as_deref().unwrap_or("native-visuals-demo");
    if !core
        .workspace
        .read_chats()?
        .iter()
        .any(|entry| entry.id == chat)
    {
        anyhow::ensure!(replay_chat.is_none(), "Replay conversation does not exist");
        core.workspace.create_chat(
            chat,
            None,
            Some(&core.device_id),
            Some(serde_json::from_value(serde_json::json!({
                "harness": "graff", "model": null, "reasoning": null,
                "modelOptions": {}, "sandbox": "workspace-write"
            }))?),
            None,
        )?;
    }
    let replay_entries = if replay_chat.is_some() {
        Some(runtime.block_on(async {
            let handle = core.doc_host.open_local(chat)?;
            Ok::<_, anyhow::Error>(handle.doc().read_entries()?)
        })?)
    } else {
        core.workspace
            .rename_chat(chat, "Capacity planning · native visual")?;
        None
    };
    let chat = chat.to_owned();
    let ipc_port = port();
    let _ipc = runtime.block_on(harness_engine::serve_ipc(ipc_port, core.rpc_service()))?;
    let ui_data = data.join("ui");
    std::fs::create_dir_all(&ui_data)?;
    let boot = EngineBootConfig {
        data_dir: ui_data.clone(),
        ipc_port,
        edge_url: String::new(),
        edge_token: None,
        org_id: None,
        codegraff_client_id: None,
        default_harness: harness_proto::HarnessId::Graff,
    };
    let handle = runtime.block_on(state::EngineHandle::bootstrap(boot.clone()))?;
    let chats = core.workspace.read_chats()?;
    let device = core.device_id.clone();
    let failure = Arc::new(Mutex::new(None));
    let result = failure.clone();
    gpui_platform::application().with_assets(icons::Assets).run(move |cx| {
        gpui_tokio::init(cx);
        gpui_base::init(cx);
        let settings = settings::UiSettings::default();
        settings::init(settings.clone(), ui_data.clone(), cx);
        let fonts = typography::register_fonts(cx);
        typography::init(
            settings.ui_font_family.clone(), settings.ui_font_size,
            settings.terminal_font_family.clone(), settings.terminal_font_size,
            settings.code_font_family.clone(), settings.code_font_size, fonts, cx,
        );
        theme_library::init(ui_data.clone(), cx);
        appearance::init(
            if light { appearance::AppearanceMode::Light } else { appearance::AppearanceMode::Dark },
            settings.theme_selection, settings.accent, settings.surface, cx,
        );
        history::init(settings.git_history_columns, settings.git_history_column_widths,
            settings.git_history_column_order, settings.git_history_author_display, cx);
        composer::init(cx, settings.composer_send_behavior);
        terminal::panel::init(cx);
        app_menus::init(cx);
        let state = cx.new(|_| {
            let mut state = state::AppState::new();
            state.fixture_attachment_engine(handle);
            state.connection = harness_proto::view::ConnectionStatus::Ready;
            state.workspace_scope = Some(harness_proto::WorkspaceScope::Development);
            state.no_project = true;
            state.local_device_id = Some(device.clone());
            state.devices = vec![serde_json::from_value(serde_json::json!({
                "id": device, "name": "Visuals Dev", "platform": std::env::consts::OS, "lastSeenAt": null
            })).unwrap()];
            state.chats = chats;
            state.selected_chat = Some(chat.clone());
            state.auto_selected = true;
            state.chats_synced = true;
            state.spaces_synced = true;
            state
        });
        let window = cx.open_window(WindowOptions {
            titlebar: Some(gpui::TitlebarOptions { title: Some("Harness Visuals Dev".into()), ..Default::default() }),
            window_background: theme::Theme::of(cx).window_background_appearance(),
            window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                gpui::point(px(20.0), px(30.0)), size(px(1320.0), px(1100.0)),
            ))),
            ..Default::default()
        }, |_, cx| cx.new(|cx| shell::Shell::new(state.clone(), boot, cx))).unwrap();
        cx.activate(true);
        cx.spawn(async move |cx| {
            let run: anyhow::Result<()> = async {
                pause(cx, 1000).await;
                state.update(cx, |state, cx| {
                    state.receive_transcript_frame(harness_doc::TranscriptFrame::Reset {
                        reset: replay_entries.unwrap_or_else(|| serde_json::from_value(serde_json::json!([
                            { "id": "visual-user", "role": "user", "createdAt": 1788900000000_i64,
                              "deviceId": device, "parts": [{ "id": "request", "kind": "text",
                                "text": "Compare capacity plans. Let me adjust the assumptions here in chat." }] },
                            { "id": "visual-assistant", "role": "assistant", "createdAt": 1788900001000_i64,
                              "deviceId": device, "status": "complete", "parts": [
                                { "id": "intro", "kind": "text", "text": "A local, interactive scenario — synthetic estimates, not billing data." },
                                { "id": "capacity-plan", "kind": "visual", "title": "Capacity planning",
                                  "script": include_str!("visuals-demo.luau") }
                              ] }
                        ])).unwrap()),
                    }, cx).unwrap();
                    cx.notify();
                });
                window.update(cx, |shell, _, cx| shell.fixture_appshots_transcript_start(cx))?;
                let view = ready(cx).await?;
                if let Some(output) = &output {
                    pause(cx, 350).await;
                    capture(window.into(), cx, output, "visuals-before")?;
                    let before = fingerprint(&view, cx);
                    let before_values = view.read_with(cx, |view, _| chart_values(view.snapshot().unwrap()));
                    let before_revision = view.read_with(cx, |view, _| view.revision());
                    view.update(cx, |view, cx| view.interact("Capacity", Input::Number(85.0), cx))
                        .map_err(anyhow::Error::msg)?;
                    ready(cx).await?;
                    let after_values = view.read_with(cx, |view, _| chart_values(view.snapshot().unwrap()));
                    anyhow::ensure!(before_values != after_values, "Slider handler did not change native chart data");
                    view.update(cx, |view, cx| view.interact("Efficiency mode", Input::Bool(false), cx))
                        .map_err(anyhow::Error::msg)?;
                    ready(cx).await?;
                    view.update(cx, |view, cx| view.interact("Save scenario", Input::Click, cx))
                        .map_err(anyhow::Error::msg)?;
                    ready(cx).await?;
                    anyhow::ensure!(before != fingerprint(&view, cx), "Handler did not change the rendered tree");
                    let proof = view.read_with(cx, |view, _| {
                        let text = visible_text(view.snapshot().unwrap());
                        view.revision() == before_revision + 3 && text.contains("Saved scenarios: 1")
                            && text.contains("85 units") && text.contains("$2040")
                    });
                    anyhow::ensure!(proof, "Expected slider, toggle and button state was not rendered");
                    pause(cx, 200).await;
                    capture(window.into(), cx, output, "visuals-after")?;
                    println!("Native visual proof passed: slider changed chart data; toggle updated cost; button saved scenario.");
                    let _ = window.update(cx, |_, window, _| window.remove_window());
                    cx.update(|cx| cx.quit());
                }
                Ok(())
            }.await;
            if let Err(error) = run {
                eprintln!("Visuals fixture failed: {error:#}");
                *result.lock().unwrap() = Some(format!("{error:#}"));
                let _ = window.update(cx, |_, window, _| window.remove_window());
                cx.update(|cx| cx.quit());
            }
        }).detach();
    });
    runtime.block_on(core.shutdown());
    if let Some(error) = failure.lock().unwrap().take() {
        anyhow::bail!(error);
    }
    Ok(())
}

fn chart_values(node: &harness_visual::Node) -> Vec<f64> {
    if node.kind == harness_visual::Kind::Chart {
        return node.values.clone();
    }
    node.children.iter().flat_map(chart_values).collect()
}

fn visible_text(node: &harness_visual::Node) -> String {
    let mut text = node.text.clone();
    for child in &node.children {
        text.push('\n');
        text.push_str(&visible_text(child));
    }
    text
}
