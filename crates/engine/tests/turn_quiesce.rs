//! Turn-quiesce watchdog + parked self-continuation, mocked against the
//! 2026-08-12 stuck-Working incident workflow (chat 15c8be78, Claude via
//! claude-agent-acp — but the failure shape is harness-agnostic):
//!
//! 1. A turn completes (Done) → the session parks Idle.
//! 2. The agent re-invokes ITSELF on a background-task notification and
//!    streams real output with no prompt behind it. The old parked gate
//!    dropped that output on the floor ("Build finished successfully…"
//!    existed in the agent's session data, was absent from harness's doc).
//! 3. A steer ("what about now") becomes the next turn — the agent answers,
//!    and the turn-end reply is LOST upstream. No Done ever arrives; the
//!    session read Working forever (the live heartbeat defeats the 45s
//!    staleness gate by design, and there is no per-turn timeout).
//!
//! The fixes under test: parked sessions RESUME on self-continued output
//! (fold it, show Working), and the quiesce watchdog settles any turn whose
//! stream goes silent after completed output with nothing in flight —
//! without ending the run, so a false trip costs a status dip, not content.

use std::sync::{Arc, Once};
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use futures::stream::BoxStream;
use tokio::sync::{Mutex, mpsc};

use harness_doc::{MessagePart, MessageRole, MessageStatus, SessionMessageEntry};
use harness_engine::{EngineCore, HarnessRegistry, SteerOutcome};
use harness_adapters::{Harness, HarnessError, RunControls};
use harness_proto::{
    AgentEvent, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SessionStatus, SteeringMode, ToolCall, TurnOrigin,
};

const CHAT: &str = "chat-quiesce";
/// Watchdog window for every test in this file (the process-global env knob
/// is set once, before any engine assembles).
const QUIESCE_MS: u64 = 300;

fn init_quiesce_env() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        // SAFETY: called before any engine (and thus any reader of the var)
        // exists in this test process; all tests share the one value.
        unsafe { std::env::set_var("HARNESS_TURN_QUIESCE_MS", QUIESCE_MS.to_string()) };
    });
}

fn run_request(prompt: &str) -> RunRequest {
    RunRequest {
        turn_origin: Default::default(),
        prompt: prompt.into(),
        harness: None,
        model: None,
        reasoning: None,
        model_options: Default::default(),
        cwd: "/tmp".into(),
        sandbox: SandboxLevel::WorkspaceWrite,
        auto_approve: true,
        attachments: Vec::new(),
        worktree: None,
        resume: None,
    }
}

fn done(status: DoneStatus) -> AgentEvent {
    AgentEvent::Done {
        status,
        result: None,
        error: None,
        session_id: Some("hs-q".into()),
    }
}

fn session_started() -> AgentEvent {
    AgentEvent::SessionStarted {
        harness: HarnessId::Mock,
        model: "mock-1".into(),
        tools: vec![],
        cwd: "/tmp".into(),
        session_id: "hs-q".into(),
        assistant_message_id: "a-q".into(),
    }
}

fn text(t: &str) -> AgentEvent {
    AgentEvent::TextDelta { text: t.into() }
}

/// Feed-by-hand harness: the test pushes events through a channel, so it can
/// model turn boundaries, self-continuation, and a LOST turn-end exactly.
/// Accepted steers are confirmed with a `Steered` boundary, like the ACP
/// adapters do. The feed is served only to the test's own dispatch (matched
/// by prompt) — the engine's auto-titler also runs this harness, and gets an
/// immediately-completed empty stream instead.
struct FeedHarness {
    main_prompt: String,
    confirm_steers: bool,
    feed: Mutex<Option<mpsc::UnboundedReceiver<AgentEvent>>>,
}

