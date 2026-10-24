//! Main-thread stall watchdog (#342).
//!
//! A background thread pings the main thread once a second through a
//! foreground task. When a ping goes unanswered for [`STALL_AFTER`], it logs a
//! warning naming what the main thread is inside (gpui's
//! [`foreground_activity`]: the running task's spawn site, an action, input
//! dispatch, a frame draw) and what the window showed (route, tab and pane
//! counts, transcript size). When the main thread answers again it logs how
//! long the stall lasted. On macOS a stall that reaches [`SAMPLE_AFTER`] also
//! gets one all-thread stack sample in the logs folder, at most once per
//! [`SAMPLE_EVERY`], so the next occurrence leaves the stacks behind.
//!
//! Content-free: spawn locations, action names, event kinds and counts.
//!
//! Sleep doesn't count. `Instant` stops while the computer sleeps, and when
//! the watch thread's own one-second nap overran by more than
//! [`SUSPEND_GAP`], the process itself wasn't running: the stall clock
//! restarts rather than blaming the main thread, and a long gap is logged as
//! the whole process not running.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use futures::StreamExt as _;
use gpui::App;
use gpui::foreground_activity;

/// How often the main thread is pinged.
const PING_EVERY: Duration = Duration::from_secs(1);
/// A ping unanswered this long is a stall. Far above any frame or busy update.
const STALL_AFTER: Duration = Duration::from_secs(5);
/// A stall this long gets a stack sample (macOS).
const SAMPLE_AFTER: Duration = Duration::from_secs(10);
/// At most one stack sample this often.
const SAMPLE_EVERY: Duration = Duration::from_secs(30 * 60);
/// Stack samples kept in the logs folder.
const SAMPLES_KEPT: usize = 3;
/// The watch thread's own nap overran by this much: the process wasn't
/// running, so the main thread isn't to blame for that time.
const SUSPEND_GAP: Duration = Duration::from_secs(5);
/// A gap this long in the whole process is worth a warning of its own.
const STARVED_LOG_AFTER: Duration = Duration::from_secs(30);

const SAMPLE_PREFIX: &str = "main-thread-stall-";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Thresholds {
    pub stall_after: Duration,
    pub sample_after: Duration,
    pub suspend_gap: Duration,
    pub starved_log_after: Duration,
}

impl Default for Thresholds {
    fn default() -> Self {
        Self {
            stall_after: STALL_AFTER,
            sample_after: SAMPLE_AFTER,
            suspend_gap: SUSPEND_GAP,
            starved_log_after: STARVED_LOG_AFTER,
        }
    }
}

/// What the watch thread should do after a tick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Event {
    /// Send ping `seq` to the main thread.
    Ping(u64),
    /// The outstanding ping has waited this long: first report of this stall.
    Stalled(Duration),
    /// Still stalled, long enough for a stack sample.
    Sample(Duration),
    /// The main thread answered a ping after a reported stall.
    Resumed(Duration),
    /// The watch thread itself didn't run for this long: the whole process
    /// was stopped or starved (or the clock counts sleep on this platform).
    ProcessGap(Duration),
}

/// The watch thread's state: one outstanding ping at a time.
#[derive(Debug, Default)]
pub(crate) struct Detector {
    thresholds: Thresholds,
    next_seq: u64,
    /// The outstanding ping and since when it counts as waiting.
    outstanding: Option<(u64, Instant)>,
    /// When the stall began, for the resume report (not reset by a gap).
    stalled_since: Option<Instant>,
    reported: bool,
    sampled: bool,
    last_tick: Option<Instant>,
}

impl Detector {
    pub(crate) fn new(thresholds: Thresholds) -> Self {
        Self {
            thresholds,
            ..Self::default()
        }
    }

