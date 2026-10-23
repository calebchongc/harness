//! A send with images used to replace the live run: the runtime config check
//! forced a new process for any attachment, which for Claude Code dropped
//! the background tasks running inside the old one (#364). A harness whose
//! steers deliver images now takes the send through its mailbox instead.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use futures::stream::BoxStream;

use harness_adapters::{Harness, HarnessError, RunControls, SteerMessage};
use harness_doc::{SessionCommandEntry, SessionCommandPayload, SessionCommandStatus};
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::{
    AgentEvent, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SteeringMode,
};

const CHAT: &str = "chat-image-steer";

struct Turn {
    steering: tokio::sync::mpsc::Receiver<SteerMessage>,
    finish: tokio::sync::broadcast::Receiver<()>,
    interrupt: harness_adapters::CancellationToken,
    interrupted: Arc<AtomicBool>,
    steers: Arc<Mutex<Vec<SteerMessage>>>,
}

/// A turn held open until the test ends it; records runs, steers and cancels.
struct ImageSteerHarness {
    finish: tokio::sync::broadcast::Sender<()>,
    runs: Mutex<Vec<RunRequest>>,
    steers: Arc<Mutex<Vec<SteerMessage>>>,
    interrupted: Arc<AtomicBool>,
}

#[async_trait]
impl Harness for ImageSteerHarness {
    fn id(&self) -> HarnessId {
        HarnessId::Mock
    }
    fn display_name(&self) -> &str {
        "Image steer"
    }
    fn supports_steering(&self) -> bool {
        true
    }
    fn steering_mode(&self) -> SteeringMode {
        SteeringMode::StepBoundary
    }
    fn steers_attachments(&self) -> bool {
        true
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
        controls: RunControls,
    ) -> Result<BoxStream<'static, Result<AgentEvent, HarnessError>>, HarnessError> {
        self.runs.lock().unwrap().push(request.clone());
        let started = futures::stream::iter(vec![Ok(AgentEvent::SessionStarted {
            harness: HarnessId::Mock,
            model: "mock-1".into(),
            tools: vec![],
            cwd: request.cwd.clone(),
            session_id: "sess-image-steer".into(),
            assistant_message_id: "a-1".into(),
        })]);
        let state = Turn {
            steering: controls.steering,
            finish: self.finish.subscribe(),
            interrupt: controls.interrupt.clone(),
            interrupted: self.interrupted.clone(),
            steers: self.steers.clone(),
        };
        // One event per step until the turn's Done.
        let rest = futures::stream::unfold(Some(state), |state| async move {
            let mut turn = state?;
            let done = |status| AgentEvent::Done {
                status,
                result: None,
                error: None,
                session_id: Some("sess-image-steer".into()),
            };
            let event = tokio::select! {
                _ = turn.interrupt.cancelled() => {
                    turn.interrupted.store(true, Ordering::SeqCst);
                    done(DoneStatus::Interrupted)
                }
                _ = turn.finish.recv() => done(DoneStatus::Completed),
                steer = turn.steering.recv() => match steer {
                    Some(steer) => {
                        turn.steers.lock().unwrap().push(steer);
                        AgentEvent::Steered {
                            assistant_message_id: Some("a-1".into()),
                            next_assistant_message_id: Some("a-2".into()),
                        }
                    }
                    None => done(DoneStatus::Completed),
                },
            };
            let next = (!matches!(event, AgentEvent::Done { .. })).then_some(turn);
            Some((Ok(event), next))
        });
        Ok(started.chain(rest).boxed())
    }
}

async fn wait_for(mut predicate: impl FnMut() -> bool, what: &str) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while !predicate() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for {what}"
        );
        tokio::time::sleep(Duration::from_millis(15)).await;
    }
}

fn run(core: &EngineCore, id: &str, prompt: &str, cwd: &str, attachments: Vec<String>) {
    core.doc_host
        .open(CHAT)
        .unwrap()
        .doc()
        .queue_command(&SessionCommandEntry {
            id: format!("cmd-{id}"),
            payload: SessionCommandPayload::Run {
                message_id: id.into(),
                request: RunRequest {
                    prompt: prompt.into(),
                    harness: Some(HarnessId::Mock),
                    model: Some("mock-1".into()),
                    reasoning: None,
                    model_options: Default::default(),
                    cwd: cwd.into(),
                    sandbox: SandboxLevel::WorkspaceWrite,
                    auto_approve: true,
                    attachments,
                    worktree: None,
                    resume: None,
                },
            },
            issued_by: "viewer".into(),
            issued_at: chrono::Utc::now().timestamp_millis(),
            based_on: None,
            expires_at: None,
            status: SessionCommandStatus::Pending,
            resolution: None,
        })
        .unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_image_send_steers_into_the_live_run() {
    let path = tempfile::tempdir().unwrap().keep();
    let cwd = path.join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let cwd = cwd.display().to_string();
    let (finish, _) = tokio::sync::broadcast::channel(16);
    let harness = Arc::new(ImageSteerHarness {
        finish,
        runs: Mutex::new(Vec::new()),
        steers: Arc::new(Mutex::new(Vec::new())),
        interrupted: Arc::new(AtomicBool::new(false)),
    });
    let registry = HarnessRegistry::new();
    registry.register(harness.clone());
    let core = EngineCore::assemble(
        &path.join("data"),
        Arc::new(registry),
        HarnessId::Mock,
        None,
    )
    .expect("engine core assembles");
    let client = harness_rpc::memory_client(core.rpc_service());
    client
        .call(
            harness_rpc::methods::MUTATE,
            serde_json::json!({"op": "createChat", "chatId": CHAT, "deviceId": core.device_id}),
        )
        .await
        .expect("createChat");
    core.workspace
        .rename_chat(CHAT, "Pre-titled")
        .expect("rename chat");
    std::fs::create_dir_all(core.uploads.dir()).unwrap();
    let image = core.uploads.dir().join("abcd1234-shot.png");
    std::fs::write(&image, b"png-bytes").unwrap();
    let image = image.display().to_string();

    run(&core, "first", "first", &cwd, Vec::new());
    wait_for(
        || core.sessions.turn_in_flight(CHAT),
        "the first turn to be working",
    )
    .await;

    // Mid-turn, a send with an image: delivered to the live run.
    run(&core, "second", "look at this", &cwd, vec![image.clone()]);
    wait_for(
        || !harness.steers.lock().unwrap().is_empty(),
        "the image send to reach the live run",
    )
    .await;
    {
        let steers = harness.steers.lock().unwrap();
        let steer = &steers[0];
        assert!(steer.prompt.contains("look at this"), "{}", steer.prompt);
        assert_eq!(steer.attachments, [image]);
        assert_eq!(steer.message_id.as_deref(), Some("second"));
    }
    assert_eq!(harness.runs.lock().unwrap().len(), 1, "no replacement run");
    assert!(
        !harness.interrupted.load(Ordering::SeqCst),
        "the live run was cancelled"
    );

    let _ = harness.finish.send(());
    core.shutdown().await;
}