#[async_trait]
impl Harness for FeedHarness {
    fn id(&self) -> HarnessId {
        HarnessId::Mock
    }
    fn display_name(&self) -> &str {
        "Feed"
    }
    fn supports_steering(&self) -> bool {
        true
    }
    fn steering_mode(&self) -> SteeringMode {
        SteeringMode::StepBoundary
    }
    fn reasoning_levels(&self) -> &[ReasoningLevel] {
        &[ReasoningLevel::Medium]
    }
    async fn models(&self) -> Result<Vec<Model>, HarnessError> {
        Ok(vec![])
    }
    async fn run(
        &self,
        request: RunRequest,
        mut controls: RunControls,
    ) -> Result<BoxStream<'static, Result<AgentEvent, HarnessError>>, HarnessError> {
        if request.prompt != self.main_prompt {
            // The auto-titler's side run: complete instantly with nothing.
            let events = vec![Ok(done(DoneStatus::Completed))];
            return Ok(futures::stream::iter(events).boxed());
        }
        let mut feed = self
            .feed
            .lock()
            .await
            .take()
            .expect("FeedHarness serves the main dispatch once per test");
        let (tx, rx) = mpsc::channel::<Result<AgentEvent, HarnessError>>(64);
        let confirm_steers = self.confirm_steers;
        let interrupt = controls.interrupt.clone();
        tokio::spawn(async move {
            let mut steering_open = true;
            loop {
                tokio::select! {
                    // Steers first: a Steered boundary always precedes feed
                    // events the test sends after steering (determinism).
                    biased;
                    _ = interrupt.cancelled() => return,
                    steer = controls.steering.recv(), if steering_open => match steer {
                        Some(_) if confirm_steers => {
                            let boundary = AgentEvent::Steered {
                                assistant_message_id: None,
                                next_assistant_message_id: None,
                            };
                            if tx.send(Ok(boundary)).await.is_err() {
                                return;
                            }
                        }
                        Some(_) => {},
                        None => steering_open = false,
                    },
                    event = feed.recv() => match event {
                        Some(event) => {
                            if tx.send(Ok(event)).await.is_err() {
                                return;
                            }
                        }
                        None => return,
                    },
                }
            }
        });
        Ok(futures::stream::unfold(rx, |mut rx| async move {
            rx.recv().await.map(|event| (event, rx))
        })
        .boxed())
    }
}

struct Rig {
    core: EngineCore,
    feed: mpsc::UnboundedSender<AgentEvent>,
    _dir: tempfile::TempDir,
}

fn assemble(main_prompt: &str) -> Rig {
    assemble_with_confirmation(main_prompt, true)
}

fn assemble_with_confirmation(main_prompt: &str, confirm_steers: bool) -> Rig {
    init_quiesce_env();
    let (feed, rx) = mpsc::unbounded_channel();
    let registry = HarnessRegistry::new();
    registry.register(Arc::new(FeedHarness {
        main_prompt: main_prompt.into(),
        confirm_steers,
        feed: Mutex::new(Some(rx)),
    }));
    let dir = tempfile::tempdir().unwrap();
    let core = EngineCore::assemble(dir.path(), Arc::new(registry), HarnessId::Mock, None)
        .expect("engine core assembles");
    Rig {
        core,
        feed,
        _dir: dir,
    }
}

fn status(core: &EngineCore) -> Option<SessionStatus> {
    core.sessions.session_status(CHAT).map(|s| s.status)
}

/// Tolerant read (see e2e.rs): a snapshot mid-segment-write deserializes with
/// fields missing — treat that instant as "not yet".
fn entries(core: &EngineCore) -> Vec<SessionMessageEntry> {
    core.doc_host
        .open(CHAT)
        .ok()
        .and_then(|h| h.doc().read_entries().ok())
        .unwrap_or_default()
}

fn assistant_texts(core: &EngineCore) -> Vec<(String, Option<MessageStatus>)> {
    entries(core)
        .into_iter()
        .filter(|e| e.role == MessageRole::Assistant)
        .map(|e| {
            let text = e
                .parts
                .iter()
                .filter_map(|p| match p {
                    MessagePart::Text { text, .. } => Some(text.as_str()),
                    _ => None,
                })
                .collect::<Vec<_>>()
                .join("");
            (text, e.status)
        })
        .collect()
}

