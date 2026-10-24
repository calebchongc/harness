use super::*;
use crate::workspace_host::WorkspaceHostConfig;

const CHAT: &str = "restore-crash-edge";

fn host(store: Arc<DocsStore>) -> DocHost {
    DocHost::new(
        store,
        DocHostConfig {
            device_id: "restore-crash-device".into(),
            default_harness: HarnessId::Mock,
            edge: None,
        },
    )
}

fn workspace(store: Arc<DocsStore>) -> WorkspaceHost {
    WorkspaceHost::open(
        store,
        WorkspaceHostConfig {
            device_id: "restore-crash-device".into(),
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
        .create_chat(CHAT, None, Some("restore-crash-device"), None, None)
        .unwrap();
    // Exercise snapshot-derived HLCs rather than relying on wall-clock order.
    workspace.archive_chat_at(CHAT, now_ms() + 60_000).unwrap();
    workspace.flush();
}

#[tokio::test]
async fn failed_staging_cannot_accept_or_restore_a_prompt_after_restart() {
    let dir = tempfile::tempdir().unwrap();
    {
        let store = Arc::new(DocsStore::open(dir.path()).unwrap());
        let workspace = workspace(store.clone());
        create_archived(&workspace);
        let host = host(store.clone());
        let db = rusqlite::Connection::open(dir.path().join("docs.sqlite3")).unwrap();
        db.execute_batch(
            "CREATE TRIGGER fail_restore_stage BEFORE INSERT ON chat_sync_jobs
             WHEN NEW.kind='prompt-restore'
             BEGIN SELECT RAISE(FAIL, 'injected staging failure'); END;",
        )
        .unwrap();
        let error = host
            .queue_message(CHAT, "must not be accepted", vec![])
            .unwrap_err();
        assert!(error.to_string().contains("injected staging failure"));
        assert!(
            host.open(CHAT)
                .unwrap()
                .doc
                .read_queue()
                .unwrap()
                .is_empty()
        );
        assert!(
            store
                .pending_sync_jobs(RESTORE_JOB, "", 4)
                .unwrap()
                .is_empty()
        );
        db.execute_batch("DROP TRIGGER fail_restore_stage").unwrap();
        host.shutdown_workers().await;
    }
    let store = Arc::new(DocsStore::open(dir.path()).unwrap());
    let workspace = workspace(store.clone());
    let host = host(store);
    host.set_workspace(workspace.clone());
    host.retry_prompt_restores(&mut String::new());
    assert!(archived(&workspace));
    assert!(
        host.open(CHAT)
            .unwrap()
            .doc
            .read_queue()
            .unwrap()
            .is_empty()
    );
    host.shutdown_workers().await;
}

#[tokio::test]
async fn failed_acceptance_receipt_recovers_from_distinct_command_id_after_restart() {
    let dir = tempfile::tempdir().unwrap();
    let message_id = "optimistic-message-not-command";
    let id = {
        let store = Arc::new(DocsStore::open(dir.path()).unwrap());
        let workspace = workspace(store.clone());
        create_archived(&workspace);
        let host = host(store.clone());
        let db = rusqlite::Connection::open(dir.path().join("docs.sqlite3")).unwrap();
        db.execute_batch(
            "CREATE TRIGGER fail_restore_accept BEFORE UPDATE ON chat_sync_jobs
             WHEN NEW.kind='prompt-restore' AND json_extract(NEW.cursor, '$.accepted')=1
             BEGIN SELECT RAISE(FAIL, 'injected acceptance receipt failure'); END;",
        )
        .unwrap();
        let id = host
            .queue_command(
                CHAT,
                SessionCommandPayload::Steer {
                    prompt: "accepted command with staged receipt".into(),
                    message_id: Some(message_id.into()),
                },
            )
            .unwrap();
        assert_ne!(id, message_id);
        let (_, data) = store.sync_job(&id, RESTORE_JOB).unwrap().unwrap();
        let receipt: PromptRestore = serde_json::from_str(&data).unwrap();
        assert!(
            !receipt.accepted,
            "the failed rewrite must leave staged evidence"
        );
        assert!(receipt.archive_basis.is_some());
        assert!(archived(&workspace));
        db.execute_batch("DROP TRIGGER fail_restore_accept")
            .unwrap();
        host.shutdown_workers().await;
        id
    };
    let store = Arc::new(DocsStore::open(dir.path()).unwrap());
    let workspace = workspace(store.clone());
    let host = host(store.clone());
    let handle = host.open(CHAT).unwrap();
    assert!(handle.doc.read_entries().unwrap().is_empty());
    assert!(handle.doc.read_queue().unwrap().is_empty());
    let commands = handle.doc.read_commands().unwrap();
    assert_eq!(commands.len(), 1);
    assert_eq!(commands[0].id, id);
    assert!(matches!(
        &commands[0].payload,
        SessionCommandPayload::Steer { message_id: Some(value), .. } if value == message_id
    ));
    host.set_workspace(workspace.clone());
    host.retry_prompt_restores(&mut String::new());
    assert!(!archived(&workspace));
    assert!(store.sync_job_version(&id, RESTORE_JOB).unwrap().is_none());
    assert_eq!(
        handle.doc.read_commands().unwrap(),
        commands,
        "restore must not replay the command"
    );
    host.shutdown_workers().await;
}

#[tokio::test]
async fn newer_explicit_archive_fences_snapshot_based_receipt_after_restart() {
    let dir = tempfile::tempdir().unwrap();
    let id = {
        let store = Arc::new(DocsStore::open(dir.path()).unwrap());
        let workspace = workspace(store.clone());
        create_archived(&workspace);
        let host = host(store.clone());
        let id = host
            .queue_message(CHAT, "older human return", vec![])
            .unwrap();
        let (_, data) = store.sync_job(&id, RESTORE_JOB).unwrap().unwrap();
        let receipt: PromptRestore = serde_json::from_str(&data).unwrap();
        assert!(receipt.accepted);
        assert!(receipt.archive_basis.is_some());
        // This fresh archive is durable before either host is reopened.
        workspace.set_chat_archived(CHAT, true).unwrap();
        workspace.flush();
        host.shutdown_workers().await;
        id
    };
    let store = Arc::new(DocsStore::open(dir.path()).unwrap());
    let workspace = workspace(store.clone());
    let host = host(store.clone());
    host.set_workspace(workspace.clone());
    host.retry_prompt_restores(&mut String::new());
    assert!(
        archived(&workspace),
        "a restart must not erase the archive fence"
    );
    assert!(store.sync_job_version(&id, RESTORE_JOB).unwrap().is_none());
    let queue = host.open(CHAT).unwrap().doc.read_queue().unwrap();
    assert_eq!(queue.len(), 1);
    assert_eq!(queue[0].id, id);
    host.shutdown_workers().await;
}

#[tokio::test]
async fn malformed_durable_receipt_does_not_abort_unrelated_admitted_restore() {
    let dir = tempfile::tempdir().unwrap();
    let id = {
        let store = Arc::new(DocsStore::open(dir.path()).unwrap());
        let workspace = workspace(store.clone());
        create_archived(&workspace);
        let host = host(store.clone());
        let id = host
            .queue_message(CHAT, "valid accepted return", vec![])
            .unwrap();
        store
            .schedule_sync_job_with_cursor("!malformed-first", RESTORE_JOB, "{broken-json")
            .unwrap();
        assert_eq!(
            store.pending_sync_jobs(RESTORE_JOB, "", 4).unwrap(),
            vec!["!malformed-first".to_string(), id.clone()],
            "both receipts must be admitted in the same bounded page"
        );
        host.shutdown_workers().await;
        id
    };
    let store = Arc::new(DocsStore::open(dir.path()).unwrap());
    let workspace = workspace(store.clone());
    let host = host(store.clone());
    host.set_workspace(workspace.clone());
    let mut cursor = String::new();
    host.retry_prompt_restores(&mut cursor);
    let still_archived = archived(&workspace);
    let valid_pending = store.sync_job_version(&id, RESTORE_JOB).unwrap();
    let queue = host.open(CHAT).unwrap().doc.read_queue().unwrap();
    host.shutdown_workers().await;
    assert!(
        !still_archived,
        "one malformed receipt must not abort valid work already admitted in the same page"
    );
    assert!(valid_pending.is_none());
    assert_eq!(queue.len(), 1);
    assert_eq!(queue[0].id, id);
}
