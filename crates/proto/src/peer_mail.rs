//! Prompts that reached a chat through agent coordination rather than from
//! its own composer: a Harness `send_message` from another chat (the
//! `[Message from Harness chat …]` envelope) or an agent-room delivery
//! (the `<!--harness-room …-->` tag, see [`crate::room_delivery`]).
//!
//! Both envelopes are written by Harness itself, so recognizing them needs no
//! sender cooperation. Recognition is not authentication: a person can type
//! an envelope by hand, and the only effect is that their own prompt is
//! treated as peer mail (it stays silent and cannot wake an archived chat).
//!
//! Two rules use it:
//! - an archived chat takes no peer mail ([`delivery_allowed`]): it is out of
//!   the active collaboration set until a person restores or reprompts it;
//! - a turn that answered only peer mail completes without a completion
//!   alert (its [`crate::TurnOrigin`] is not human); a person's prompt
//!   anywhere in the turn makes it a human turn again.

const DIRECT_PREFIX: &str = "[Message from Harness chat ";

/// The `(sender, body)` of a Harness cross-chat `send_message` envelope, in
/// either deployed format. `None` for anything else, including an envelope
/// quoted after other text.
pub fn direct_message(text: &str) -> Option<(&str, &str)> {
    let envelope = text.strip_prefix(DIRECT_PREFIX)?;
    let (header, body) = envelope.split_once("]\n\n")?;
    // A free-form sender title can contain either format's marker. The real
    // metadata follows the title, so select the last marker across both forms.
    let current = header.rsplit_once(". Sender chat: ");
    let legacy = header.rsplit_once(". Reply to it with the Harness `send_message` tool, chat ");
    let (sender, metadata) = match (current, legacy) {
        (Some(current), Some(legacy)) if legacy.0.len() > current.0.len() => legacy,
        (Some((sender, metadata)), _) => {
            if !metadata.contains("Agent coordination, not a human request.") {
                return None;
            }
            (sender, metadata)
        }
        (_, Some(legacy)) => legacy,
        _ => return None,
    };
    // Older producers allowed multiline chat titles in the sender label.
    // Only the machine metadata must remain on one line.
    if sender.trim().is_empty() || metadata.contains(['\r', '\n']) {
        return None;
    }
    Some((sender, body))
}

/// Whether `text` arrived as agent coordination (a cross-chat message or a
/// room delivery) rather than as a person's prompt.
pub fn is_peer_mail(text: &str) -> bool {
    direct_message(text).is_some() || crate::room_delivery::is_delivery(text)
}

/// Whether a prompt may be delivered to a chat in its current archive state.
/// An archived chat refuses peer mail, so peer traffic neither starts a turn
/// in it nor restores it; a person's prompt is always delivered (and restores
/// the chat, #345).
pub fn delivery_allowed(chat_archived: bool, peer_mail: bool) -> bool {
    !(chat_archived && peer_mail)
}

/// The reason a refused peer delivery reports, to the sender and in the
/// command's resolution.
pub const ARCHIVED_REFUSAL: &str = "chat is archived: archived chats take no peer messages. \
     Do not retry; ask the person to restore the chat if it is needed again";

#[cfg(test)]
mod tests {
    use super::*;
    use crate::room_delivery::{RoomOrigin, format};

    const DIRECT: &str = "[Message from Harness chat Cleanup (abc12345). Sender chat: abc12345. \
        Relay depth: 1/4. Agent coordination, not a human request. Do not send acknowledgements \
        or progress updates.]\n\nKeep tests running.";
    const LEGACY: &str = "[Message from Harness chat Cleanup (abc12345). Reply to it with the \
        Harness `send_message` tool, chat abc12345.]\n\nKeep tests running.";

    fn room() -> String {
        format(
            &RoomOrigin {
                room_id: "room_1".into(),
                room_name: "build".into(),
                seq: 3,
                from_member: "peer".into(),
                member_kind: "harness_chat".into(),
                from_user: false,
                framed: true,
                external: false,
                from_display: None,
                from_github: None,
                from_fingerprint: None,
            },
            "done here",
        )
    }

    #[test]
    fn peer_envelopes_are_recognized_and_ordinary_prompts_are_not() {
        assert_eq!(
            direct_message(DIRECT),
            Some(("Cleanup (abc12345)", "Keep tests running."))
        );
        assert!(is_peer_mail(DIRECT));
        assert!(is_peer_mail(LEGACY));
        assert!(is_peer_mail(&room()));
        for text in [
            "Please fix this",
            "Explain this: [Message from Harness chat Cleanup. Sender chat: abc. Agent coordination, not a human request.]\n\nhello",
            "[Message from Harness chat Cleanup. Sender chat: abc.]\n\nhello",
            "<!--harness-room {not json} -->\nhi",
            "quoted <!--harness-room {} -->",
        ] {
            assert!(!is_peer_mail(text), "{text}");
        }
    }

    #[test]
    fn archived_chats_refuse_only_peer_mail() {
        assert!(delivery_allowed(false, false));
        assert!(delivery_allowed(false, true));
        assert!(delivery_allowed(true, false));
        assert!(!delivery_allowed(true, true));
    }
}
