use super::*;
use crate::workspace_host::WorkspaceHostConfig;

const CHAT: &str = "restore-test";

fn host(store: Arc<DocsStore>) -> DocHost {
    DocHost::new(
        store,
        DocHostConfig {
            device_id: "restore-device".into(),
            default_harness: HarnessId::Mock,
            edge: None,
        },
    )
}

fn workspace(store: Arc<DocsStore>) -> WorkspaceHost {
    WorkspaceHost::open(
        store,
        WorkspaceHostConfig {
            device_id: "restore-device".into(),
            device_name: "Test device".into(),
            platform: "test".into(),
            org_id: "test-org".into(),
            user_id: "test-user".into(),
            edge: None,
        },
    )
    .unwrap()
}

fn archived(workspace: &WorkspaceHost) -> bool {
    workspace.chat(CHAT).unwrap().unwrap().archived
}

fn create_archived(workspace: &WorkspaceHost) {
    workspace
        .create_chat(CHAT, None, Some("restore-device"), None, None)
        .unwrap();
    workspace.set_chat_archived(CHAT, true).unwrap();
    workspace.flush();
}

#[tokio::test]
async fn accepted_queue_restore_survives_restart_before_workspace_arrives() {
    let dir = tempfile::tempdir().unwrap();
    let id = {
        let store = Arc::new(DocsStore::open(dir.path()).unwrap());
        let workspace = workspace(store.clone());
        create_archived(&workspace);
        let host = host(store.clone());
        let id = host.queue_message(CHAT, "resume later", vec![]).unwrap();
        host.flush_all();
        assert!(store.sync_job_version(&id, RESTORE_JOB).unwrap().is_some());
        host.shutdown_workers().await;
        id
    };
    let store = Arc::new(DocsStore::open(dir.path()).unwrap());
    let workspace = workspace(store.clone());
    assert!(archived(&workspace));
    let host = host(store.clone());
    host.set_workspace(workspace.clone());
    // Exercise the actual offline scheduler, not execution or focus hooks.
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        while store.sync_job_version(&id, RESTORE_JOB).unwrap().is_some() {
            tokio::time::sleep(std::time::Duration::from_millis(15)).await;
        }
    })
    .await
    .unwrap();
    assert!(!archived(&workspace));
    let queue = host.open(CHAT).unwrap().doc.read_queue().unwrap();
    assert_eq!(queue.len(), 1, "restoration must not replay the prompt");
    assert_eq!(queue[0].id, id);
    host.shutdown_workers().await;
}

#[tokio::test]
async fn missing_chat_metadata_keeps_accepted_restore_pending() {
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(DocsStore::open(dir.path()).unwrap());
    let workspace = workspace(store.clone());
    let host = host(store.clone());
    host.set_workspace(workspace.clone());
    let id = host.queue_message(CHAT, "first prompt", vec![]).unwrap();
    host.retry_prompt_restores(&mut String::new());
    assert!(
        workspace.chat(CHAT).unwrap().is_none(),
        "do not fabricate a partial row"
    );
    assert!(store.sync_job_version(&id, RESTORE_JOB).unwrap().is_some());
    workspace.claim_chat(CHAT, None).unwrap();
    host.retry_prompt_restores(&mut String::new());
    assert!(!archived(&workspace));
    assert!(store.sync_job_version(&id, RESTORE_JOB).unwrap().is_none());
    assert_eq!(host.open(CHAT).unwrap().doc.read_queue().unwrap().len(), 1);
    host.shutdown_workers().await;
}

#[tokio::test]
async fn restore_failure_retries_without_rejecting_or_duplicating_accepted_send() {
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(DocsStore::open(dir.path()).unwrap());
    let workspace = workspace(store.clone());
    create_archived(&workspace);
    let host = host(store.clone());
    host.set_workspace(workspace.clone());
    let db = rusqlite::Connection::open(dir.path().join("docs.sqlite3")).unwrap();
    db.execute_batch(
        "CREATE TRIGGER fail_registry_save BEFORE UPDATE ON snapshots
        WHEN NEW.doc_id='registry1' BEGIN SELECT RAISE(FAIL, 'injected registry failure'); END;",
    )
    .unwrap();
    let id = host.queue_message(CHAT, "accepted once", vec![]).unwrap();
    assert!(store.sync_job_version(&id, RESTORE_JOB).unwrap().is_some());
    host.retry_prompt_restores(&mut String::new());
    assert!(store.sync_job_version(&id, RESTORE_JOB).unwrap().is_some());
    db.execute_batch("DROP TRIGGER fail_registry_save").unwrap();
    host.retry_prompt_restores(&mut String::new());
    assert!(store.sync_job_version(&id, RESTORE_JOB).unwrap().is_none());
    assert!(!archived(&workspace));
    assert_eq!(host.open(CHAT).unwrap().doc.read_queue().unwrap().len(), 1);
    host.shutdown_workers().await;
}

