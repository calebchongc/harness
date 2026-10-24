//! Publishing a queue row must expose its metadata and delivery gate together.
//! A commit after attaching an empty map is not a publication barrier: another
//! thread using the same document can read or drain it between field writes.

use std::sync::{Barrier, mpsc};
use std::thread;

use harness_doc::{QueueDeliveryGate, QueuedMessage, SessionDoc};
use harness_proto::TurnOrigin;

const ROUNDS: usize = 256;

#[derive(Clone, Copy, Debug)]
enum Publication {
    Push,
    Insert,
}

fn message(round: usize, gated: bool) -> QueuedMessage {
    let mut row = QueuedMessage::new(
        format!("peer-{round}"),
        format!("complete message {round}"),
        format!("device-{round}"),
    );
    row.turn_origin = TurnOrigin::Peer;
    row.attachments = vec![
        format!("uploads/{round}/image.png"),
        format!("uploads/{round}/notes.txt"),
    ];
    row.peer_chat_id = Some(format!("sender-chat-{round}"));
    row.hold_for_turn_end = true;
    row.issued_at = 1_000 + round as i64;
    row.edited_at = Some(2_000 + round as i64);
    if gated {
        row.delivery_gate = Some(if round % 2 == 0 {
            QueueDeliveryGate::Editing {
                lease_id: format!("lease-{round}"),
                owner_device_id: row.issued_by.clone(),
                owner_instance_id: format!("editor-{round}"),
                acquired_at_ms: 3_000,
                expires_at_ms: 63_000,
                base_text_hash: format!("hash-{round}"),
            }
        } else {
            QueueDeliveryGate::ReviewRequired {
                previous_lease_id: format!("lease-{round}"),
                owner_device_id: row.issued_by.clone(),
                since_ms: 3_000,
                base_text_hash: format!("hash-{round}"),
            }
        });
    }
    row
}

fn observe_and_drain(
    doc: &SessionDoc,
    expected: &QueuedMessage,
    publication: Publication,
    taken: &mut usize,
) {
    for visible in doc.read_queue().expect("read during publication") {
        // Whole-row equality checks origin, both attachments, issuedBy,
        // peerChatId, holdForTurnEnd, both timestamps and the entire gate.
        assert_eq!(
            visible, *expected,
            "partial row visible via {publication:?}"
        );
    }
    if expected.delivery_gate.is_some() {
        assert!(
            doc.take_queue_head().expect("drain gated head").is_none(),
            "gated row escaped head drain during {publication:?}"
        );
        assert!(
            doc.take_queued(&expected.id)
                .expect("take gated row by id")
                .is_none(),
            "gated row escaped explicit take during {publication:?}"
        );
    } else {
        // Exercise both public drain paths across the repetitions.
        let row = if expected.issued_at % 2 == 0 {
            doc.take_queue_head().expect("drain during publication")
        } else {
            doc.take_queued(&expected.id)
                .expect("take during publication")
        };
        if let Some(row) = row {
            assert_eq!(row, *expected, "partial row taken via {publication:?}");
            *taken += 1;
        }
    }
}

fn exercise_publication(gated: bool) {
    for publication in [Publication::Push, Publication::Insert] {
        let doc = SessionDoc::init("queue-publication").unwrap();
        let rows: Vec<_> = (0..ROUNDS).map(|round| message(round, gated)).collect();
        let start = Barrier::new(2);
        let (ready_tx, ready_rx) = mpsc::sync_channel(0);
        let (done_tx, done_rx) = mpsc::channel();

        thread::scope(|scope| {
            let doc = &doc;
            let rows = &rows;
            let start = &start;
            scope.spawn(move || {
                for row in rows {
                    // Rendezvous on every publication, not just thread startup.
                    // The next row cannot start until the observer finishes the
                    // previous one, so queue-position races are out of scope.
                    ready_tx.send(()).expect("observer ready");
                    start.wait();
                    let result = match publication {
                        Publication::Push => doc.push_queued(row),
                        Publication::Insert => doc.insert_queued(0, row),
                    };
                    done_tx.send(result).expect("observer receives result");
                }
            });
            scope.spawn(move || {
                for expected in rows {
                    ready_rx.recv().expect("producer ready");
                    start.wait();
                    let mut taken = 0;
                    loop {
                        // Poll visibility and eligibility while publication is
                        // in progress. No sleeps, error retries or ignored rows:
                        // the very first partial observation fails the test.
                        observe_and_drain(doc, expected, publication, &mut taken);
                        match done_rx.try_recv() {
                            Ok(result) => {
                                result.expect("publication must not hit ContainerDeleted");
                                break;
                            }
                            Err(mpsc::TryRecvError::Empty) => {}
                            Err(mpsc::TryRecvError::Disconnected) => {
                                panic!("producer exited during publication")
                            }
                        }
                    }
                    // Cover publication completing just after the last sample.
                    observe_and_drain(doc, expected, publication, &mut taken);
                    if gated {
                        assert_eq!(doc.read_queue().unwrap(), vec![expected.clone()]);
                        assert!(doc.remove_queued(&expected.id).unwrap());
                        assert_eq!(taken, 0);
                    } else {
                        assert_eq!(taken, 1, "published row must be taken exactly once");
                    }
                    assert!(doc.read_queue().unwrap().is_empty());
                }
            });
        });
    }
}

#[test]
fn concurrent_push_and_insert_never_expose_or_deliver_partial_metadata() {
    exercise_publication(false);
}

#[test]
fn concurrent_push_and_insert_never_deliver_a_gated_row() {
    exercise_publication(true);
}