async fn wait_for<F>(mut predicate: F, what: &str)
where
    F: FnMut() -> bool,
{
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while !predicate() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for {what}"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

/// Steps 1+2 of the incident: a completed turn parks the session; the agent
/// then self-continues (background-task re-invocation) with no prompt. The
/// output must land in the transcript (it used to be dropped), the session
/// must read Working while it streams, and — with no Done ever coming for a
/// self-started turn — the watchdog must settle it back to Idle.
#[tokio::test]
async fn parked_self_continuation_folds_and_requiesces() {
    let rig = assemble("pull the app and benchmark it");
    rig.core
        .sessions
        .dispatch(
            CHAT,
            HarnessId::Mock,
            run_request("pull the app and benchmark it"),
            None,
        )
        .await
        .expect("dispatch");

    // Turn 1 completes normally → parked Idle.
    rig.feed.send(session_started()).unwrap();
    rig.feed.send(text("Still going, and healthy.")).unwrap();
    rig.feed.send(done(DoneStatus::Completed)).unwrap();
    wait_for(
        || status(&rig.core) == Some(SessionStatus::Idle),
        "park after Done",
    )
    .await;

    let first_completion = rig
        .core
        .sessions
        .session_status(CHAT)
        .unwrap()
        .last_completed_turn;
    assert!(first_completion.is_some());

    // Self-continuation: streamed output with NO turn behind it, arriving
    // well past the resume gate (a real one follows a whole agent round
    // trip — the incident's came five minutes after the park).
    tokio::time::sleep(Duration::from_millis(1200)).await;
    rig.feed
        .send(text("Build finished successfully. Launching the app."))
        .unwrap();
    wait_for(
        || status(&rig.core) == Some(SessionStatus::Working),
        "parked session resumes Working on self-continued output",
    )
    .await;

    // No Done will ever come for a self-started turn: the watchdog parks it.
    wait_for(
        || status(&rig.core) == Some(SessionStatus::Idle),
        "watchdog re-parks the self-continued turn",
    )
    .await;

    let second_completion = rig
        .core
        .sessions
        .session_status(CHAT)
        .unwrap()
        .last_completed_turn;
    assert!(second_completion.is_some());
    assert_ne!(
        second_completion, first_completion,
        "engine-settled background responses still advance the consumed marker"
    );

    assert!(rig.core.sessions.session_status(CHAT).unwrap().last_completed_peer_only,
        "unsolicited native wakes must not inherit completed human ownership");

    // The self-continued output is in the doc as its own COMPLETE entry —
    // this exact text was lost in the incident.
    let texts = assistant_texts(&rig.core);
    assert!(
        texts.iter().any(|(t, s)| {
            t.contains("Build finished successfully") && *s == Some(MessageStatus::Complete)
        }),
        "self-continued output must fold into a complete transcript entry, got {texts:#?}"
    );

    rig.core.sessions.shutdown().await;
}

#[tokio::test]
async fn peer_only_turns_and_later_human_turns_keep_their_own_completion_origin() {
    let rig = assemble("peer request");
    let mut request = run_request("peer request");
    request.turn_origin = TurnOrigin::Peer;
    rig.core
        .sessions
        .dispatch(CHAT, HarnessId::Mock, request, None)
        .await
        .unwrap();
    rig.feed.send(session_started()).unwrap();
    rig.feed.send(text("Acknowledged.")).unwrap();
    rig.feed.send(done(DoneStatus::Completed)).unwrap();
    wait_for(
        || status(&rig.core) == Some(SessionStatus::Idle),
        "peer completion",
    )
    .await;
    let mut previous = rig.core.sessions.session_status(CHAT).unwrap();
    assert!(previous.last_completed_peer_only);

    for origin in [TurnOrigin::Human, TurnOrigin::Peer, TurnOrigin::Human] {
        assert_eq!(
            rig.core
                .sessions
                .steer_with_origin(CHAT, "next", None, Vec::new(), origin)
                .await
                .unwrap(),
            SteerOutcome::Accepted,
        );
        wait_for(
            || status(&rig.core) == Some(SessionStatus::Working),
            "steer boundary",
        )
        .await;
        // A newly running turn must not relabel a previously consumed marker.
        let running = rig.core.sessions.session_status(CHAT).unwrap();
        assert_eq!(running.last_completed_turn, previous.last_completed_turn);
        assert_eq!(
            running.last_completed_peer_only,
            previous.last_completed_peer_only
        );
        rig.feed.send(text("Finished next request.")).unwrap();
        rig.feed.send(done(DoneStatus::Completed)).unwrap();
        wait_for(
            || status(&rig.core) == Some(SessionStatus::Idle),
            "next completion",
        )
        .await;
        let completed = rig.core.sessions.session_status(CHAT).unwrap();
        assert_ne!(completed.last_completed_turn, previous.last_completed_turn);
        assert_eq!(completed.last_completed_peer_only, origin != TurnOrigin::Human);
        previous = completed;
    }
    rig.core.sessions.shutdown().await;
}

#[tokio::test]
async fn quiesced_human_work_keeps_ownership_through_a_delayed_peer_boundary() {
    let rig = assemble_with_confirmation("human with a delayed peer", false);
    rig.core
        .sessions
        .dispatch(
            CHAT,
            HarnessId::Mock,
            run_request("human with a delayed peer"),
            None,
        )
        .await
        .unwrap();
    rig.feed.send(session_started()).unwrap();
    rig.feed
        .send(text("Human task is still being handed off."))
        .unwrap();
    assert_eq!(
        rig.core
            .sessions
            .steer_with_origin(
                CHAT,
                "peer acknowledgement",
                None,
                Vec::new(),
                TurnOrigin::Peer,
            )
            .await
            .unwrap(),
        SteerOutcome::Accepted
    );

    // No native Done or steer confirmation arrives before the watchdog.
    wait_for(
        || status(&rig.core) == Some(SessionStatus::Idle),
        "pending handoff quiesces",
    )
    .await;
    assert!(
        rig.core
            .sessions
            .session_status(CHAT)
            .unwrap()
            .last_completed_turn
            .is_none()
    );
    rig.feed
        .send(AgentEvent::Steered {
            assistant_message_id: None,
            next_assistant_message_id: Some("delayed-peer".into()),
        })
        .unwrap();
    rig.feed
        .send(text("Peer-assisted human task finished."))
        .unwrap();
    rig.feed.send(done(DoneStatus::Completed)).unwrap();
    wait_for(
        || {
            rig.core
                .sessions
                .session_status(CHAT)
                .is_some_and(|s| s.last_completed_turn.as_deref() == Some("delayed-peer"))
        },
        "handed-off completion",
    )
    .await;
    assert_eq!(
        rig.core
            .sessions
            .session_status(CHAT)
            .unwrap()
            .last_completed_peer_only,
        false,
        "quiescence must not lose the pending human completion"
    );

    // Once delivered, that human ownership must not leak into future wakes.
    tokio::time::sleep(Duration::from_millis(1200)).await;
    rig.feed
        .send(text("Unsolicited peer acknowledgement."))
        .unwrap();
    wait_for(
        || {
            rig.core.sessions.session_status(CHAT).is_some_and(|s| {
                s.last_completed_turn.as_deref() != Some("delayed-peer")
                    && s.last_completed_peer_only
            })
        },
        "later background completion stays silent",
    )
    .await;
    rig.core.sessions.shutdown().await;
}

#[tokio::test]
async fn unconfirmed_steers_publish_recoverable_origin_before_their_boundary() {
    for (parked, routed_dispatch) in [(false, false), (true, false), (false, true), (true, true)] {
        for initial in [TurnOrigin::Human, TurnOrigin::Peer, TurnOrigin::Background] {
            for incoming in [TurnOrigin::Human, TurnOrigin::Peer, TurnOrigin::Background] {
                let rig = assemble_with_confirmation("origin before boundary", false);
                let mut request = run_request("origin before boundary");
                request.turn_origin = initial;
                let run_id = rig
                    .core
                    .sessions
                    .dispatch(CHAT, HarnessId::Mock, request, Some("opening-id".into()))
                    .await
                    .unwrap();
                let journal = harness_engine::RunJournal::open(
                    rig._dir.path().join("orgs/dev-org/dev-user/journals"),
                )
                .unwrap();
                rig.feed.send(session_started()).unwrap();
                rig.feed.send(text("Original work.")).unwrap();
                wait_for(
                    || journal.last_event(CHAT).unwrap().is_some(),
                    "original stream",
                )
                .await;
                if parked {
                    rig.feed.send(done(DoneStatus::Completed)).unwrap();
                    wait_for(
                        || status(&rig.core) == Some(SessionStatus::Idle),
                        "parked origin",
                    )
                    .await;
                }
                if routed_dispatch {
                    let mut request = run_request("accepted, not confirmed");
                    request.turn_origin = incoming;
                    assert_eq!(
                        rig.core
                            .sessions
                            .dispatch(CHAT, HarnessId::Mock, request, Some("unconfirmed".into()),)
                            .await
                            .unwrap(),
                        run_id,
                        "must use the warm steering path"
                    );
                } else {
                    assert_eq!(
                        rig.core
                            .sessions
                            .steer_with_origin(
                                CHAT,
                                "accepted, not confirmed",
                                Some("unconfirmed".into()),
                                Vec::new(),
                                incoming,
                            )
                            .await
                            .unwrap(),
                        SteerOutcome::Accepted
                    );
                }
                let expected = if !parked && initial == TurnOrigin::Human {
                    TurnOrigin::Human
                } else {
                    incoming
                };
                // A process crash now recovers the latest User row, not the
                // previous assistant turn. Its notification ownership must
                // already be durable, before any Steered acknowledgement.
                assert_eq!(
                    journal.turn_origin(CHAT),
                    expected,
                    "initial={initial:?}, incoming={incoming:?}, parked={parked}, routed={routed_dispatch}"
                );
                assert_eq!(
                    journal.turn_origin_for_prompt(CHAT, "unconfirmed"),
                    expected
                );
                assert_eq!(
                    journal.turn_origin_for_prompt(CHAT, "opening-id"),
                    initial,
                    "pending provenance must be bound to its own User row"
                );
                rig.core.sessions.shutdown().await;
            }
        }
    }
}

#[tokio::test]
async fn idle_peer_acceptance_preserves_carried_human_origin_before_and_after_delayed_boundary() {
    let mut observed = Vec::new();
    for routed_dispatch in [false, true] {
        let rig = assemble_with_confirmation("human awaiting peer handoff", false);
        let run_id = rig
            .core
            .sessions
            .dispatch(
                CHAT,
                HarnessId::Mock,
                run_request("human awaiting peer handoff"),
                Some("opening-human".into()),
            )
            .await
            .unwrap();
        let journal = harness_engine::RunJournal::open(
            rig._dir.path().join("orgs/dev-org/dev-user/journals"),
        )
        .unwrap();
        rig.feed.send(session_started()).unwrap();
        // Keep the original turn active while the test thread is scheduled;
        // readiness must not race this fixture's short quiesce watchdog.
        rig.feed.send(AgentEvent::ToolCall {
            id: "handoff-in-progress".into(),
            call: ToolCall::Exec { command: "work".into() },
        }).unwrap();
        rig.feed.send(text("Human work in progress.")).unwrap();
        wait_for(
            || matches!(
                journal.last_event(CHAT).unwrap(),
                Some((_, AgentEvent::TextDelta { text })) if text == "Human work in progress."
            ),
            "original human output",
        )
        .await;
        assert_eq!(status(&rig.core), Some(SessionStatus::Working));
        assert_eq!(
            rig.core
                .sessions
                .steer_with_origin(
                    CHAT,
                    "peer A joins human work",
                    Some("peer-a".into()),
                    Vec::new(),
                    TurnOrigin::Peer,
                )
                .await
                .unwrap(),
            SteerOutcome::Accepted
        );
        assert_eq!(journal.turn_origin_for_prompt(CHAT, "peer-a"), TurnOrigin::Human);

        // The original Done is an internal handoff: A remains unconfirmed,
        // so Idle carries unfinished human work and publishes no completion.
        rig.feed.send(AgentEvent::ToolResult {
            id: "handoff-in-progress".into(),
            is_error: false,
            output: None,
            diff: None,
        }).unwrap();
        rig.feed.send(done(DoneStatus::Completed)).unwrap();
        wait_for(
            || status(&rig.core) == Some(SessionStatus::Idle),
            "original turn parks with a pending human handoff",
        )
        .await;
        assert!(
            rig.core.sessions.session_status(CHAT).unwrap().last_completed_turn.is_none()
        );

        if routed_dispatch {
            let mut request = run_request("peer B joins carried human work");
            request.turn_origin = TurnOrigin::Peer;
            assert_eq!(
                rig.core
                    .sessions
                    .dispatch(CHAT, HarnessId::Mock, request, Some("peer-b".into()))
                    .await
                    .unwrap(),
                run_id,
                "B must use the warm dispatch path"
            );
        } else {
            assert_eq!(
                rig.core
                    .sessions
                    .steer_with_origin(
                        CHAT,
                        "peer B joins carried human work",
                        Some("peer-b".into()),
                        Vec::new(),
                        TurnOrigin::Peer,
                    )
                    .await
                    .unwrap(),
                SteerOutcome::Accepted
            );
        }
        let before = journal.turn_origin_for_prompt(CHAT, "peer-b");
        rig.feed
            .send(AgentEvent::Steered {
                assistant_message_id: None,
                next_assistant_message_id: Some("delayed-peer-a".into()),
            })
            .unwrap();
        rig.feed.send(text("A boundary has been processed.")).unwrap();
        wait_for(
            || journal.replay(CHAT, 0).unwrap().iter().any(|(_, event)| matches!(
                event,
                AgentEvent::TextDelta { text } if text == "A boundary has been processed."
            )),
            "streamed output after delayed A boundary",
        )
        .await;
        let after = journal.turn_origin_for_prompt(CHAT, "peer-b");
        // B is still unconfirmed. Exercise both acceptance paths and shut
        // down before asserting, without completing B to repair its ledger.
        rig.core.sessions.shutdown().await;
        observed.push((routed_dispatch, before, after));
    }
    for (routed_dispatch, before, after) in observed {
        assert_eq!(
            before,
            TurnOrigin::Human,
            "B must inherit carried human work before A's boundary; routed_dispatch={routed_dispatch}"
        );
        assert_eq!(
            after,
            TurnOrigin::Human,
            "A's delayed boundary must preserve B's human ownership; routed_dispatch={routed_dispatch}"
        );
    }
}

/// Step 3 of the incident: a steer becomes the next turn, the agent answers,
/// and the turn-end reply is LOST. The session must not read Working forever
/// — the watchdog settles it, and the answer text survives in the doc.
#[tokio::test]
async fn missing_turn_end_settles_instead_of_working_forever() {
    let rig = assemble("pull the app and benchmark it");
    rig.core
        .sessions
        .dispatch(
            CHAT,
            HarnessId::Mock,
            run_request("pull the app and benchmark it"),
            None,
        )
        .await
        .expect("dispatch");

    rig.feed.send(session_started()).unwrap();
    rig.feed.send(text("Cloned and building.")).unwrap();
    rig.feed.send(done(DoneStatus::Completed)).unwrap();
    wait_for(
        || status(&rig.core) == Some(SessionStatus::Idle),
        "park after Done",
    )
    .await;

    // "what about now" — routed into the live run's mailbox; the harness
    // confirms it with a Steered boundary, which re-arms Working.
    let outcome = rig
        .core
        .sessions
        .steer(CHAT, "what about now", None)
        .await
        .expect("steer");
    assert!(matches!(outcome, SteerOutcome::Accepted));
    wait_for(
        || status(&rig.core) == Some(SessionStatus::Working),
        "steer boundary re-arms Working",
    )
    .await;

    // The agent answers… and its Done is lost upstream. Nothing else comes.
    rig.feed.send(text("Done — here are the results.")).unwrap();

    // Old behavior: Working forever (heartbeat keeps the row fresh; no
    // turn timeout). New behavior: the watchdog settles the turn.
    wait_for(
        || status(&rig.core) == Some(SessionStatus::Idle),
        "watchdog settles the turn whose Done was lost",
    )
    .await;
    let texts = assistant_texts(&rig.core);
    assert!(
        texts.iter().any(|(t, s)| {
            t.contains("here are the results") && *s == Some(MessageStatus::Complete)
        }),
        "the lost-Done turn's answer must still finalize in the doc, got {texts:#?}"
    );

    rig.core.sessions.shutdown().await;
}

/// The guard the design comment insists on: a long-running tool call is
/// legitimately silent for minutes — an unresolved tool part must hold the
/// watchdog off no matter how long the stream is quiet.
#[tokio::test]
async fn open_tool_call_never_quiesces() {
    let rig = assemble("run the slow build");
    rig.core
        .sessions
        .dispatch(
            CHAT,
            HarnessId::Mock,
            run_request("run the slow build"),
            None,
        )
        .await
        .expect("dispatch");

    rig.feed.send(session_started()).unwrap();
    rig.feed.send(text("Kicking off the build.")).unwrap();
    rig.feed
        .send(AgentEvent::ToolCall {
            id: "tool-slow".into(),
            call: ToolCall::Exec {
                command: "cargo build --release".into(),
            },
        })
        .unwrap();
    wait_for(
        || status(&rig.core) == Some(SessionStatus::Working),
        "run starts Working",
    )
    .await;

    // Several full watchdog windows of silence mid-tool-call.
    tokio::time::sleep(Duration::from_millis(QUIESCE_MS * 4)).await;
    assert_eq!(
        status(&rig.core),
        Some(SessionStatus::Working),
        "an unresolved tool call must never quiesce"
    );

    // The tool resolves and the turn ends normally.
    rig.feed
        .send(AgentEvent::ToolResult {
            id: "tool-slow".into(),
            is_error: false,
            output: None,
            diff: None,
        })
        .unwrap();
    rig.feed.send(text("Build done.")).unwrap();
    rig.feed.send(done(DoneStatus::Completed)).unwrap();
    wait_for(
        || status(&rig.core) == Some(SessionStatus::Idle),
        "clean turn end",
    )
    .await;

    rig.core.sessions.shutdown().await;
}

/// Post-turn noise (the original eternally-running-session bug) must STILL be
/// gated: a stale tool echo for an id folded in a prior segment does not
/// resume a parked session.
#[tokio::test]
async fn stale_tool_echo_stays_parked() {
    let rig = assemble("do a thing");
    rig.core
        .sessions
        .dispatch(CHAT, HarnessId::Mock, run_request("do a thing"), None)
        .await
        .expect("dispatch");

    rig.feed.send(session_started()).unwrap();
    rig.feed
        .send(AgentEvent::ToolCall {
            id: "tool-echoed".into(),
            call: ToolCall::Exec {
                command: "sleep 600".into(),
            },
        })
        .unwrap();
    rig.feed
        .send(AgentEvent::ToolResult {
            id: "tool-echoed".into(),
            is_error: false,
            output: None,
            diff: None,
        })
        .unwrap();
    rig.feed
        .send(text("Started it in the background."))
        .unwrap();
    rig.feed.send(done(DoneStatus::Completed)).unwrap();
    wait_for(
        || status(&rig.core) == Some(SessionStatus::Idle),
        "park after Done",
    )
    .await;

    // A late tool_call_update re-emitted as a full ToolCall for the OLD id —
    // sent past the resume gate, so it is the seen-tools guard (not the
    // gate) keeping the session parked.
    tokio::time::sleep(Duration::from_millis(1200)).await;
    rig.feed
        .send(AgentEvent::ToolCall {
            id: "tool-echoed".into(),
            call: ToolCall::Exec {
                command: "sleep 600".into(),
            },
        })
        .unwrap();

    // Give the echo ample time to (wrongly) resume the session.
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(
        status(&rig.core),
        Some(SessionStatus::Idle),
        "a stale tool echo must not resume a parked session"
    );

    rig.core.sessions.shutdown().await;
}
