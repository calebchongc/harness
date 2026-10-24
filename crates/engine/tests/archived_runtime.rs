//! #498: archive retires warm native-peer runtimes without aborting human work.
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};
use std::time::Duration;

use async_trait::async_trait;
use futures::{StreamExt, stream::BoxStream};
use harness_adapters::{Harness, HarnessError, RunControls};
use harness_doc::{MessagePart, MessageRole, MessageStatus, SessionCommandPayload};
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::{
    AgentEvent, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SessionStatus, SteeringMode, TurnOrigin,
};
use tokio::sync::mpsc;

const CHAT: &str = "archive-runtime";

fn peer_prompt(body: &str) -> String {
    format!(
        "[Message from Harness chat Fixture. Sender chat: fixture. \
         Agent coordination, not a human request.]\n\n{body}"
    )
}

#[derive(Default)]
struct PersistentHarness {
    requests: Mutex<Vec<RunRequest>>,
    feeds: Mutex<Vec<mpsc::UnboundedSender<AgentEvent>>>,
    retired: Arc<AtomicUsize>,
    before_yield: Arc<Mutex<Option<Box<dyn FnOnce() + Send>>>>,
}

#[async_trait]
impl Harness for PersistentHarness {
    fn id(&self) -> HarnessId {
        HarnessId::Mock
    }
    fn display_name(&self) -> &str {
        "Persistent archive fixture"
    }
    fn supports_steering(&self) -> bool {
        true
    }
    fn steering_mode(&self) -> SteeringMode {
        SteeringMode::TurnBoundary
    }
    fn reasoning_levels(&self) -> &[ReasoningLevel] {
        &[ReasoningLevel::Medium]
    }
    fn deterministic_turn_end(&self) -> bool {
        true
    }
    async fn models(&self) -> Result<Vec<Model>, HarnessError> {
        Ok(vec![])
    }

    async fn run(
        &self,
        request: RunRequest,
        controls: RunControls,
    ) -> Result<BoxStream<'static, Result<AgentEvent, HarnessError>>, HarnessError> {
        let (feed, mut input) = mpsc::unbounded_channel();
        let (output, receiver) = mpsc::unbounded_channel();
        output
            .send(Ok(AgentEvent::SessionStarted {
                harness: HarnessId::Mock,
                model: "fixture".into(),
                tools: vec![],
                cwd: request.cwd.clone(),
                session_id: "persistent-session".into(),
                assistant_message_id: uuid::Uuid::new_v4().to_string(),
            }))
            .unwrap();
        self.requests.lock().unwrap().push(request);
        self.feeds.lock().unwrap().push(feed);
        let retired = self.retired.clone();
        tokio::spawn(async move {
            // Keep the steering mailbox and simulated peer runtime alive until
            // the host retires them, as a persistent ACP process would.
            let _steering = controls.steering;
            loop {
                tokio::select! {
                    biased;
                    _ = controls.interrupt.cancelled() => {
                        retired.fetch_add(1, Ordering::SeqCst);
                        break;
                    }
                    event = input.recv() => match event {
                        Some(event) => {
                            if output.send(Ok(event)).is_err() {
                                break;
                            }
                        }
                        None => break,
                    },
                }
            }
        });
        let before_yield = self.before_yield.clone();
        Ok(futures::stream::unfold(
            (receiver, before_yield),
            |(mut receiver, hook)| async move {
                let event = receiver.recv().await?;
                if let Some(before_yield) = hook.lock().unwrap().take() {
                    before_yield();
                }
                Some((event, (receiver, hook)))
            },
        )
        .boxed())
    }
}

