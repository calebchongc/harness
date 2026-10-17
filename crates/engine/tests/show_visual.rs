//! Explicit visual intake must use the normal ordered journal/fold/doc pipeline.
use std::{sync::Arc, time::Duration};

use async_trait::async_trait;
use futures::stream::BoxStream;
use harness_adapters::{Harness, HarnessError, RunControls};
use harness_doc::MessagePart;
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::{
    AgentEvent, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SandboxLevel,
    SessionStatus, SteeringMode,
};

const CHAT: &str = "chat-show-visual";
const SCRIPT: &str = "return function() return ui.text(\"Hello\") end";

fn done() -> AgentEvent {
    AgentEvent::Done {
        status: DoneStatus::Completed,
        result: None,
        error: None,
        session_id: None,
    }
}

fn request(cwd: &std::path::Path) -> RunRequest {
    RunRequest {
        prompt: "work".into(),
        harness: None,
        model: None,
        reasoning: None,
        model_options: Default::default(),
        cwd: cwd.to_string_lossy().into_owned(),
        sandbox: SandboxLevel::WorkspaceWrite,
        auto_approve: true,
        attachments: vec![],
        worktree: None,
        resume: None,
    }
}

#[derive(Default)]
struct ChannelHarness {
    tx: std::sync::Mutex<Option<tokio::sync::mpsc::Sender<Result<AgentEvent, HarnessError>>>>,
}

impl ChannelHarness {
    async fn emit(&self, event: AgentEvent) {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        let tx = loop {
            if let Some(tx) = self.tx.lock().unwrap().clone() {
                break tx;
            }
            assert!(tokio::time::Instant::now() < deadline, "run did not start");
            tokio::time::sleep(Duration::from_millis(10)).await;
        };
        tx.send(Ok(event)).await.unwrap();
    }

    fn close(&self) {
        self.tx.lock().unwrap().take();
    }
}

#[async_trait]
impl Harness for ChannelHarness {
    fn id(&self) -> HarnessId {
        HarnessId::Mock
    }
    fn display_name(&self) -> &str {
        "Channel"
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
        _request: RunRequest,
        _controls: RunControls,
    ) -> Result<BoxStream<'static, Result<AgentEvent, HarnessError>>, HarnessError> {
        let (tx, rx) = tokio::sync::mpsc::channel(16);
        *self.tx.lock().unwrap() = Some(tx);
        Ok(Box::pin(futures::stream::unfold(rx, |mut rx| async move {
            rx.recv().await.map(|event| (event, rx))
        })))
    }
}

fn assemble(dir: &std::path::Path, harness: Arc<ChannelHarness>) -> EngineCore {
    let registry = HarnessRegistry::new();
    registry.register(harness);
    EngineCore::assemble(dir, Arc::new(registry), HarnessId::Mock, None).unwrap()
}

fn parts(core: &EngineCore) -> Vec<MessagePart> {
    core.doc_host
        .open(CHAT)
        .unwrap()
        .doc()
        .read_entries()
        .unwrap()
        .into_iter()
        .flat_map(|entry| entry.parts)
        .collect()
}

fn visual_count(core: &EngineCore) -> usize {
    parts(core)
        .iter()
        .filter(|p| matches!(p, MessagePart::Visual { .. }))
        .count()
}

async fn wait_for(mut predicate: impl FnMut() -> bool) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while !predicate() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "condition did not settle"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}

