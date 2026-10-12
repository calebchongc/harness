//! One `claude` process per conversation at a time.
//!
//! Replacing a run (a send with an image, a changed model) stops the old
//! process and resumes the same session in a new one. The engine counts the
//! old run as ended once it settles, which can be seconds before its child
//! has exited. A second `claude --resume` of a session that is still open
//! started half-loaded and answered the new prompt with an empty result
//! without calling the model, so the message was silently dropped. A run
//! now registers its session id while its child lives, and a resume of that
//! id waits for it to exit first (bounded, so a stuck child can't block the
//! next run for good).

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use tokio::sync::watch;

/// Longest a resume waits for the previous process: the run's interrupt and
/// kill graces plus slack.
pub(super) const WAIT: Duration = Duration::from_secs(10);

static LIVE: LazyLock<Mutex<HashMap<String, watch::Receiver<bool>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Held by a run while its child is alive. Dropping it (after the child has
/// been reaped) releases the session.
pub(super) struct Registration {
    session_id: String,
    exited: watch::Sender<bool>,
}

impl Drop for Registration {
    fn drop(&mut self) {
        let _ = self.exited.send(true);
        let mut live = LIVE.lock().unwrap_or_else(|e| e.into_inner());
        // Only our own entry: a newer process may have registered since.
        if live
            .get(&self.session_id)
            .is_some_and(|rx| rx.same_channel(&self.exited.subscribe()))
        {
            live.remove(&self.session_id);
        }
    }
}

/// Mark `session_id` as having a live process.
pub(super) fn register(session_id: &str) -> Registration {
    let (exited, rx) = watch::channel(false);
    LIVE.lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(session_id.to_string(), rx);
    Registration {
        session_id: session_id.to_string(),
        exited,
    }
}

/// Wait until no process has `session_id` open, at most `limit`. Returns
/// whether the session was free in time.
pub(super) async fn wait_until_closed(session_id: &str, limit: Duration) -> bool {
    let rx = LIVE
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(session_id)
        .cloned();
    let Some(mut rx) = rx else {
        return true;
    };
    tokio::time::timeout(limit, rx.wait_for(|exited| *exited))
        .await
        .is_ok_and(|r| r.is_ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_resume_waits_for_the_previous_process_to_exit() {
        assert!(wait_until_closed("s-free", Duration::from_millis(10)).await);

        let held = register("s-held");
        assert!(!wait_until_closed("s-held", Duration::from_millis(50)).await);

        let waiter = tokio::spawn(async { wait_until_closed("s-held", WAIT).await });
        tokio::time::sleep(Duration::from_millis(30)).await;
        drop(held);
        assert!(waiter.await.unwrap());
        assert!(wait_until_closed("s-held", Duration::from_millis(10)).await);
    }

    #[tokio::test]
    async fn an_older_run_never_releases_a_newer_ones_entry() {
        let old = register("s-twice");
        let new = register("s-twice");
        drop(old);
        assert!(!wait_until_closed("s-twice", Duration::from_millis(30)).await);
        drop(new);
        assert!(wait_until_closed("s-twice", Duration::from_millis(10)).await);
    }
}