async fn wait_for(mut condition: impl FnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(10), async {
        while !condition() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("archive lifecycle must settle");
}

fn payload(cwd: &str, message_id: &str) -> SessionCommandPayload {
    SessionCommandPayload::Run {
        message_id: message_id.into(),
        request: RunRequest {
            turn_origin: Default::default(),
            prompt: "human task".into(),
            harness: Some(HarnessId::Mock),
            model: None,
            reasoning: None,
            model_options: Default::default(),
            cwd: cwd.into(),
            sandbox: SandboxLevel::WorkspaceWrite,
            auto_approve: false,
            attachments: vec![],
            worktree: None,
            resume: None,
        },
    }
}

fn done() -> AgentEvent {
    AgentEvent::Done {
        status: DoneStatus::Completed,
        result: None,
        error: None,
        session_id: Some("persistent-session".into()),
    }
}

async fn setup() -> (tempfile::TempDir, EngineCore, Arc<PersistentHarness>) {
    let dir = tempfile::tempdir().unwrap();
    let harness = Arc::new(PersistentHarness::default());
    let registry = HarnessRegistry::new();
    registry.register(harness.clone());
    let core = EngineCore::assemble(dir.path(), Arc::new(registry), HarnessId::Mock, None).unwrap();
    let client = harness_rpc::memory_client(core.rpc_service());
    client
        .call(
            harness_rpc::methods::MUTATE,
            serde_json::json!({
                "op": "createChat", "chatId": CHAT, "deviceId": core.device_id,
            }),
        )
        .await
        .unwrap();
    core.workspace.rename_chat(CHAT, "Archive fixture").unwrap();
    core.doc_host
        .queue_command(CHAT, payload(&dir.path().to_string_lossy(), "first"))
        .unwrap();
    wait_for(|| !harness.feeds.lock().unwrap().is_empty()).await;
    (dir, core, harness)
}

fn text(core: &EngineCore, wanted: &str) -> bool {
    core.doc_host
        .open(CHAT)
        .unwrap()
        .doc()
        .read_entries()
        .unwrap()
        .iter()
        .any(|entry| {
            entry
                .parts
                .iter()
                .any(|part| matches!(part, MessagePart::Text { text, .. } if text == wanted))
        })
}

#[tokio::test]
async fn archived_idle_runtime_retires_and_human_restore_resumes_history() {
    let (dir, core, harness) = setup().await;
    let feed = harness.feeds.lock().unwrap()[0].clone();
    feed.send(AgentEvent::TextDelta {
        text: "finished human task".into(),
    })
    .unwrap();
    feed.send(done()).unwrap();
    wait_for(|| {
        core.sessions
            .session_status(CHAT)
            .is_some_and(|s| s.status == SessionStatus::Idle)
    })
    .await;
    assert_eq!(
        harness.retired.load(Ordering::SeqCst),
        0,
        "ordinary idle stays warm"
    );

    let client = harness_rpc::memory_client(core.rpc_service());
    client
        .call(
            harness_rpc::methods::MUTATE,
            serde_json::json!({
                "op": "setChatArchived", "chatId": CHAT, "archived": true,
            }),
        )
        .await
        .unwrap();
    wait_for(|| harness.retired.load(Ordering::SeqCst) == 1).await;
    assert!(core.workspace.chat(CHAT).unwrap().unwrap().archived);
    assert!(
        feed.send(AgentEvent::TextDelta {
            text: "late peer wake".into()
        })
        .is_err()
    );
    let reference = core.doc_host.open(CHAT).unwrap();
    assert!(text(&core, "finished human task"));
    assert!(!text(&core, "late peer wake"));
    assert_eq!(
        harness.requests.lock().unwrap().len(),
        1,
        "viewing history starts nothing"
    );

    // Explicit restore alone need not spawn a model, but a later human prompt
    // starts a fresh runtime and retains the native session continuation.
    core.workspace.set_chat_archived(CHAT, false).unwrap();
    core.doc_host
        .queue_command(CHAT, payload(&dir.path().to_string_lossy(), "second"))
        .unwrap();
    wait_for(|| harness.requests.lock().unwrap().len() == 2).await;
    assert_eq!(
        harness.requests.lock().unwrap()[1].resume.as_deref(),
        Some("persistent-session")
    );
    harness.feeds.lock().unwrap()[1].send(done()).unwrap();
    wait_for(|| {
        core.sessions
            .session_status(CHAT)
            .is_some_and(|s| s.status == SessionStatus::Idle)
    })
    .await;
    assert!(!core.workspace.chat(CHAT).unwrap().unwrap().archived);
    assert!(reference.doc().read_entries().unwrap().iter().any(|entry| {
        entry.role == MessageRole::Assistant && entry.status == Some(MessageStatus::Complete)
    }));
    core.shutdown().await;
}

#[tokio::test]
async fn archive_finishes_active_human_work_but_drops_post_done_peer_output() {
    let (_dir, core, harness) = setup().await;
    let feed = harness.feeds.lock().unwrap()[0].clone();
    core.workspace.set_chat_archived(CHAT, true).unwrap();
    feed.send(AgentEvent::TextDelta {
        text: "human work after archive".into(),
    })
    .unwrap();
    wait_for(|| text(&core, "human work after archive")).await;
    assert_eq!(
        harness.retired.load(Ordering::SeqCst),
        0,
        "archive must not interrupt active work"
    );
    assert_eq!(
        core.sessions.session_status(CHAT).unwrap().status,
        SessionStatus::Working
    );

    feed.send(done()).unwrap();
    // Model the native peer-wake race: both frames are already buffered when
    // the human turn completes. The archived runtime must not unpark again.
    let _ = feed.send(AgentEvent::TextDelta {
        text: "unsolicited peer acknowledgement".into(),
    });
    wait_for(|| harness.retired.load(Ordering::SeqCst) == 1).await;
    assert!(!text(&core, "unsolicited peer acknowledgement"));
    let entries = core
        .doc_host
        .open(CHAT)
        .unwrap()
        .doc()
        .read_entries()
        .unwrap();
    let assistants: Vec<_> = entries
        .iter()
        .filter(|entry| entry.role == MessageRole::Assistant)
        .collect();
    assert_eq!(assistants.len(), 1);
    assert_eq!(assistants[0].status, Some(MessageStatus::Complete));
    assert_eq!(
        core.sessions.session_status(CHAT).unwrap().status,
        SessionStatus::Idle
    );
    assert!(core.workspace.chat(CHAT).unwrap().unwrap().archived);
    core.shutdown().await;
}

#[tokio::test]
async fn archive_retires_pending_peer_steers_but_recovers_accepted_human_prompts() {
    let (dir, core, harness) = setup().await;
    let feed = harness.feeds.lock().unwrap()[0].clone();
    // The adapter deliberately has not confirmed either mailbox message with
    // Steered yet: archive must recheck this accepted-but-undelivered work.
    for (id, peer) in [("peer-pending", true), ("human-pending", false)] {
        let SessionCommandPayload::Run { mut request, .. } =
            payload(&dir.path().to_string_lossy(), id)
        else {
            unreachable!()
        };
        request.prompt = if peer { peer_prompt(id) } else { id.into() };
        core.sessions
            .dispatch(CHAT, HarnessId::Mock, request, Some(id.into()))
            .await
            .unwrap();
    }
    assert_eq!(harness.requests.lock().unwrap().len(), 1);
    core.workspace.set_chat_archived(CHAT, true).unwrap();
    feed.send(AgentEvent::TextDelta {
        text: "original human result".into(),
    })
    .unwrap();
    feed.send(done()).unwrap();
    wait_for(|| harness.requests.lock().unwrap().len() == 2).await;
    let recovered = harness.requests.lock().unwrap()[1].clone();
    assert_eq!(recovered.prompt, "human-pending");
    assert_eq!(recovered.resume.as_deref(), Some("persistent-session"));
    assert_eq!(harness.retired.load(Ordering::SeqCst), 1);
    harness.feeds.lock().unwrap()[1].send(done()).unwrap();
    wait_for(|| harness.retired.load(Ordering::SeqCst) == 2).await;
    assert_eq!(
        harness.requests.lock().unwrap().len(),
        2,
        "peer work must not redeliver"
    );
    assert!(core.workspace.chat(CHAT).unwrap().unwrap().archived);
    core.shutdown().await;
}

/// Peer work is known by its origin, not only by the envelope text (#553):
/// an MCP send arrives as plain text tagged `TurnOrigin::Peer`, and archive
/// retirement must drop it like enveloped peer mail.
#[tokio::test]
async fn archive_retires_pending_peer_steers_known_only_by_their_origin() {
    let (dir, core, harness) = setup().await;
    let feed = harness.feeds.lock().unwrap()[0].clone();
    for (id, origin) in [
        ("plain-peer-pending", TurnOrigin::Peer),
        ("human-pending", TurnOrigin::Human),
    ] {
        let SessionCommandPayload::Run { mut request, .. } =
            payload(&dir.path().to_string_lossy(), id)
        else {
            unreachable!()
        };
        request.prompt = id.into();
        request.turn_origin = origin;
        core.sessions
            .dispatch(CHAT, HarnessId::Mock, request, Some(id.into()))
            .await
            .unwrap();
    }
    core.workspace.set_chat_archived(CHAT, true).unwrap();
    feed.send(AgentEvent::TextDelta {
        text: "original human result".into(),
    })
    .unwrap();
    feed.send(done()).unwrap();
    wait_for(|| harness.requests.lock().unwrap().len() == 2).await;
    let recovered = harness.requests.lock().unwrap()[1].clone();
    assert_eq!(recovered.prompt, "human-pending");
    assert_eq!(recovered.turn_origin, TurnOrigin::Human);
    harness.feeds.lock().unwrap()[1].send(done()).unwrap();
    wait_for(|| harness.retired.load(Ordering::SeqCst) == 2).await;
    assert_eq!(
        harness.requests.lock().unwrap().len(),
        2,
        "plain-text peer work must not redeliver into an archived chat"
    );

    // New peer work tagged only by origin is refused at the door, too.
    let mut refused = payload(&dir.path().to_string_lossy(), "late-peer");
    if let SessionCommandPayload::Run { request, .. } = &mut refused {
        request.prompt = "ordinary follow-up".into();
        request.turn_origin = TurnOrigin::Peer;
    }
    let err = core.doc_host.queue_command(CHAT, refused).unwrap_err();
    assert!(
        err.to_string()
            .contains(harness_proto::peer_mail::ARCHIVED_REFUSAL)
    );
    assert!(
        core.doc_host
            .queue_message_with_origin(
                CHAT,
                "ordinary follow-up",
                Vec::new(),
                true,
                TurnOrigin::Peer,
                None
            )
            .is_err()
    );
    assert!(core.workspace.chat(CHAT).unwrap().unwrap().archived);
    core.shutdown().await;
}

/// #499: retiring an archived chat's parked runtime is not a completion, and
/// output that races the archive cannot publish one either.
#[tokio::test]
async fn archived_runtime_retirement_publishes_no_completion() {
    let (_dir, core, harness) = setup().await;
    let feed = harness.feeds.lock().unwrap()[0].clone();
    feed.send(AgentEvent::TextDelta {
        text: "finished human task".into(),
    })
    .unwrap();
    feed.send(done()).unwrap();
    wait_for(|| {
        core.sessions
            .session_status(CHAT)
            .is_some_and(|s| s.status == SessionStatus::Idle && s.last_completed_turn.is_some())
    })
    .await;
    let completed = core.sessions.session_status(CHAT).unwrap();
    assert!(!completed.last_completed_peer_only);

    // Past the resume gate, so a frame would otherwise unpark the runtime
    // as a self-continued turn.
    tokio::time::sleep(Duration::from_millis(1200)).await;
    core.workspace.set_chat_archived(CHAT, true).unwrap();
    // A self-continued frame already in flight when the archive lands.
    let _ = feed.send(AgentEvent::TextDelta {
        text: "background result after archive".into(),
    });
    wait_for(|| harness.retired.load(Ordering::SeqCst) == 1).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    let after = core.sessions.session_status(CHAT).unwrap();
    assert_eq!(after.status, SessionStatus::Idle);
    assert_eq!(
        after.last_completed_turn, completed.last_completed_turn,
        "an archived chat's retirement publishes no new completion"
    );
    assert!(!text(&core, "background result after archive"));
    core.shutdown().await;
}

#[tokio::test]
async fn archive_at_human_steer_boundary_recovers_once_with_native_history() {
    let (dir, core, harness) = setup().await;
    let feed = harness.feeds.lock().unwrap()[0].clone();
    feed.send(AgentEvent::TextDelta {
        text: "original completed history".into(),
    })
    .unwrap();
    feed.send(done()).unwrap();
    wait_for(|| {
        core.sessions
            .session_status(CHAT)
            .is_some_and(|s| s.status == SessionStatus::Idle)
    })
    .await;

    let SessionCommandPayload::Run { mut request, .. } =
        payload(&dir.path().to_string_lossy(), "racing-human")
    else {
        unreachable!()
    };
    request.prompt = "accepted human boundary prompt".into();
    core.sessions
        .dispatch(CHAT, HarnessId::Mock, request, Some("racing-human".into()))
        .await
        .unwrap();
    assert_eq!(harness.requests.lock().unwrap().len(), 1);
    let workspace = core.workspace.clone();
    *harness.before_yield.lock().unwrap() = Some(Box::new(move || {
        workspace.set_chat_archived(CHAT, true).unwrap();
    }));
    feed.send(AgentEvent::Steered {
        assistant_message_id: None,
        next_assistant_message_id: None,
    })
    .unwrap();

    wait_for(|| harness.requests.lock().unwrap().len() == 2).await;
    let recovered = harness.requests.lock().unwrap()[1].clone();
    assert_eq!(recovered.prompt, "accepted human boundary prompt");
    assert_eq!(recovered.resume.as_deref(), Some("persistent-session"));
    assert_eq!(harness.retired.load(Ordering::SeqCst), 1);
    let recovered_feed = harness.feeds.lock().unwrap()[1].clone();
    recovered_feed
        .send(AgentEvent::TextDelta {
            text: "recovered human result".into(),
        })
        .unwrap();
    recovered_feed.send(done()).unwrap();
    wait_for(|| harness.retired.load(Ordering::SeqCst) == 2).await;
    assert_eq!(harness.requests.lock().unwrap().len(), 2);
    assert!(core.workspace.chat(CHAT).unwrap().unwrap().archived);
    assert!(text(&core, "original completed history"));
    assert!(text(&core, "recovered human result"));
    let entries = core
        .doc_host
        .open(CHAT)
        .unwrap()
        .doc()
        .read_entries()
        .unwrap();
    assert_eq!(
        entries
            .iter()
            .filter(|entry| entry.role == MessageRole::User
                && entry.parts.iter().any(|part| matches!(part,
                    MessagePart::Text { text, .. } if text == "accepted human boundary prompt")))
            .count(),
        1,
        "recovery must not duplicate the already accepted human message"
    );
    assert_eq!(
        entries
            .iter()
            .filter(|entry| entry.role == MessageRole::Assistant)
            .count(),
        2,
        "a discarded boundary must not create a phantom assistant segment"
    );
    core.shutdown().await;
}

#[tokio::test]
async fn repeated_archive_restore_cycles_keep_native_continuity_and_all_history() {
    let (dir, core, harness) = setup().await;
    for cycle in 0..3 {
        let feed = harness.feeds.lock().unwrap()[cycle].clone();
        let result = format!("human result for archive cycle {cycle}");
        feed.send(AgentEvent::TextDelta {
            text: result.clone(),
        })
        .unwrap();
        wait_for(|| text(&core, &result)).await;
        core.workspace.set_chat_archived(CHAT, true).unwrap();
        feed.send(done()).unwrap();
        wait_for(|| harness.retired.load(Ordering::SeqCst) == cycle + 1).await;
        assert!(
            feed.send(AgentEvent::TextDelta {
                text: "stale cycle output".into()
            })
            .is_err()
        );
        assert_eq!(harness.requests.lock().unwrap().len(), cycle + 1);
        assert!(core.workspace.chat(CHAT).unwrap().unwrap().archived);

        if cycle < 2 {
            // Repeated restore is idempotent; only a new human prompt launches
            // another runtime, always resuming the same native conversation.
            core.workspace.set_chat_archived(CHAT, false).unwrap();
            core.workspace.set_chat_archived(CHAT, false).unwrap();
            assert_eq!(harness.requests.lock().unwrap().len(), cycle + 1);
            core.doc_host
                .queue_command(
                    CHAT,
                    payload(
                        &dir.path().to_string_lossy(),
                        &format!("cycle-{}", cycle + 1),
                    ),
                )
                .unwrap();
            wait_for(|| harness.requests.lock().unwrap().len() == cycle + 2).await;
            assert_eq!(
                harness.requests.lock().unwrap()[cycle + 1]
                    .resume
                    .as_deref(),
                Some("persistent-session")
            );
        }
    }
    for cycle in 0..3 {
        assert!(text(
            &core,
            &format!("human result for archive cycle {cycle}")
        ));
    }
    assert!(!text(&core, "stale cycle output"));
    let entries = core
        .doc_host
        .open(CHAT)
        .unwrap()
        .doc()
        .read_entries()
        .unwrap();
    assert_eq!(
        entries
            .iter()
            .filter(|entry| entry.role == MessageRole::User)
            .count(),
        3
    );
    let assistants: Vec<_> = entries
        .iter()
        .filter(|entry| entry.role == MessageRole::Assistant)
        .collect();
    assert_eq!(assistants.len(), 3);
    assert!(
        assistants
            .iter()
            .all(|entry| entry.status == Some(MessageStatus::Complete))
    );
    core.shutdown().await;
}

#[tokio::test]
async fn archive_retirement_is_isolated_from_another_chats_active_runtime() {
    let (dir, core, harness) = setup().await;
    const OTHER: &str = "unarchived-neighbor";
    let client = harness_rpc::memory_client(core.rpc_service());
    client
        .call(
            harness_rpc::methods::MUTATE,
            serde_json::json!({
                "op": "createChat", "chatId": OTHER, "deviceId": core.device_id,
            }),
        )
        .await
        .unwrap();
    core.doc_host
        .queue_command(
            OTHER,
            payload(&dir.path().to_string_lossy(), "neighbor-first"),
        )
        .unwrap();
    wait_for(|| harness.feeds.lock().unwrap().len() == 2).await;
    let archived_feed = harness.feeds.lock().unwrap()[0].clone();
    let neighbor_feed = harness.feeds.lock().unwrap()[1].clone();
    core.workspace.set_chat_archived(CHAT, true).unwrap();
    archived_feed.send(done()).unwrap();
    wait_for(|| harness.retired.load(Ordering::SeqCst) == 1).await;

    neighbor_feed
        .send(AgentEvent::TextDelta {
            text: "neighbor continues after retirement".into(),
        })
        .unwrap();
    wait_for(|| core.doc_host.open(OTHER).unwrap().doc().read_entries().unwrap().iter().any(|entry| {
        entry.parts.iter().any(|part| matches!(part, MessagePart::Text { text, .. } if text == "neighbor continues after retirement"))
    })).await;
    assert_eq!(
        core.sessions.session_status(OTHER).unwrap().status,
        SessionStatus::Working
    );
    neighbor_feed.send(done()).unwrap();
    wait_for(|| {
        core.sessions
            .session_status(OTHER)
            .is_some_and(|s| s.status == SessionStatus::Idle)
    })
    .await;
    assert_eq!(
        harness.retired.load(Ordering::SeqCst),
        1,
        "the unarchived neighbor stays warm"
    );
    assert_eq!(harness.requests.lock().unwrap().len(), 2);
    assert!(core.workspace.chat(CHAT).unwrap().unwrap().archived);
    assert!(!core.workspace.chat(OTHER).unwrap().unwrap().archived);
    assert!(!text(&core, "neighbor continues after retirement"));
    core.shutdown().await;
}

#[tokio::test]
async fn archive_between_stream_poll_and_steer_boundary_cannot_reopen_a_parked_runtime() {
    let (dir, core, harness) = setup().await;
    let feed = harness.feeds.lock().unwrap()[0].clone();
    feed.send(done()).unwrap();
    wait_for(|| {
        core.sessions
            .session_status(CHAT)
            .is_some_and(|s| s.status == SessionStatus::Idle)
    })
    .await;
    let SessionCommandPayload::Run { mut request, .. } =
        payload(&dir.path().to_string_lossy(), "racing-peer")
    else {
        unreachable!()
    };
    request.prompt = peer_prompt("racing-peer");
    core.sessions
        .dispatch(CHAT, HarnessId::Mock, request, Some("racing-peer".into()))
        .await
        .unwrap();
    let workspace = core.workspace.clone();
    *harness.before_yield.lock().unwrap() = Some(Box::new(move || {
        // Archive after the event loop passed its pre-poll check, but before
        // the next adapter frame is returned. No sleep or scheduler luck.
        workspace.set_chat_archived(CHAT, true).unwrap();
    }));
    feed.send(AgentEvent::Steered {
        assistant_message_id: None,
        next_assistant_message_id: None,
    })
    .unwrap();
    feed.send(AgentEvent::TextDelta {
        text: "peer crossed archive boundary".into(),
    })
    .unwrap();
    feed.send(done()).unwrap();
    wait_for(|| harness.retired.load(Ordering::SeqCst) == 1).await;
    assert!(
        !text(&core, "peer crossed archive boundary"),
        "archive must be checked after polling too"
    );
    assert_eq!(harness.requests.lock().unwrap().len(), 1);
    assert!(core.workspace.chat(CHAT).unwrap().unwrap().archived);
    core.shutdown().await;
}