    /// Advance to `now`, given the newest ping the main thread answered and
    /// how long the watch thread meant to nap since the last tick.
    pub(crate) fn tick(&mut self, now: Instant, answered: u64, nap: Duration) -> Vec<Event> {
        let mut events = Vec::new();
        let gap = self
            .last_tick
            .map(|last| now.saturating_duration_since(last).saturating_sub(nap));
        self.last_tick = Some(now);
        let suspended = gap.is_some_and(|gap| gap > self.thresholds.suspend_gap);
        if let Some(gap) = gap.filter(|gap| *gap >= self.thresholds.starved_log_after) {
            events.push(Event::ProcessGap(gap));
        }
        if let Some((seq, since)) = self.outstanding {
            if answered >= seq {
                if self.reported {
                    let began = self.stalled_since.unwrap_or(since);
                    events.push(Event::Resumed(now.saturating_duration_since(began)));
                }
                self.outstanding = None;
                self.stalled_since = None;
                self.reported = false;
                self.sampled = false;
            } else if suspended {
                // The process wasn't running; start counting again.
                self.outstanding = Some((seq, now));
            } else {
                let waited = now.saturating_duration_since(since);
                if !self.reported && waited >= self.thresholds.stall_after {
                    self.reported = true;
                    self.stalled_since = Some(since);
                    events.push(Event::Stalled(waited));
                }
                if self.reported && !self.sampled && waited >= self.thresholds.sample_after {
                    self.sampled = true;
                    events.push(Event::Sample(waited));
                }
            }
        }
        if self.outstanding.is_none() {
            self.next_seq += 1;
            self.outstanding = Some((self.next_seq, now));
            events.push(Event::Ping(self.next_seq));
        }
        events
    }
}

/// What the window showed at its last render, without content.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct View {
    pub route: &'static str,
    pub tabs: usize,
    pub panes: usize,
    pub transcript_entries: usize,
    pub streaming: bool,
    pub window_active: bool,
}

static VIEW: Mutex<Option<View>> = Mutex::new(None);

/// Record what the window shows; the shell calls this as it renders.
pub(crate) fn set_view(view: View) {
    if let Ok(mut current) = VIEW.lock() {
        *current = Some(view);
    }
}

fn describe_view() -> String {
    match VIEW.lock().ok().and_then(|view| *view) {
        Some(view) => format!(
            "{} route, {} tab(s), {} pane(s), {} transcript entries{}, window {}",
            view.route,
            view.tabs,
            view.panes,
            view.transcript_entries,
            if view.streaming { ", streaming" } else { "" },
            if view.window_active {
                "active"
            } else {
                "inactive"
            },
        ),
        None => "no window rendered yet".into(),
    }
}

/// The main thread's nested work, outermost first.
pub(crate) fn describe_activity() -> String {
    let (frames, deeper) = foreground_activity::snapshot();
    if frames.is_empty() {
        return "no recorded work (an OS callback or a nested event loop)".into();
    }
    let mut out = frames
        .iter()
        .map(|(activity, running)| format!("{activity} ({:.1}s)", running.as_secs_f64()))
        .collect::<Vec<_>>()
        .join(" > ");
    if deeper > 0 {
        out.push_str(&format!(" > {deeper} more"));
    }
    out
}

fn report(event: Event, logs: Option<&Path>) {
    match event {
        Event::Ping(_) => {}
        Event::Stalled(waited) => tracing::warn!(
            waited_s = waited.as_secs_f64(),
            "main thread hasn't responded for {:.1}s; it is in: {}; view: {}",
            waited.as_secs_f64(),
            describe_activity(),
            describe_view(),
        ),
        Event::Sample(_) => {
            if let Some(logs) = logs {
                sample_stacks(logs);
            }
        }
        Event::Resumed(stalled) => tracing::warn!(
            stalled_s = stalled.as_secs_f64(),
            "main thread responded again after {:.1}s",
            stalled.as_secs_f64(),
        ),
        Event::ProcessGap(gap) => tracing::warn!(
            gap_s = gap.as_secs_f64(),
            "the whole process didn't run for {:.1}s (stopped, starved, or a sleep this platform's clock counts)",
            gap.as_secs_f64(),
        ),
    }
}