#[tokio::test]
async fn later_explicit_archive_supersedes_delayed_steer_restore() {
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(DocsStore::open(dir.path()).unwrap());
    let workspace = workspace(store.clone());
    create_archived(&workspace);
    let host = host(store.clone());
    let id = host
        .queue_command(
            CHAT,
            SessionCommandPayload::Steer {
                turn_origin: Default::default(),
                prompt: "new prompt".into(),
                message_id: Some("steered-message".into()),
            },
        )
        .unwrap();
    workspace.set_chat_archived(CHAT, true).unwrap();
    host.set_workspace(workspace.clone());
    host.retry_prompt_restores(&mut String::new());
    assert!(
        archived(&workspace),
        "retry must retain the original send clock"
    );
    assert!(store.sync_job_version(&id, RESTORE_JOB).unwrap().is_none());
    assert_eq!(
        host.open(CHAT).unwrap().doc.read_commands().unwrap().len(),
        1
    );
    host.shutdown_workers().await;
}

#[tokio::test]
async fn staged_but_unaccepted_prompt_cannot_restore_a_reference_chat() {
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(DocsStore::open(dir.path()).unwrap());
    let workspace = workspace(store.clone());
    create_archived(&workspace);
    let host = host(store);
    host.set_workspace(workspace.clone());
    host.stage_prompt_restore(CHAT, "not-accepted").unwrap();
    host.retry_prompt_restores(&mut String::new());
    assert!(archived(&workspace));
    host.shutdown_workers().await;
}

#[tokio::test]
async fn detached_restore_observes_durable_clock_after_wall_clock_regression() {
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(DocsStore::open(dir.path()).unwrap());
    let workspace = workspace(store.clone());
    create_archived(&workspace);
    // The durable registry may have observed a remote future clock before
    // startup wires it into the doc host. A wall-only clock cannot restore it.
    workspace.archive_chat_at(CHAT, now_ms() + 60_000).unwrap();
    workspace.flush();
    let host = host(store.clone());
    let id = host
        .queue_message(CHAT, "human returns after restart", vec![])
        .unwrap();
    host.set_workspace(workspace.clone());
    host.retry_prompt_restores(&mut String::new());
    assert!(
        !archived(&workspace),
        "accepted human send must observe the stored archive clock"
    );
    assert!(store.sync_job_version(&id, RESTORE_JOB).unwrap().is_none());
    host.shutdown_workers().await;
}

#[tokio::test]
async fn detached_restore_cannot_outrank_a_newer_explicit_archive_counter() {
    let dir = tempfile::tempdir().unwrap();
    let store = Arc::new(DocsStore::open(dir.path()).unwrap());
    let workspace = workspace(store.clone());
    create_archived(&workspace);
    workspace.archive_chat_at(CHAT, now_ms() + 60_000).unwrap();
    workspace.flush();
    let host = host(store.clone());
    let id = host
        .queue_message(CHAT, "older accepted human return", vec![])
        .unwrap();
    // The detached host and the live workspace can reserve independent HLC
    // counters in the same millisecond. The later archive is authoritative,
    // even if the detached send reserved more counter increments.
    workspace.set_chat_archived(CHAT, true).unwrap();
    host.set_workspace(workspace.clone());
    host.retry_prompt_restores(&mut String::new());
    assert!(
        archived(&workspace),
        "newer archive intent must fence a detached restore"
    );
    assert!(store.sync_job_version(&id, RESTORE_JOB).unwrap().is_none());
    host.shutdown_workers().await;
}

#[tokio::test]
async fn corrupted_restore_clocks_cannot_unarchive_reference_chats() {
    for (clock, archive_basis) in [
        ("zzzz", None),
        ("9999999999999-not-a-counter-restore-device", None),
        ("9999999999999-000000-", None),
        ("9999999999999-000000-restore-device", Some("zzzz")),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let store = Arc::new(DocsStore::open(dir.path()).unwrap());
        let workspace = workspace(store.clone());
        create_archived(&workspace);
        let host = host(store.clone());
        host.set_workspace(workspace.clone());
        store.schedule_sync_job_with_cursor(
            "corrupt-clock", RESTORE_JOB,
            &serde_json::json!({
                "chat_id": CHAT, "clock": clock, "archive_basis": archive_basis, "accepted": true
            }).to_string(),
        ).unwrap();
        host.retry_prompt_restores(&mut String::new());
        let stayed_archived = archived(&workspace);
        let pending = store
            .sync_job_version("corrupt-clock", RESTORE_JOB)
            .unwrap();
        host.shutdown_workers().await;
        assert!(
            stayed_archived,
            "invalid durable clock must fail closed: {clock}"
        );
        assert!(
            pending.is_some(),
            "invalid data must not be acknowledged as a successful restore"
        );
    }
}
