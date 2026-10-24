//! Blocks the main thread inside an action for a while and prints what gets
//! logged, with the stall watch on (default) or off (`off`): the shape of a
//! #342 freeze, without real data. Stack samples go to a temporary folder.
//!
//! `cargo run -p harness-ui --features stall-watch-fixture --example stall-watch-fixture -- [off] [seconds]`
use std::time::Duration;

use gpui::{
    AppContext as _, Bounds, Context, IntoElement, ParentElement as _, Render, Styled as _, Window,
    WindowBounds, WindowOptions, div, px, size,
};

gpui::actions!(stall_fixture, [RunLongImport]);

struct Fixture;

impl Render for Fixture {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child("stall watch fixture")
    }
}

fn main() {
    tracing_subscriber::fmt()
        .with_target(false)
        .with_ansi(false)
        .without_time()
        .init();
    let mut args = std::env::args().skip(1);
    let mut watch = true;
    let mut block = Duration::from_secs(15);
    for arg in args.by_ref() {
        match arg.as_str() {
            "off" => watch = false,
            secs => block = Duration::from_secs(secs.parse().expect("seconds")),
        }
    }
    let logs = tempfile::tempdir().expect("temporary logs folder");
    let logs_path = logs.path().to_path_buf();
    gpui_platform::application().run(move |cx| {
        if watch {
            harness_ui::stall_watch::start(logs_path.clone(), cx);
        }
        cx.on_action(move |_: &RunLongImport, _| {
            tracing::info!(
                "fixture: an action blocks the main thread for {}s",
                block.as_secs()
            );
            std::thread::sleep(block);
        });
        let window = cx
            .open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds::centered(
                        None,
                        size(px(360.), px(120.)),
                        cx,
                    ))),
                    ..Default::default()
                },
                |_, cx| cx.new(|_| Fixture),
            )
            .expect("window");
        cx.spawn(async move |cx| {
            cx.background_executor().timer(Duration::from_secs(2)).await;
            window
                .update(cx, |_, window, cx| {
                    window.dispatch_action(Box::new(RunLongImport), cx)
                })
                .ok();
            tracing::info!("fixture: main thread free again");
            // The stack sample runs on its own thread; give it time to land.
            cx.background_executor().timer(Duration::from_secs(6)).await;
            let samples = std::fs::read_dir(&logs_path)
                .map(|entries| entries.flatten().count())
                .unwrap_or(0);
            tracing::info!("fixture: {samples} stack sample file(s) in the logs folder");
            let _ = std::fs::remove_dir_all(&logs_path);
            cx.update(|cx| cx.quit());
        })
        .detach();
    });
    drop(logs);
}
