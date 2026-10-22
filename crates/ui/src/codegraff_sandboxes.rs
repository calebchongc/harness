//! Cloud sandbox rows for Settings → Accounts (the engine's `CodegraffSandboxes`).
//!
//! Pure row text and button rules, so the card stays a thin renderer: a paused fleet sandbox
//! can be started, a running one turned off (or, if Harness was never set up in it, set up), and
//! any of them deleted. A running sandbox costs credit until it is turned off, so
//! [`running_summary`] also drives the always-visible "Cloud sandbox running" strip.

use chrono::{DateTime, Utc};
use serde_json::Value;

/// One sandbox, as the engine sends it. Tolerant of fields added later.
#[derive(Debug, Clone, Default, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct CodegraffSandbox {
    pub id: String,
    /// `fleet` or `daytona`.
    pub provider: String,
    pub name: Option<String>,
    /// `running` | `starting` | `paused` | `stopping` | `error` (the engine's words).
    pub state: String,
    pub expires_at: Option<Value>,
    /// Harness was set up in it, so it can show up as a device.
    pub harness: bool,
    /// The name its device registers under; the gateway gives fleet sandboxes no name.
    pub device_name: Option<String>,
    /// The gateway renews its window until it is turned off. `None` when the gateway doesn't
    /// know the setting (read as off).
    pub keep_running: Option<bool>,
    /// Why the last renewal failed; it pauses when its current window ends.
    pub renew_error: Option<String>,
}

/// `enabled: false` means this build doesn't offer cloud sandboxes.
#[derive(Debug, Clone, Default, serde::Deserialize, PartialEq)]
#[serde(default)]
pub struct CodegraffSandboxes {
    pub enabled: bool,
    pub sandboxes: Vec<CodegraffSandbox>,
}

pub fn sandbox_title(sandbox: &CodegraffSandbox) -> String {
    [&sandbox.name, &sandbox.device_name]
        .into_iter()
        .flatten()
        .map(|name| name.trim())
        .find(|name| !name.is_empty())
        .unwrap_or("Cloud sandbox")
        .to_string()
}

/// Only our own (fleet) sandboxes have Harness set up in them: a paused one is started, and a
/// running one that never got Harness (a create that half-failed) is set up again.
pub fn can_start(sandbox: &CodegraffSandbox) -> bool {
    sandbox.provider == "fleet"
        && (sandbox.state == "paused" || (sandbox.state == "running" && !sandbox.harness))
}

/// The button's label and its in-progress label.
pub fn start_labels(sandbox: &CodegraffSandbox) -> (&'static str, &'static str) {
    if sandbox.state == "running" {
        ("Set up Harness", "Setting up…")
    } else {
        ("Start", "Starting…")
    }
}

pub fn can_stop(sandbox: &CodegraffSandbox) -> bool {
    sandbox.state == "running"
}

/// The turn-off button's label, its in-progress label, and what it does.
pub const TURN_OFF: (&str, &str) = ("Turn off", "Turning off…");
pub const TURN_OFF_HINT: &str = "Pauses it. Memory and files are kept; billing stops.";

/// A running fleet sandbox the gateway says will pause when its window ends can be kept
/// running again (after a failed renewal, say). Gateways that don't know the setting say
/// nothing, so nothing is offered.
pub fn can_keep_running(sandbox: &CodegraffSandbox) -> bool {
    sandbox.provider == "fleet" && sandbox.state == "running" && sandbox.keep_running == Some(false)
}

fn keeps_running(sandbox: &CodegraffSandbox) -> bool {
    sandbox.keep_running == Some(true) && renew_problem(sandbox).is_none()
}

/// The renewal failure in the app's words.
fn renew_problem(sandbox: &CodegraffSandbox) -> Option<&'static str> {
    let error = sandbox.renew_error.as_deref().map(str::trim)?;
    Some(match error {
        "" => return None,
        "insufficient_credit" | "insufficient_credits" => "Out of credit",
        "key_budget" => "Key budget reached",
        _ => "Couldn't renew",
    })
}

