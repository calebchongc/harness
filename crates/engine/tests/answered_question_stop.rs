//! A run stopped right after a question was answered must say so (#149).
//!
//! The answer resolves the question part, so before this the transcript's
//! last word was a resolved question: nothing told the user that the task had
//! stopped, or why, rather than going on with their answer.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use futures::StreamExt;
use futures::stream::BoxStream;

use harness_adapters::{Harness, HarnessError, RunControls};
use harness_doc::{MessagePart, MessageRole};
use harness_engine::{EngineCore, HarnessRegistry};
use harness_proto::{
    AgentEvent, DoneStatus, HarnessId, Model, ReasoningLevel, RunRequest, SessionStatus,
    SteeringMode, UserInputAnswer, UserInputQuestion,
};

const CHAT: &str = "chat-answered-stop";

/// Asks one question, takes the answer, optionally reports progress, then
/// stays in the turn until it is interrupted, the way an agent mid-way
/// through its next model call does.
struct AskingHarness {
    progress_after_answer: bool,
    answers: Arc<Mutex<Vec<Vec<UserInputAnswer>>>>,
}

#[async_trait]
impl Harness for AskingHarness {
    fn id(&self) -> HarnessId {
        HarnessId::Mock
    }
    fn display_name(&self) -> &str {
        "Asking"
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
    async fn models(&self) -> Result<Vec<Model>, HarnessError> {
        Ok(vec![])
    }
    async fn run(
        &self,
        request: RunRequest,
        controls: RunControls,
    ) -> Result<BoxStream<'static, Result<AgentEvent, HarnessError>>, HarnessError> {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        let answer = (controls.request_input)(vec![UserInputQuestion {
            id: "q1".into(),
            header: "Choose".into(),
            question: "Go ahead?".into(),
            options: vec!["Yes".into(), "No".into()],
            prefill: None,
            multiline: false,
            multi_select: false,
        }]);
        let interrupt = controls.interrupt.clone();
        let progress = self.progress_after_answer;
        let answers = self.answers.clone();
        let _ = tx.send(AgentEvent::SessionStarted {
            harness: HarnessId::Mock,
            model: "mock-1".into(),
            tools: vec![],
            cwd: request.cwd.clone(),
            session_id: "sess-answered".into(),
            assistant_message_id: "a-1".into(),
        });
        tokio::spawn(async move {
            tokio::select! {
                got = answer => {
                    if let Ok(got) = got {
                        answers.lock().unwrap().push(got);
                    }
                }
                _ = interrupt.cancelled() => {}
            }
            if progress && !interrupt.is_cancelled() {
                let _ = tx.send(AgentEvent::TextDelta {
                    text: "Continuing with the answer.".into(),
                });
            }
            interrupt.cancelled().await;
            let _ = tx.send(AgentEvent::Done {
                status: DoneStatus::Interrupted,
                result: None,
                error: None,
                session_id: Some("sess-answered".into()),
            });
        });
        Ok(futures::stream::poll_fn(move |cx| rx.poll_recv(cx))
            .map(Ok)
            .boxed())
    }
}

async fn wait_for<F: FnMut() -> bool>(mut predicate: F, what: &str) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    while !predicate() {
        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for {what}"
        );
        tokio::time::sleep(Duration::from_millis(15)).await;
    }
}

async fn setup(progress_after_answer: bool) -> (EngineCore, Arc<Mutex<Vec<Vec<UserInputAnswer>>>>) {
    let path = tempfile::tempdir().unwrap().keep();
    let answers = Arc::new(Mutex::new(Vec::new()));
    let registry = HarnessRegistry::new();
    registry.register(Arc::new(AskingHarness {
        progress_after_answer,
        answers: answers.clone(),
    }));
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
            serde_json::json!({
                "op": "createChat",
                "chatId": CHAT,
                "deviceId": core.device_id,
            }),
        )
        .await
        .expect("createChat");
    // Pre-titled, so no title run of its own joins the test.
    core.workspace
        .rename_chat(CHAT, "Pre-titled")
        .expect("rename chat");
    (core, answers)
}

fn assistant_parts(core: &EngineCore) -> Vec<MessagePart> {
    core.doc_host
        .open(CHAT)
        .ok()
        .and_then(|h| h.doc().read_entries().ok())
        .unwrap_or_default()
        .into_iter()
        .filter(|e| e.role == MessageRole::Assistant)
        .flat_map(|e| e.parts)
        .collect()
}

fn open_request_id(core: &EngineCore) -> Option<String> {
    assistant_parts(core)
        .into_iter()
        .find_map(|part| match part {
            MessagePart::Input {
                request_id,
                resolved: false,
                ..
            } => Some(request_id),
            _ => None,
        })
}

/// Start the turn, wait for its question, and answer it.
async fn ask_and_answer(core: &EngineCore, answers: &Arc<Mutex<Vec<Vec<UserInputAnswer>>>>) {
    core.doc_host
        .queue_message(CHAT, "do the task", Vec::new())
        .expect("send the prompt");
    wait_for(
        || {
            core.sessions
                .session_status(CHAT)
                .is_some_and(|s| s.status == SessionStatus::AwaitingInput)
        },
        "the agent to ask its question",
    )
    .await;
    let mut request_id = None;
    wait_for(
        || {
            request_id = open_request_id(core);
            request_id.is_some()
        },
        "the question to reach the transcript",
    )
    .await;
    let answered = core
        .sessions
        .respond_input(
            CHAT,
            &request_id.unwrap(),
            vec![UserInputAnswer {
                question_id: "q1".into(),
                labels: vec!["Yes".into()],
            }],
        )
        .expect("answer");
    assert!(answered, "the live run takes the answer");
    wait_for(
        || !answers.lock().unwrap().is_empty(),
        "the agent to receive the answer",
    )
    .await;
}

fn error_messages(core: &EngineCore) -> Vec<String> {
    assistant_parts(core)
        .into_iter()
        .filter_map(|part| match part {
            MessagePart::Error { message, .. } => Some(message),
            _ => None,
        })
        .collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stop_right_after_an_answer_says_the_task_stopped() {
    let (core, answers) = setup(false).await;
    ask_and_answer(&core, &answers).await;

    assert!(
        core.sessions.interrupt(CHAT).await.expect("stop"),
        "a run was live to stop"
    );
    wait_for(|| !core.sessions.turn_in_flight(CHAT), "the turn to end").await;

    let errors = error_messages(&core);
    assert!(
        errors
            .iter()
            .any(|m| m.contains("Stopped") && m.contains("after your answer")),
        "the transcript must say the task stopped after the answer, not end on \
         a resolved question; error parts: {errors:?}"
    );
    core.shutdown().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_stop_after_the_agent_went_on_from_its_answer_adds_no_notice() {
    let (core, answers) = setup(true).await;
    ask_and_answer(&core, &answers).await;
    wait_for(
        || {
            assistant_parts(&core)
                .iter()
                .any(|p| matches!(p, MessagePart::Text { text, .. } if text.contains("Continuing")))
        },
        "the agent's progress after the answer",
    )
    .await;

    assert!(core.sessions.interrupt(CHAT).await.expect("stop"));
    wait_for(|| !core.sessions.turn_in_flight(CHAT), "the turn to end").await;

    assert_eq!(error_messages(&core), Vec::<String>::new());
    core.shutdown().await;
}
