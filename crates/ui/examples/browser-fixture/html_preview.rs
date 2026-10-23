//! Real native-host isolation test. No model, login, or engine connection.
use super::*;
use gpui::{Entity, WindowHandle};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

async fn wait(page: &Entity<browser::BrowserSurface>, cx: &mut AsyncApp) -> anyhow::Result<()> {
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    loop {
        let state = page.read_with(cx, |p, _| p.page.clone());
        anyhow::ensure!(
            state.error.is_none(),
            "native preview failed: {:?}",
            state.error
        );
        anyhow::ensure!(!state.title.starts_with("preview:fail:"), "{}", state.title);
        if state.title == "preview:pass" {
            return Ok(());
        }
        anyhow::ensure!(
            std::time::Instant::now() < deadline,
            "native preview did not finish: {state:?}"
        );
        pause(cx, 40).await;
    }
}

pub(super) async fn exercise(
    window: WindowHandle<shell::Shell>,
    cx: &mut AsyncApp,
) -> anyhow::Result<()> {
    // A native HTTP sink catches subresource/navigation attempts that a stub JS
    // environment cannot detect. This receives no real user data.
    let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
    listener.set_nonblocking(true)?;
    let origin = format!("http://{}", listener.local_addr()?);
    // A running Harness daemon may discover this fixture-owned listener. Its
    // exact HEAD probe cannot be emitted by WebKit for our 127.0.0.1 origin
    // (Host and browser headers differ). Exclude only that known probe, not
    // arbitrary HEAD requests, speculative connects, or empty connections.
    let discovery_probe = format!(
        "HEAD / HTTP/1.1\r\nHost: localhost:{}\r\nConnection: close\r\n\r\n",
        listener.local_addr()?.port()
    );
    let requests = Arc::new(AtomicUsize::new(0));
    let attempts = Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
    let captured = attempts.clone();
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let counter = requests.clone();
    let stopped = stop.clone();
    let server = std::thread::spawn(move || {
        while !stopped.load(Ordering::Relaxed) {
            if let Ok((mut stream, _)) = listener.accept() {
                let _ = stream.set_read_timeout(Some(Duration::from_millis(100)));
                let mut request = [0; 512];
                let bytes = stream.read(&mut request).unwrap_or(0);
                if request[..bytes] != *discovery_probe.as_bytes() {
                    counter.fetch_add(1, Ordering::Relaxed);
                    captured.lock().unwrap().push(
                        String::from_utf8_lossy(&request[..bytes])
                            .lines()
                            .next()
                            .unwrap_or("empty TCP connection")
                            .to_owned(),
                    );
                }
                let _ = stream.write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                );
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    });
    let content = include_str!("html-preview.html").replace("{{origin}}", &origin);
    let (id, page) = window.update(cx, |shell, w, cx| shell.fixture_open_browser(None, w, cx))?;
    let result: anyhow::Result<()> = async {
        window
            .update(cx, |_, w, cx| {
                page.update(cx, |p, cx| p.fixture_document(&content, w, cx))
            })?
            .map_err(anyhow::Error::msg)?;
        wait(&page, cx).await?;
        pause(cx, 500).await;
        anyhow::ensure!(
            requests.load(Ordering::Relaxed) == 0,
            "preview escaped its network policy: {:?}",
            attempts.lock().unwrap()
        );
        // Reload production document/context construction: the widget state
        // must be empty again even while an old page entity remains alive.
        window
            .update(cx, |_, w, cx| {
                page.update(cx, |p, cx| p.fixture_document(&content, w, cx))
            })?
            .map_err(anyhow::Error::msg)?;
        wait(&page, cx).await?;
        pause(cx, 500).await;
        window.update(cx, |shell, w, cx| shell.fixture_close_browser(id, w, cx))?;
        anyhow::ensure!(
            !page.read_with(cx, |p, _| p.fixture_native_visible()),
            "closed preview retained native content"
        );
        anyhow::ensure!(
            requests.load(Ordering::Relaxed) == 0,
            "reload escaped its network policy: {:?}",
            attempts.lock().unwrap()
        );
        Ok(())
    }
    .await;
    stop.store(true, Ordering::Relaxed);
    let _ = server.join();
    result
}