/// When a running sandbox stops on its own: "keeps running until you turn it off", "pauses in
/// 24 min", or a failed renewal ("Out of credit — pauses in 4 min"). `None` when unknown.
fn running_outlook(sandbox: &CodegraffSandbox, now: DateTime<Utc>) -> Option<String> {
    let lease = sandbox
        .expires_at
        .as_ref()
        .and_then(|at| lease_remaining(at, now));
    match (renew_problem(sandbox), lease) {
        (Some(problem), Some(lease)) => Some(format!("{problem} — {lease}")),
        (Some(problem), None) => Some(problem.to_string()),
        _ if keeps_running(sandbox) => Some("keeps running until you turn it off".to_string()),
        (None, lease) => lease,
    }
}

/// "Running · Harness ready · keeps running until you turn it off". Pure.
pub fn sandbox_detail(sandbox: &CodegraffSandbox, now: DateTime<Utc>) -> String {
    let mut parts = vec![match sandbox.state.as_str() {
        "running" => "Running".to_string(),
        "starting" => "Starting…".to_string(),
        // A fleet pause keeps the machine's memory and disk.
        "paused" if sandbox.provider == "fleet" => "Paused — memory and files kept".to_string(),
        "paused" => "Paused".to_string(),
        "stopping" => "Stopping…".to_string(),
        "error" => "Error".to_string(),
        other if other.is_empty() || other == "unknown" => "Unknown state".to_string(),
        other => other.to_string(),
    }];
    if sandbox.state == "running" {
        if sandbox.harness {
            parts.push("Harness ready".into());
        } else {
            parts.push("Harness not set up".into());
        }
        if let Some(outlook) = running_outlook(sandbox, now) {
            parts.push(outlook);
        }
    }
    parts.join(" · ")
}

const BILLED: &str = "Billed per second until you turn it off";

/// What the always-visible strip says while sandboxes cost credit.
#[derive(Debug, Clone, PartialEq)]
pub struct RunningSummary {
    /// "Cloud sandbox running" / "2 cloud sandboxes running".
    pub label: String,
    /// "Billed per second until you turn it off", "Pauses in 24 min", or a failed renewal.
    pub detail: String,
    /// The detail is a problem (a failed renewal): show it in the warning color.
    pub warning: bool,
    /// What "Turn off" pauses: every running sandbox.
    pub running_ids: Vec<String>,
}

/// `None` while nothing is running (or starting): the strip is hidden. Every provider counts,
/// since every running sandbox is billed. Pure.
pub fn running_summary(list: &CodegraffSandboxes, now: DateTime<Utc>) -> Option<RunningSummary> {
    if !list.enabled {
        return None;
    }
    let live: Vec<&CodegraffSandbox> = list
        .sandboxes
        .iter()
        .filter(|s| matches!(s.state.as_str(), "running" | "starting"))
        .collect();
    if live.is_empty() {
        return None;
    }
    let label = match live.len() {
        1 if live[0].state == "starting" => "Cloud sandbox starting".to_string(),
        1 => "Cloud sandbox running".to_string(),
        n => format!("{n} cloud sandboxes running"),
    };
    let running: Vec<&CodegraffSandbox> = live.iter().copied().filter(|s| can_stop(s)).collect();
    // The most pressing word wins: a failed renewal, then a window about to end, then billing.
    let problem = running
        .iter()
        .find(|s| renew_problem(s).is_some())
        .and_then(|s| running_outlook(s, now));
    let (detail, warning) = match problem {
        Some(problem) => (problem, true),
        None => match running
            .iter()
            .find(|s| !keeps_running(s))
            .and_then(|s| running_outlook(s, now))
        {
            Some(lease) if lease.starts_with("pauses") => (capitalize(&lease), false),
            _ => (BILLED.to_string(), false),
        },
    };
    Some(RunningSummary {
        label,
        detail,
        warning,
        running_ids: running.iter().map(|s| s.id.clone()).collect(),
    })
}

/// The collapsed-sidebar chip's hover text: "Cloud sandbox running — billed per second", or
/// the summary's own news ("… — Out of credit — pauses in 4 min"). Pure.
pub fn compact_tooltip(summary: &RunningSummary) -> String {
    if summary.detail == BILLED {
        format!("{} — billed per second", summary.label)
    } else {
        format!("{} — {}", summary.label, summary.detail)
    }
}

