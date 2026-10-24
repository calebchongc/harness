//! Turn-only interrupts for live `claude` runs (#364).
//!
//! An interrupt used to tear down the whole CLI process, and with it every
//! background task running inside the session (background subagents,
//! monitors, background shells). Claude Code's own `interrupt` control
//! request only ends the current turn; the process keeps reading stdin and
//! its background work keeps running. A run registers here, keyed by its
//! chat, so the engine can ask for exactly that
//! ([`crate::Harness::interrupt_turn`]).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use tokio::sync::mpsc;

/// Live runs that accept a turn interrupt, by chat id.
#[derive(Clone, Default)]
pub(super) struct TurnInterrupts {
    runs: Arc<Mutex<HashMap<String, mpsc::UnboundedSender<()>>>>,
}

/// Held by a run while it can take turn interrupts. Dropping it releases the
/// chat, unless a newer run has registered since.
pub(super) struct Registration {
    runs: Arc<Mutex<HashMap<String, mpsc::UnboundedSender<()>>>>,
    chat_id: String,
    tx: mpsc::UnboundedSender<()>,
}

impl Drop for Registration {
    fn drop(&mut self) {
        let mut runs = self.runs.lock().unwrap_or_else(|e| e.into_inner());
        if runs
            .get(&self.chat_id)
            .is_some_and(|tx| tx.same_channel(&self.tx))
        {
            runs.remove(&self.chat_id);
        }
    }
}

impl TurnInterrupts {
    /// Register `chat_id`'s run; its loop reads interrupts from the receiver.
    pub(super) fn register(&self, chat_id: &str) -> (Registration, mpsc::UnboundedReceiver<()>) {
        let (tx, rx) = mpsc::unbounded_channel();
        self.runs
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(chat_id.to_string(), tx.clone());
        let registration = Registration {
            runs: self.runs.clone(),
            chat_id: chat_id.to_string(),
            tx,
        };
        (registration, rx)
    }

    /// Ask `chat_id`'s live run to end its current turn. False with no live
    /// run for the chat (or one that already exited).
    pub(super) fn request(&self, chat_id: &str) -> bool {
        self.runs
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get(chat_id)
            .is_some_and(|tx| tx.send(()).is_ok())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_request_reaches_only_the_registered_run() {
        let interrupts = TurnInterrupts::default();
        assert!(!interrupts.request("chat"));
        let (registration, mut rx) = interrupts.register("chat");
        assert!(interrupts.request("chat"));
        assert_eq!(rx.try_recv(), Ok(()));
        assert!(!interrupts.request("other"));
        drop(registration);
        assert!(!interrupts.request("chat"));
    }

    #[test]
    fn an_older_run_never_releases_a_newer_ones_entry() {
        let interrupts = TurnInterrupts::default();
        let (old, _old_rx) = interrupts.register("chat");
        let (_new, mut new_rx) = interrupts.register("chat");
        drop(old);
        assert!(interrupts.request("chat"));
        assert_eq!(new_rx.try_recv(), Ok(()));
    }
}