#[tokio::test]
async fn show_visual_ack_is_journaled_synced_ordered_and_deduped() {
    let dir = tempfile::tempdir().unwrap();
    let harness = Arc::new(ChannelHarness::default());
    let core = assemble(dir.path(), harness.clone());
    core.sessions
        .dispatch(CHAT, HarnessId::Mock, request(dir.path()), None)
        .await
        .unwrap();
    harness
        .emit(AgentEvent::TextDelta {
            text: "before".into(),
        })
        .await;
    wait_for(|| {
        parts(&core)
            .iter()
            .any(|p| matches!(p, MessagePart::Text { text, .. } if text == "before"))
    })
    .await;

    core.sessions
        .show_visual(CHAT, "one", "Overview", SCRIPT)
        .await
        .unwrap();
    assert_eq!(
        visual_count(&core),
        1,
        "success ACK requires doc sync already complete"
    );
    let (replay, _) = core.sessions.subscribe(CHAT, 0).unwrap();
    assert_eq!(
        replay
            .iter()
            .filter(|row| matches!(&row.event, AgentEvent::GeneratedVisual { .. }))
            .count(),
        1
    );
    assert!(replay.iter().any(|row| row.seq > 0 && matches!(&row.event, AgentEvent::GeneratedVisual { id, .. } if id == "show-visual:one")));
    core.sessions
        .show_visual(CHAT, "one", "Overview", SCRIPT)
        .await
        .unwrap();
    assert!(
        core.sessions
            .show_visual(CHAT, "one", "Changed", SCRIPT)
            .await
            .unwrap_err()
            .to_string()
            .contains("different parameters")
    );
    assert!(
        core.sessions
            .show_visual(CHAT, "one", "Overview", &format!("{SCRIPT} "))
            .await
            .is_err()
    );
    assert_eq!(visual_count(&core), 1);
    assert_eq!(
        core.sessions
            .subscribe(CHAT, 0)
            .unwrap()
            .0
            .iter()
            .filter(|row| matches!(&row.event, AgentEvent::GeneratedVisual { .. }))
            .count(),
        1
    );

    harness
        .emit(AgentEvent::TextDelta {
            text: "after".into(),
        })
        .await;
    harness.emit(done()).await;
    wait_for(|| {
        core.sessions
            .session_status(CHAT)
            .is_some_and(|s| s.status == SessionStatus::Idle)
    })
    .await;
    let parts = parts(&core);
    let before = parts
        .iter()
        .position(|p| matches!(p, MessagePart::Text { text, .. } if text == "before"))
        .unwrap();
    let visual = parts
        .iter()
        .position(|p| matches!(p, MessagePart::Visual { .. }))
        .unwrap();
    let after = parts
        .iter()
        .position(|p| matches!(p, MessagePart::Text { text, .. } if text == "after"))
        .unwrap();
    assert!(before < visual && visual < after);
    harness.close();
    core.doc_host.shutdown_workers().await;
    core.sessions.shutdown().await;
    drop(core);
    let core = assemble(dir.path(), Arc::new(ChannelHarness::default()));
    assert_eq!(visual_count(&core), 1, "source survives snapshot/reopen");
    core.sessions.shutdown().await;
}

#[tokio::test]
async fn show_visual_queued_request_beats_immediately_following_done() {
    let dir = tempfile::tempdir().unwrap();
    let harness = Arc::new(ChannelHarness::default());
    let core = assemble(dir.path(), harness.clone());
    core.sessions
        .dispatch(CHAT, HarnessId::Mock, request(dir.path()), None)
        .await
        .unwrap();
    harness
        .emit(AgentEvent::TextDelta {
            text: "ready".into(),
        })
        .await;
    wait_for(|| {
        parts(&core)
            .iter()
            .any(|p| matches!(p, MessagePart::Text { text, .. } if text == "ready"))
    })
    .await;
    let publish = core
        .sessions
        .show_visual(CHAT, "queued", "Overview", SCRIPT);
    futures::pin_mut!(publish);
    // Poll once to put the request in its bounded mailbox without waiting for its ACK.
    assert!(futures::poll!(publish.as_mut()).is_pending());
    harness.emit(done()).await;
    tokio::time::timeout(Duration::from_secs(10), publish)
        .await
        .unwrap()
        .unwrap();
    wait_for(|| {
        core.sessions
            .session_status(CHAT)
            .is_some_and(|s| s.status == SessionStatus::Idle)
    })
    .await;
    let (replay, _) = core.sessions.subscribe(CHAT, 0).unwrap();
    let visual = replay
        .iter()
        .position(|row| matches!(&row.event, AgentEvent::GeneratedVisual { .. }))
        .unwrap();
    let done = replay
        .iter()
        .position(|row| matches!(&row.event, AgentEvent::Done { .. }))
        .unwrap();
    assert!(visual < done);
    harness.close();
    core.sessions.shutdown().await;
}