/// Anything running, starting or stopping changes on its own (billing, renewals, pauses), so
/// the list is re-read while one is. Pure.
pub fn needs_refresh(list: &CodegraffSandboxes) -> bool {
    list.enabled
        && list
            .sandboxes
            .iter()
            .any(|s| matches!(s.state.as_str(), "running" | "starting" | "stopping"))
}

fn capitalize(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

fn lease_remaining(expires_at: &Value, now: DateTime<Utc>) -> Option<String> {
    let at = match expires_at {
        Value::String(text) => DateTime::parse_from_rfc3339(text).ok()?.with_timezone(&Utc),
        Value::Number(seconds) => DateTime::from_timestamp(seconds.as_i64()?, 0)?,
        _ => return None,
    };
    let minutes = (at - now).num_minutes();
    Some(match minutes {
        m if m < 0 => "lease ended".to_string(),
        0 => "pauses in under a minute".to_string(),
        m if m < 60 => format!("pauses in {m} min"),
        m => format!("pauses in {}h {}m", m / 60, m % 60),
    })
}

#[cfg(test)]
mod tests {
    use chrono::TimeZone;

    use super::*;

    fn at(h: u32, m: u32) -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, 1, h, m, 0).unwrap()
    }

    fn sandbox(state: &str, harness: bool, expires: Option<&str>) -> CodegraffSandbox {
        CodegraffSandbox {
            id: "cnd_1".into(),
            provider: "fleet".into(),
            name: Some("Harness cloud".into()),
            state: state.into(),
            expires_at: expires.map(|e| Value::String(e.into())),
            harness,
            device_name: None,
            keep_running: None,
            renew_error: None,
        }
    }

    fn kept(expires: &str, renew_error: Option<&str>) -> CodegraffSandbox {
        CodegraffSandbox {
            keep_running: Some(renew_error.is_none()),
            renew_error: renew_error.map(str::to_owned),
            ..sandbox("running", true, Some(expires))
        }
    }

    #[test]
    fn kept_running_rows_say_so_instead_of_counting_down() {
        assert_eq!(
            sandbox_detail(&kept("2026-10-01T12:24:00Z", None), at(12, 0)),
            "Running · Harness ready · keeps running until you turn it off"
        );
        // Keep-running off on a gateway that knows it: the countdown, as before.
        let mut off = kept("2026-10-01T12:24:00Z", None);
        off.keep_running = Some(false);
        assert_eq!(
            sandbox_detail(&off, at(12, 0)),
            "Running · Harness ready · pauses in 24 min"
        );
    }

    #[test]
    fn failed_renewals_say_why_and_when_it_pauses() {
        for (error, words) in [
            ("insufficient_credit", "Out of credit"),
            ("key_budget", "Key budget reached"),
            ("fleet_unavailable", "Couldn't renew"),
            ("something_new", "Couldn't renew"),
        ] {
            assert_eq!(
                sandbox_detail(&kept("2026-10-01T12:04:00Z", Some(error)), at(12, 0)),
                format!("Running · Harness ready · {words} — pauses in 4 min"),
                "{error}"
            );
        }
        let mut no_expiry = kept("x", Some("insufficient_credit"));
        no_expiry.expires_at = None;
        assert_eq!(
            sandbox_detail(&no_expiry, at(12, 0)),
            "Running · Harness ready · Out of credit"
        );
        // A renew error wins over a keep-running flag that hasn't caught up.
        let mut both = kept("2026-10-01T12:04:00Z", Some("key_budget"));
        both.keep_running = Some(true);
        assert!(sandbox_detail(&both, at(12, 0)).ends_with("Key budget reached — pauses in 4 min"));
    }

    #[test]
    fn only_running_fleet_sandboxes_that_will_pause_offer_keep_running() {
        let mut off = kept("2026-10-01T12:04:00Z", Some("insufficient_credit"));
        assert!(can_keep_running(&off));
        off.provider = "daytona".into();
        assert!(!can_keep_running(&off));
        assert!(!can_keep_running(&kept("2026-10-01T12:04:00Z", None)));
        assert!(
            !can_keep_running(&sandbox("running", true, None)),
            "older gateways say nothing, so nothing is offered"
        );
        let mut paused = sandbox("paused", true, None);
        paused.keep_running = Some(false);
        assert!(!can_keep_running(&paused));
    }

    fn list(sandboxes: Vec<CodegraffSandbox>) -> CodegraffSandboxes {
        CodegraffSandboxes {
            enabled: true,
            sandboxes,
        }
    }

    #[test]
    fn the_strip_shows_only_while_something_runs() {
        let now = at(12, 0);
        assert_eq!(running_summary(&list(vec![]), now), None);
        assert_eq!(
            running_summary(&list(vec![sandbox("paused", true, None)]), now),
            None
        );
        let mut off = list(vec![kept("2026-10-01T12:24:00Z", None)]);
        off.enabled = false;
        assert_eq!(running_summary(&off, now), None, "feature off");
        assert!(!needs_refresh(&off));

        let one = running_summary(&list(vec![kept("2026-10-01T12:24:00Z", None)]), now).unwrap();
        assert_eq!(one.label, "Cloud sandbox running");
        assert_eq!(one.detail, "Billed per second until you turn it off");
        assert!(!one.warning);
        assert_eq!(one.running_ids, ["cnd_1"]);
    }

    #[test]
    fn the_strip_puts_the_most_pressing_word_first() {
        let now = at(12, 0);
        let mut other = kept("2026-10-01T12:24:00Z", None);
        other.id = "cnd_2".into();
        let failing = kept("2026-10-01T12:04:00Z", Some("insufficient_credit"));
        let two = running_summary(&list(vec![other.clone(), failing]), now).unwrap();
        assert_eq!(two.label, "2 cloud sandboxes running");
        assert_eq!(two.detail, "Out of credit — pauses in 4 min");
        assert!(two.warning);
        assert_eq!(two.running_ids, ["cnd_2", "cnd_1"]);

        // An older gateway: no keep-running word, so the window's end is the news.
        let old = running_summary(
            &list(vec![sandbox("running", true, Some("2026-10-01T12:24:00Z"))]),
            now,
        )
        .unwrap();
        assert_eq!(old.detail, "Pauses in 24 min");
        assert!(!old.warning);

        let starting = running_summary(&list(vec![sandbox("starting", false, None)]), now).unwrap();
        assert_eq!(starting.label, "Cloud sandbox starting");
        assert!(starting.running_ids.is_empty(), "nothing to turn off yet");
    }

    #[test]
    fn the_collapsed_chip_says_what_it_costs_or_what_is_wrong() {
        let now = at(12, 0);
        let one = running_summary(&list(vec![kept("2026-10-01T12:24:00Z", None)]), now).unwrap();
        assert_eq!(
            compact_tooltip(&one),
            "Cloud sandbox running — billed per second"
        );
        let failing = running_summary(
            &list(vec![kept(
                "2026-10-01T12:04:00Z",
                Some("insufficient_credit"),
            )]),
            now,
        )
        .unwrap();
        assert_eq!(
            compact_tooltip(&failing),
            "Cloud sandbox running — Out of credit — pauses in 4 min"
        );
    }

    #[test]
    fn the_list_is_re_read_only_while_something_can_change_on_its_own() {
        assert!(!needs_refresh(&list(vec![sandbox("paused", true, None)])));
        for state in ["running", "starting", "stopping"] {
            assert!(
                needs_refresh(&list(vec![sandbox(state, true, None)])),
                "{state}"
            );
        }
    }

    #[test]
    fn running_rows_show_harness_and_when_the_lease_ends() {
        let running = sandbox("running", true, Some("2026-10-01T12:24:00Z"));
        assert_eq!(
            sandbox_detail(&running, at(12, 0)),
            "Running · Harness ready · pauses in 24 min"
        );
        let long = sandbox("running", true, Some("2026-10-01T14:05:00Z"));
        assert!(sandbox_detail(&long, at(12, 0)).ends_with("pauses in 2h 5m"));
        let late = sandbox("running", false, Some("2026-10-01T11:00:00Z"));
        assert_eq!(
            sandbox_detail(&late, at(12, 0)),
            "Running · Harness not set up · lease ended"
        );
    }

    #[test]
    fn paused_rows_say_their_state_is_kept() {
        let paused = sandbox("paused", true, Some("2026-10-01T12:24:00Z"));
        assert_eq!(
            sandbox_detail(&paused, at(12, 0)),
            "Paused — memory and files kept"
        );
        let mut daytona = paused.clone();
        daytona.provider = "daytona".into();
        assert_eq!(sandbox_detail(&daytona, at(12, 0)), "Paused");
    }

    #[test]
    fn expiry_can_be_unix_seconds_and_bad_values_are_ignored() {
        let mut s = sandbox("running", false, None);
        s.expires_at = Some(serde_json::json!(at(12, 10).timestamp()));
        assert!(sandbox_detail(&s, at(12, 0)).ends_with("pauses in 10 min"));
        s.expires_at = Some(serde_json::json!("soon"));
        assert_eq!(
            sandbox_detail(&s, at(12, 0)),
            "Running · Harness not set up"
        );
    }

    #[test]
    fn in_between_states_have_no_buttons_and_say_what_is_happening() {
        for state in ["starting", "stopping", "error"] {
            let s = sandbox(state, false, None);
            assert!(!can_start(&s) && !can_stop(&s), "{state}");
        }
        assert_eq!(
            sandbox_detail(&sandbox("starting", false, None), at(12, 0)),
            "Starting…"
        );
        assert_eq!(
            sandbox_detail(&sandbox("stopping", false, None), at(12, 0)),
            "Stopping…"
        );
    }

    #[test]
    fn a_running_sandbox_without_harness_offers_setup_instead_of_start() {
        let unready = sandbox("running", false, None);
        assert!(can_start(&unready));
        assert_eq!(start_labels(&unready), ("Set up Harness", "Setting up…"));
        assert_eq!(
            start_labels(&sandbox("paused", true, None)),
            ("Start", "Starting…")
        );
    }

    #[test]
    fn only_startable_fleet_sandboxes_start_and_only_running_ones_stop() {
        assert!(can_start(&sandbox("paused", true, None)));
        assert!(!can_start(&sandbox("running", true, None)));
        let mut daytona = sandbox("paused", false, None);
        daytona.provider = "daytona".into();
        assert!(!can_start(&daytona));
        assert!(can_stop(&sandbox("running", true, None)));
        assert!(!can_stop(&sandbox("paused", true, None)));
    }

    #[test]
    fn titles_fall_back_and_the_engine_answer_parses() {
        let mut s = sandbox("running", true, None);
        s.name = Some("  ".into());
        assert_eq!(sandbox_title(&s), "Cloud sandbox");
        s.device_name = Some("Harness cloud ab12".into());
        assert_eq!(
            sandbox_title(&s),
            "Harness cloud ab12",
            "the gateway gives no name"
        );
        let parsed: Option<CodegraffSandboxes> = serde_json::from_value(serde_json::json!({
            "enabled": true,
            "sandboxes": [{"id": "cnd_1", "provider": "fleet", "state": "paused", "future": 1}]
        }))
        .unwrap();
        let parsed = parsed.unwrap();
        assert!(parsed.enabled);
        assert_eq!(parsed.sandboxes[0].state, "paused");
        let off: Option<CodegraffSandboxes> =
            serde_json::from_value(serde_json::json!({})).unwrap();
        assert!(!off.unwrap().enabled);
    }

    #[test]
    fn the_shared_vector_rows() {
        let vector: Value = serde_json::from_str(include_str!(
            "../../../apps/parity/vectors/cloud-sandbox.json"
        ))
        .unwrap();
        let now = DateTime::from_timestamp(vector["now"].as_i64().unwrap(), 0).unwrap();
        for case in vector["rows"].as_array().unwrap() {
            let sandbox: CodegraffSandbox =
                serde_json::from_value(case["sandbox"].clone()).unwrap();
            assert_eq!(
                sandbox_title(&sandbox),
                case["title"].as_str().unwrap(),
                "{case}"
            );
            assert_eq!(
                sandbox_detail(&sandbox, now),
                case["detail"].as_str().unwrap(),
                "{case}"
            );
            assert_eq!(
                can_start(&sandbox),
                case["canStart"].as_bool().unwrap(),
                "{case}"
            );
            assert_eq!(
                can_stop(&sandbox),
                case["canStop"].as_bool().unwrap(),
                "{case}"
            );
            if case["canStart"].as_bool().unwrap() {
                assert_eq!(
                    start_labels(&sandbox).0,
                    case["startLabel"].as_str().unwrap(),
                    "{case}"
                );
            }
        }
    }
}