/// Start the watchdog for the calling (main) thread. `logs` is where stack
/// samples go.
pub fn start(logs: PathBuf, cx: &mut App) {
    foreground_activity::watch_current_thread(true);
    let answered = Arc::new(AtomicU64::new(0));
    let (ping_tx, mut ping_rx) = futures::channel::mpsc::unbounded::<u64>();
    let pong = answered.clone();
    cx.spawn(async move |_| {
        while let Some(seq) = ping_rx.next().await {
            pong.store(seq, Ordering::Release);
        }
    })
    .detach();
    let spawned = std::thread::Builder::new()
        .name("stall-watch".into())
        .spawn(move || {
            run(
                Detector::new(Thresholds::default()),
                PING_EVERY,
                |seq| ping_tx.unbounded_send(seq).is_ok(),
                &answered,
                |event| report(event, Some(&logs)),
            )
        });
    if let Err(err) = spawned {
        tracing::warn!(error = %err, "couldn't start the main-thread stall watch");
    }
}

/// The watch loop: tick, ping, report, nap. Returns once a ping can't be sent
/// (the app is gone).
pub(crate) fn run(
    mut detector: Detector,
    nap: Duration,
    mut ping: impl FnMut(u64) -> bool,
    answered: &AtomicU64,
    mut report: impl FnMut(Event),
) {
    loop {
        for event in detector.tick(Instant::now(), answered.load(Ordering::Acquire), nap) {
            match event {
                Event::Ping(seq) => {
                    if !ping(seq) {
                        return;
                    }
                }
                event => report(event),
            }
        }
        std::thread::sleep(nap);
    }
}

/// One all-thread stack sample of this process into `logs`, on its own thread
/// so the watch keeps ticking. macOS only; at most once per [`SAMPLE_EVERY`].
fn sample_stacks(logs: &Path) {
    #[cfg(target_os = "macos")]
    {
        static LAST: Mutex<Option<Instant>> = Mutex::new(None);
        let Ok(mut last) = LAST.lock() else { return };
        if last.is_some_and(|at| at.elapsed() < SAMPLE_EVERY) {
            return;
        }
        *last = Some(Instant::now());
        drop(last);
        let logs = logs.to_path_buf();
        let _ = std::thread::Builder::new()
            .name("stall-sample".into())
            .spawn(move || {
                if std::fs::create_dir_all(&logs).is_err() {
                    return;
                }
                let stamp = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_or(0, |since| since.as_secs());
                let name = format!("{SAMPLE_PREFIX}{stamp}.txt");
                let status = std::process::Command::new("/usr/bin/sample")
                    .arg(std::process::id().to_string())
                    .arg("3")
                    .arg("-mayDie")
                    .arg("-file")
                    .arg(logs.join(&name))
                    .stdin(std::process::Stdio::null())
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status();
                match status {
                    Ok(status) if status.success() => {
                        tracing::warn!(file = %name, "saved a stack sample of the main-thread stall to the logs folder");
                        prune_samples(&logs, SAMPLES_KEPT);
                    }
                    Ok(status) => tracing::warn!(%status, "couldn't sample the stalled process"),
                    Err(err) => tracing::warn!(error = %err, "couldn't sample the stalled process"),
                }
            });
    }
    #[cfg(not(target_os = "macos"))]
    let _ = logs;
}

