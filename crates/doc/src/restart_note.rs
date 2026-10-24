//! The note a run's entry carries when Harness restarted under it (a quit,
//! an update, a crash). The engine writes it as the entry's error part; the
//! transcript reads it back to pick the chip's tone. A run that picks itself
//! back up, or that waits on an answer the user can still give, gets a calm
//! notice. A run that won't resume keeps the error.

/// The run will not resume on its own (too old, out of revivals, or nothing
/// to re-send).
pub const NOT_RESUMED: &str = "Run interrupted by engine restart";

/// The run was parked on a question when Harness restarted: the question
/// stays answerable, and answering it continues the run.
pub const AWAITING_ANSWER: &str =
    "Harness restarted — answer the question to pick this run back up";

/// The run is being picked back up on its own. `updated_to` names the version
/// Harness came back as, when the restart was an update.
pub fn resuming(updated_to: Option<&str>) -> String {
    match updated_to {
        Some(version) => format!("Harness updated to v{version} — picking this run back up"),
        None => "Harness restarted — picking this run back up".to_owned(),
    }
}

/// Whether `message` is one of the calm restart notes above (rendered as a
/// notice, not an error).
pub fn is_calm(message: &str) -> bool {
    message == AWAITING_ANSWER
        || (message.starts_with("Harness restarted — ")
            || message.starts_with("Harness updated to v"))
            && message.ends_with(" — picking this run back up")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn calm_notes_are_told_apart_from_the_error() {
        assert!(is_calm(&resuming(None)));
        assert!(is_calm(&resuming(Some("0.2.135"))));
        assert!(is_calm(AWAITING_ANSWER));
        assert!(!is_calm(NOT_RESUMED));
        assert!(!is_calm("Run interrupted by engine restart — resuming"));
        assert!(!is_calm("Harness restarted the agent: exit code 1"));
        assert_eq!(
            resuming(Some("0.2.135")),
            "Harness updated to v0.2.135 — picking this run back up"
        );
    }
}
