//! What the main thread is doing right now, readable from another thread.
//!
//! A stall watchdog on a background thread can't see the main thread's stack,
//! but it can read this: the nested work the main thread entered and hasn't
//! left yet (a task by its spawn site, input dispatch, an action, a frame
//! draw), each with when it started. Content-free: spawn locations, action
//! names and event kinds only.
//!
//! Only a thread that called [`watch_current_thread`] records anything; on any
//! other thread [`enter`] is one thread-local read.

use std::{
    cell::Cell,
    fmt,
    panic::Location,
    time::{Duration, Instant},
};

use parking_lot::Mutex;

/// One level of work the watched thread is inside.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ForegroundActivity {
    /// Polling a task, by where it was spawned.
    Task(&'static Location<'static>),
    /// Dispatching a platform input event of this kind.
    Input(&'static str),
    /// Running listeners for this action.
    Action(&'static str),
    /// Drawing a window frame.
    Draw,
    /// Work an app names itself.
    Named(&'static str),
}

impl fmt::Display for ForegroundActivity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Task(location) => {
                write!(f, "task spawned at {}:{}", location.file(), location.line())
            }
            Self::Input(kind) => write!(f, "{kind} input"),
            Self::Action(name) => write!(f, "action {name}"),
            Self::Draw => f.write_str("drawing a frame"),
            Self::Named(name) => f.write_str(name),
        }
    }
}

/// Levels kept; deeper nesting is counted but not named.
const DEPTH: usize = 8;

struct Stack {
    frames: [Option<(ForegroundActivity, Instant)>; DEPTH],
    depth: usize,
}

static STACK: Mutex<Stack> = parking_lot::const_mutex(Stack {
    frames: [None; DEPTH],
    depth: 0,
});

thread_local! {
    static WATCHED: Cell<bool> = const { Cell::new(false) };
}

/// Record (or stop recording) this thread's activity. Watch one thread at a
/// time: the main thread.
pub fn watch_current_thread(watch: bool) {
    WATCHED.with(|watched| watched.set(watch));
}

/// Leaves the activity [`enter`] began when dropped.
#[must_use]
pub struct ActivityGuard {
    recorded: bool,
}

/// Mark the watched thread as inside `activity` until the guard drops.
pub fn enter(activity: ForegroundActivity) -> ActivityGuard {
    if !WATCHED.with(Cell::get) {
        return ActivityGuard { recorded: false };
    }
    let mut stack = STACK.lock();
    let depth = stack.depth;
    if let Some(slot) = stack.frames.get_mut(depth) {
        *slot = Some((activity, Instant::now()));
    }
    stack.depth = depth + 1;
    ActivityGuard { recorded: true }
}

impl Drop for ActivityGuard {
    fn drop(&mut self) {
        if !self.recorded {
            return;
        }
        let mut stack = STACK.lock();
        stack.depth = stack.depth.saturating_sub(1);
        let depth = stack.depth;
        if let Some(slot) = stack.frames.get_mut(depth) {
            *slot = None;
        }
    }
}

/// The watched thread's current activity, outermost first, each with how long
/// it has been running, and how many deeper levels weren't kept. Empty when
/// the thread is idle (or nothing is watched).
pub fn snapshot() -> (Vec<(ForegroundActivity, Duration)>, usize) {
    let now = Instant::now();
    let stack = STACK.lock();
    let frames = stack
        .frames
        .iter()
        .flatten()
        .map(|(activity, since)| (*activity, now.saturating_duration_since(*since)))
        .collect();
    (frames, stack.depth.saturating_sub(DEPTH))
}

/// What a platform input event is, without its contents.
pub(crate) fn input_kind(event: &crate::PlatformInput) -> &'static str {
    use crate::PlatformInput;
    match event {
        PlatformInput::KeyDown(_) => "key down",
        PlatformInput::KeyUp(_) => "key up",
        PlatformInput::ModifiersChanged(_) => "modifiers",
        PlatformInput::MouseDown(_) => "mouse down",
        PlatformInput::MouseUp(_) => "mouse up",
        PlatformInput::MouseMove(_) => "mouse move",
        PlatformInput::MouseExited(_) => "mouse exit",
        PlatformInput::ScrollWheel(_) => "scroll",
        PlatformInput::MousePressure(_) => "mouse pressure",
        PlatformInput::Pinch(_) => "pinch",
        PlatformInput::FileDrop(_) => "file drop",
        PlatformInput::Touch(_) => "touch",
    }
}
