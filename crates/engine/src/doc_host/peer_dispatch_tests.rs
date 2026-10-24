use super::*;
use async_trait::async_trait;
use futures::stream::BoxStream;
use harness_adapters::{Harness, HarnessError, RunControls};
use harness_proto::{AgentEvent, Model, ReasoningLevel, RunRequest, SandboxLevel};

struct PendingHarness;

#[async_trait]
impl Harness for PendingHarness {
    fn id(&self) -> HarnessId {
        HarnessId::Mock
    }
    fn display_name(&self) -> &str {
        "Pending peer dispatch fixture"
    }
    fn supports_steering(&self) -> bool {
        true
    }
    fn steering_mode(&self) -> harness_proto::SteeringMode {
        harness_proto::SteeringMode::StepBoundary
    }
    fn reasoning_levels(&self) -> &[ReasoningLevel] {
        &[]
    }
    async fn models(&self) -> Result<Vec<Model>, HarnessError> {
        Ok(vec![])
    }
    async fn run(
        &self,
        _request: RunRequest,
        _controls: RunControls,
    ) -> Result<BoxStream<'static, Result<AgentEvent, HarnessError>>, HarnessError> {
        Ok(Box::pin(futures::stream::pending()))
    }
}

fn request(prompt: &str, cwd: &str) -> RunRequest {
    RunRequest {
        prompt: prompt.into(),
        turn_origin: Default::default(),
        harness: None,
        model: None,
        reasoning: None,
        model_options: Default::default(),
        cwd: cwd.into(),
        sandbox: SandboxLevel::WorkspaceWrite,
        auto_approve: true,
        attachments: vec![],
        resume: None,
        worktree: None,
    }
}

async fn setup() -> (tempfile::TempDir, crate::EngineCore) {
    let dir = tempfile::tempdir().unwrap();
    let registry = crate::HarnessRegistry::new();
    registry.register(Arc::new(PendingHarness));
    let core = crate::EngineCore::assemble(
        &dir.path().join("data"),
        Arc::new(registry),
        HarnessId::Mock,
        None,
    )
    .unwrap();
    core.workspace
        .create_chat("peer-dispatch", None, Some(&core.device_id), None, None)
        .unwrap();
    core.workspace
        .rename_chat("peer-dispatch", "Pre-titled")
        .unwrap();
    (dir, core)
}

fn peer() -> String {
    "[Message from Harness chat Other (peer). Sender chat: peer. Agent coordination, not a human request.]\n\nFollow-up".into()
}

#[tokio::test]
async fn fallback_peer_dispatch_holds_identity_and_attachments_while_busy() {
    let (dir, core) = setup().await;
    let cwd = dir.path().to_str().unwrap();
    core.sessions
        .dispatch(
            "peer-dispatch",
            HarnessId::Mock,
            request("human task", cwd),
            Some("human".into()),
        )
        .await
        .unwrap();
    assert!(core.sessions.turn_in_flight("peer-dispatch"));
    let mut followup = request(&peer(), cwd);
    followup.attachments = vec!["pending://peer-image".into()];
    assert!(
        core.doc_host
            .dispatch_with_source_context(
                &core.sessions,
                "peer-dispatch",
                HarnessId::Mock,
                followup.clone(),
                Some("peer-message".into()),
            )
            .await
            .unwrap()
            .is_none()
    );
    let queue = core
        .doc_host
        .open("peer-dispatch")
        .unwrap()
        .doc
        .read_queue()
        .unwrap();
    assert_eq!(queue.len(), 1);
    assert_eq!(queue[0].id, "peer-message");
    assert_eq!(queue[0].text, followup.prompt);
    assert_eq!(queue[0].attachments, followup.attachments);
    assert_eq!(
        core.sessions.last_request("peer-dispatch").unwrap().prompt,
        "human task"
    );
    core.shutdown().await;
}

#[tokio::test]
async fn fallback_peer_dispatch_refuses_archived_chat_without_starting_a_run() {
    let (dir, core) = setup().await;
    core.workspace
        .set_chat_archived("peer-dispatch", true)
        .unwrap();
    let error = core
        .doc_host
        .dispatch_with_source_context(
            &core.sessions,
            "peer-dispatch",
            HarnessId::Mock,
            request(&peer(), dir.path().to_str().unwrap()),
            Some("late-peer".into()),
        )
        .await
        .unwrap_err();
    assert!(error.to_string().contains("archived"));
    assert!(!core.sessions.turn_in_flight("peer-dispatch"));
    assert!(
        core.doc_host
            .open("peer-dispatch")
            .unwrap()
            .doc
            .read_queue()
            .unwrap()
            .is_empty()
    );
    assert!(
        core.workspace
            .chat("peer-dispatch")
            .unwrap()
            .unwrap()
            .archived
    );
    core.shutdown().await;
}