/// Keep the newest `keep` stack samples in `logs`.
pub(crate) fn prune_samples(logs: &Path, keep: usize) {
    let Ok(entries) = std::fs::read_dir(logs) else {
        return;
    };
    let mut samples: Vec<PathBuf> = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with(SAMPLE_PREFIX) && name.ends_with(".txt"))
        })
        .collect();
    // Names carry a fixed-width Unix timestamp, so they sort by age.
    samples.sort();
    let excess = samples.len().saturating_sub(keep);
    for path in samples.into_iter().take(excess) {
        let _ = std::fs::remove_file(path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NAP: Duration = Duration::from_secs(1);

    fn secs(s: u64) -> Duration {
        Duration::from_secs(s)
    }

    /// Ticks once a second from `t0`, with the main thread answering every
    /// ping except during `blocked` (seconds since `t0`).
    fn drive(blocked: std::ops::Range<u64>, until: u64) -> Vec<(u64, Event)> {
        let mut detector = Detector::new(Thresholds::default());
        let t0 = Instant::now();
        let mut answered = 0;
        let mut sent = 0;
        let mut seen = Vec::new();
        for s in 0..=until {
            if !blocked.contains(&s) {
                answered = sent;
            }
            for event in detector.tick(t0 + secs(s), answered, NAP) {
                if let Event::Ping(seq) = event {
                    sent = seq;
                } else {
                    seen.push((s, event));
                }
            }
        }
        seen
    }

    #[test]
    fn a_responsive_main_thread_reports_nothing() {
        assert_eq!(drive(0..0, 120), Vec::new());
    }

    #[test]
    fn a_stall_is_reported_once_sampled_once_and_its_end_logged() {
        // Blocked from 10 s to 70 s: the ping sent at 9 s waits.
        let seen = drive(10..70, 90);
        assert_eq!(
            seen,
            vec![
                (14, Event::Stalled(secs(5))),
                (19, Event::Sample(secs(10))),
                (70, Event::Resumed(secs(61))),
            ]
        );
    }

    #[test]
    fn a_short_hitch_is_not_a_stall() {
        assert_eq!(drive(10..13, 30), Vec::new());
    }

    #[test]
    fn time_the_process_wasnt_running_is_not_blamed_on_the_main_thread() {
        let mut detector = Detector::new(Thresholds::default());
        let t0 = Instant::now();
        assert_eq!(detector.tick(t0, 0, NAP), vec![Event::Ping(1)]);
        // The watch thread's own nap overran by a minute: the process (and
        // with it the main thread) was stopped.
        assert_eq!(
            detector.tick(t0 + secs(61), 0, NAP),
            vec![Event::ProcessGap(secs(60))]
        );
        // Counting restarts at 61 s: nothing until 66 s.
        assert_eq!(
            detector.tick(t0 + secs(64), 0, Duration::from_secs(3)),
            vec![]
        );
        assert_eq!(
            detector.tick(t0 + secs(66), 0, Duration::from_secs(2)),
            vec![Event::Stalled(secs(5))]
        );
        // A short overrun is suspension but not worth its own warning.
        let mut detector = Detector::new(Thresholds::default());
        detector.tick(t0, 0, NAP);
        assert_eq!(detector.tick(t0 + secs(8), 0, NAP), vec![]);
        assert_eq!(detector.tick(t0 + secs(12), 0, NAP), vec![]);
        assert_eq!(
            detector.tick(t0 + secs(13), 0, NAP),
            vec![Event::Stalled(secs(5))]
        );
    }

    #[test]
    fn old_stack_samples_are_pruned() {
        let dir = tempfile::tempdir().unwrap();
        for stamp in [
            1_700_000_001u64,
            1_700_000_003,
            1_700_000_002,
            1_700_000_004,
        ] {
            std::fs::write(dir.path().join(format!("{SAMPLE_PREFIX}{stamp}.txt")), "").unwrap();
        }
        std::fs::write(dir.path().join("harness-desktop.log"), "").unwrap();
        prune_samples(dir.path(), 2);
        let mut left: Vec<String> = std::fs::read_dir(dir.path())
            .unwrap()
            .flatten()
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .collect();
        left.sort();
        assert_eq!(
            left,
            vec![
                "harness-desktop.log".to_string(),
                format!("{SAMPLE_PREFIX}1700000003.txt"),
                format!("{SAMPLE_PREFIX}1700000004.txt"),
            ]
        );
    }

    gpui::actions!(stall_watch_test, [Probe]);

    struct ProbeView {
        focus: gpui::FocusHandle,
        seen: Option<String>,
    }

    impl gpui::Render for ProbeView {
        fn render(
            &mut self,
            _: &mut gpui::Window,
            cx: &mut gpui::Context<Self>,
        ) -> impl gpui::IntoElement {
            use gpui::{InteractiveElement as _, ParentElement as _, Styled as _};
            gpui::div()
                .key_context("StallProbe")
                .track_focus(&self.focus)
                .size_full()
                .on_action(cx.listener(|this, _: &Probe, _, _| {
                    this.seen = Some(describe_activity());
                }))
                .child("probe")
        }
    }

    /// What the watchdog would report from inside a shortcut's handler: the
    /// input being dispatched and the action it became, outermost first.
    #[gpui::test]
    fn the_report_names_the_input_and_action_the_main_thread_is_in(cx: &mut gpui::TestAppContext) {
        use gpui::AppContext as _;
        cx.update(|cx| {
            cx.bind_keys([gpui::KeyBinding::new(
                "ctrl-shift-f12",
                Probe,
                Some("StallProbe"),
            )])
        });
        let window = cx.add_window(|_, cx| ProbeView {
            focus: cx.focus_handle(),
            seen: None,
        });
        foreground_activity::watch_current_thread(true);
        cx.update_window(window.into(), |_, window, cx| {
            let focus = window
                .root::<ProbeView>()
                .flatten()
                .unwrap()
                .read(cx)
                .focus
                .clone();
            window.focus(&focus, cx);
            window.draw(cx).clear();
            window.dispatch_event(
                gpui::PlatformInput::KeyDown(gpui::KeyDownEvent {
                    keystroke: gpui::Keystroke::parse("ctrl-shift-f12").unwrap(),
                    is_held: false,
                    prefer_character_input: false,
                }),
                cx,
            );
        })
        .unwrap();
        foreground_activity::watch_current_thread(false);
        let seen = window
            .update(cx, |view, _, _| view.seen.clone())
            .unwrap()
            .expect("the probe action ran");
        let seen = strip_durations(&seen);
        assert_eq!(seen, "key down input > action stall_watch_test::Probe");
        assert_eq!(
            describe_activity(),
            "no recorded work (an OS callback or a nested event loop)",
            "every level is left again"
        );
    }

    /// `"a (1.2s) > b (0.0s)"` → `"a > b"`.
    fn strip_durations(report: &str) -> String {
        report
            .split(" > ")
            .map(|level| level.rsplit_once(" (").map_or(level, |(name, _)| name))
            .collect::<Vec<_>>()
            .join(" > ")
    }

    /// The real loop against a thread that stops answering: the stall is
    /// reported while it lasts, and its end after.
    #[test]
    fn the_watch_loop_reports_a_blocked_responder() {
        let thresholds = Thresholds {
            stall_after: Duration::from_millis(200),
            sample_after: Duration::from_secs(3600),
            suspend_gap: Duration::from_secs(2),
            starved_log_after: Duration::from_secs(3600),
        };
        let answered = Arc::new(AtomicU64::new(0));
        let (ping_tx, ping_rx) = std::sync::mpsc::channel::<u64>();
        let responder = {
            let answered = answered.clone();
            std::thread::spawn(move || {
                let started = Instant::now();
                let mut blocked = false;
                while let Ok(seq) = ping_rx.recv() {
                    if !blocked && started.elapsed() > Duration::from_millis(300) {
                        blocked = true;
                        std::thread::sleep(Duration::from_millis(1200));
                    }
                    answered.store(seq, Ordering::Release);
                    if started.elapsed() > Duration::from_millis(2000) {
                        return;
                    }
                }
            })
        };
        let (events_tx, events_rx) = std::sync::mpsc::channel();
        run(
            Detector::new(thresholds),
            Duration::from_millis(20),
            |seq| ping_tx.send(seq).is_ok(),
            &answered,
            |event| events_tx.send(event).unwrap(),
        );
        responder.join().unwrap();
        let events: Vec<Event> = events_rx.try_iter().collect();
        assert!(
            matches!(events.as_slice(), [Event::Stalled(_), Event::Resumed(stalled)] if *stalled >= Duration::from_millis(900)),
            "{events:?}"
        );
    }
}
