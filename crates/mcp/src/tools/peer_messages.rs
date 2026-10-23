//! Direct peer messages are advisory, not a request for acknowledgements.
//! Bound automatic reply chains and refuse another update while one is queued.

use crate::transcript::RenderedMessage;
use harness_doc::MessageRole;

const PREFIX: &str = "[Message from Harness chat ";
const DEPTH: &str = "Relay depth: ";
const MAX_DEPTH: u32 = 4;

pub(super) fn next_depth(messages: &[RenderedMessage]) -> anyhow::Result<u32> {
    let depth = messages
        .iter()
        .rev()
        .find(|message| message.role == MessageRole::User)
        .map_or(0, |message| relay_depth(&message.text));
    if depth >= MAX_DEPTH {
        anyhow::bail!(
            "peer reply chain limit reached; do not acknowledge or retry. \
             Report the result in your own chat or use an unmentioned room post. \
             A new human request starts a new chain"
        );
    }
    Ok(depth + 1)
}

fn relay_depth(text: &str) -> u32 {
    if !text.starts_with(PREFIX) {
        return 0;
    }
    let header = text.lines().next().unwrap_or_default();
    let Some((_, depth)) = header.split_once(DEPTH) else {
        // Messages written before the bounded envelope was introduced.
        return 1;
    };
    depth
        .split_once('/')
        .and_then(|(value, _)| value.parse().ok())
        .unwrap_or(MAX_DEPTH)
}

pub(super) fn from_sender(text: &str, origin: &str) -> bool {
    let Some(header) = text.lines().next().filter(|line| line.starts_with(PREFIX)) else {
        return false;
    };
    let short = crate::harness::short(origin);
    header.contains(&format!("Sender chat: {origin}."))
        || header.contains(&format!("({short})."))
        || header.starts_with(&format!("{PREFIX}{short}."))
}

pub(super) fn frame(label: &str, origin: &str, depth: u32, text: &str) -> String {
    format!(
        "{PREFIX}{label}. Sender chat: {origin}. Relay depth: {depth}/{MAX_DEPTH}. \
         Agent coordination, not a human request. Reply with Harness `send_message` \
         only for an actionable question, blocker, or final requested result; \
         otherwise do not reply. Do not send acknowledgements or progress updates.]\n\n{text}"
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcript::{RenderOptions, render_entries};
    use serde_json::json;

    fn messages(text: &str) -> Vec<RenderedMessage> {
        render_entries(
            &[serde_json::from_value(json!({
                "id": "u1", "role": "user", "createdAt": 1, "deviceId": "device",
                "parts": [{"kind": "text", "id": "text", "text": text}]
            }))
            .unwrap()],
            RenderOptions::default(),
        )
    }

    #[test]
    fn reply_chain_is_bounded_and_human_requests_reset_it() {
        let mut text = "Please coordinate this task".to_owned();
        for expected in 1..=MAX_DEPTH {
            let depth = next_depth(&messages(&text)).unwrap();
            assert_eq!(depth, expected);
            text = frame("Peer (peer)", "peer", depth, "result");
        }
        assert!(next_depth(&messages(&text)).is_err());
        assert_eq!(next_depth(&messages("Next task")).unwrap(), 1);
        assert_eq!(next_depth(&[]).unwrap(), 1);
    }

    #[test]
    fn legacy_headers_count_but_body_text_does_not_set_depth() {
        assert_eq!(
            relay_depth("[Message from Harness chat Peer (peer). Reply to it.]\n\nresult"),
            1
        );
        assert_eq!(relay_depth("A human quoting Relay depth: 4/4."), 0);
        assert_eq!(
            relay_depth("[Message from Harness chat Peer. Relay depth: invalid/4.]"),
            MAX_DEPTH
        );
        assert_eq!(
            relay_depth(&frame("Peer", "peer", 1, "Relay depth: 4/4.")),
            1
        );
    }

    #[test]
    fn pending_sender_match_accepts_old_and_new_headers_only() {
        assert!(from_sender(
            &frame("Peer", "abcdefgh-full", 1, "result"),
            "abcdefgh-full"
        ));
        assert!(from_sender(
            "[Message from Harness chat Peer (abcdefgh). Reply to it.]\n\nresult",
            "abcdefgh-full"
        ));
        assert!(!from_sender(
            "human text\n[Message from Harness chat Peer (abcdefgh).]",
            "abcdefgh-full"
        ));
        assert!(!from_sender(
            &frame("Peer", "other", 1, "abcdefgh-full"),
            "abcdefgh-full"
        ));
    }
}