#[tokio::test]
async fn show_visual_rejects_limits_invalid_first_render_idle_and_interruption() {
    let dir = tempfile::tempdir().unwrap();
    let harness = Arc::new(ChannelHarness::default());
    let core = assemble(dir.path(), harness.clone());
    assert!(
        core.sessions
            .show_visual(CHAT, "absent", "Overview", SCRIPT)
            .await
            .unwrap_err()
            .to_string()
            .contains("No active run")
    );
    core.sessions
        .dispatch(CHAT, HarnessId::Mock, request(dir.path()), None)
        .await
        .unwrap();
    for (id, title, script) in [
        ("bad id".to_owned(), "Title".to_owned(), SCRIPT.to_owned()),
        ("long-title".into(), "界".repeat(201), SCRIPT.into()),
        ("blank-title".into(), " \n".into(), SCRIPT.into()),
        ("long-script".into(), "Title".into(), "é".repeat(32769)),
        ("blank-script".into(), "Title".into(), " \n\t".into()),
        ("syntax".into(), "Title".into(), "not a valid script".into()),
        (
            "bad-render".into(),
            "Title".into(),
            "return function() return {} end".into(),
        ),
        ("loop".into(), "Title".into(), "while true do end".into()),
    ] {
        tokio::time::timeout(
            Duration::from_secs(10),
            core.sessions.show_visual(CHAT, &id, &title, &script),
        )
        .await
        .expect("bounded rejection")
        .expect_err("invalid publication must fail");
    }
    assert_eq!(visual_count(&core), 0);
    assert!(
        !core
            .sessions
            .subscribe(CHAT, 0)
            .unwrap()
            .0
            .iter()
            .any(|row| matches!(&row.event, AgentEvent::GeneratedVisual { .. }))
    );
    // Exact UTF-8 source bound and Unicode title character bound are accepted.
    let padded = format!("{SCRIPT}{}", " ".repeat(65536 - SCRIPT.len()));
    core.sessions
        .show_visual(CHAT, "boundary", &"界".repeat(200), &padded)
        .await
        .unwrap();
    harness.emit(done()).await;
    wait_for(|| {
        core.sessions
            .session_status(CHAT)
            .is_some_and(|s| s.status == SessionStatus::Idle)
    })
    .await;
    // Even a successful retry must not publish/ACK into a parked turn.
    assert!(
        core.sessions
            .show_visual(CHAT, "boundary", &"界".repeat(200), &padded)
            .await
            .unwrap_err()
            .to_string()
            .contains("idle")
    );
    harness.close();
    core.sessions.shutdown().await;

    let other_dir = tempfile::tempdir().unwrap();
    let harness = Arc::new(ChannelHarness::default());
    let core = assemble(other_dir.path(), harness.clone());
    core.sessions
        .dispatch(CHAT, HarnessId::Mock, request(other_dir.path()), None)
        .await
        .unwrap();
    core.sessions.interrupt(CHAT).await.unwrap();
    tokio::time::timeout(
        Duration::from_secs(10),
        core.sessions
            .show_visual(CHAT, "interrupted", "Title", SCRIPT),
    )
    .await
    .unwrap()
    .expect_err("interrupted run must reject");
    assert_eq!(visual_count(&core), 0);
    harness.close();
    core.sessions.shutdown().await;
}

#[tokio::test]
async fn show_visual_rpc_is_local_owner_only_and_denies_unknown_fields() {
    use harness_rpc::{memory_client, methods};
    use serde_json::json;
    let dir = tempfile::tempdir().unwrap();
    let harness = Arc::new(ChannelHarness::default());
    let core = assemble(dir.path(), harness.clone());
    let client = memory_client(core.rpc_service());
    let params = json!({"chatId":CHAT, "id":"rpc", "title":"Overview", "script":SCRIPT});
    assert!(
        client
            .call(methods::SHOW_VISUAL, params.clone())
            .await
            .unwrap_err()
            .to_string()
            .contains("chat not found")
    );
    core.workspace
        .create_chat(
            CHAT,
            None,
            Some(&core.device_id),
            None,
            Some(dir.path().to_string_lossy().into_owned()),
        )
        .unwrap();
    assert!(
        client
            .call(methods::SHOW_VISUAL, params.clone())
            .await
            .unwrap_err()
            .to_string()
            .contains("No active run")
    );
    core.sessions
        .dispatch(CHAT, HarnessId::Mock, request(dir.path()), None)
        .await
        .unwrap();
    let mut spoof = params.clone();
    spoof["targetDeviceId"] = json!("another-device");
    assert!(
        client
            .call(methods::SHOW_VISUAL, spoof)
            .await
            .unwrap_err()
            .to_string()
            .contains("unknown field")
    );
    core.workspace
        .create_chat("foreign", None, Some("another-device"), None, None)
        .unwrap();
    let mut foreign = params.clone();
    foreign["chatId"] = json!("foreign");
    assert!(
        client
            .call(methods::SHOW_VISUAL, foreign)
            .await
            .unwrap_err()
            .to_string()
            .contains("another device")
    );
    let result = client.call(methods::SHOW_VISUAL, params).await.unwrap();
    assert_eq!(result["attached"], true);
    assert_eq!(result["id"], "show-visual:rpc");
    assert!(result.get("script").is_none());
    assert_eq!(visual_count(&core), 1);
    harness.emit(done()).await;
    harness.close();
    core.sessions.shutdown().await;
}
