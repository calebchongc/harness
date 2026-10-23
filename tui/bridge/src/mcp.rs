//! `/mcp` in the TUI: Codex's MCP methods answered from graff's own MCP
//! status (`graff mcp status|reconnect|enable|disable|login`), the same rows
//! the Harness settings page lists.
//!
//! - `mcpServerStatus/list`: one `McpServerStatus` per configured server.
//! - `config/mcpServer/reload`: a fresh handshake for every switched-on
//!   server, or (with `name`/`enabled`) one server, or switching it on/off.
//! - `mcpServer/oauth/login`: graff's OAuth sign-in; the TUI opens the URL.
//! - `graff/mcp/reconnect` and `graff/mcp/setEnabled`: `/mcp reconnect` and
//!   `/mcp enable|disable` (tui/patches/0006-mcp-reconnect.patch).

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use harness_proto::{McpServerRow, McpServerState, McpServerVerb};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, BufReader};

use crate::wire::{Conn, RpcError};

fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_default()
}

/// The thread's folder decides which project `.mcp.json` counts.
fn cwd_of(conn: &Conn, params: &Value) -> Option<PathBuf> {
    let thread = params.get("threadId").and_then(Value::as_str)?;
    let threads = conn.threads.lock().expect("threads lock");
    threads.get(thread).map(|t| PathBuf::from(&t.cwd))
}

fn fallback_cwd(conn: &Conn, params: &Value) -> Option<PathBuf> {
    cwd_of(conn, params).or_else(|| std::env::current_dir().ok())
}

fn failed(error: harness_engine::EngineError) -> RpcError {
    RpcError::internal(error.to_string())
}

/// Codex's `McpServerStatus` for one graff row.
pub fn to_codex(row: &McpServerRow) -> Value {
    let runtime = match row.state {
        // Its tools reach the model; a local one starts on the first call.
        McpServerState::Ready | McpServerState::OnDemand => Some("connected"),
        McpServerState::Connecting => Some("starting"),
        McpServerState::Failed => Some("failed"),
        McpServerState::NeedsLogin => Some("authenticationRequired"),
        McpServerState::Off | McpServerState::OptIn => Some("disabled"),
        McpServerState::NotStarted => Some("notStarted"),
        McpServerState::Unknown => None,
    };
    let auth = match (row.state, row.auth.as_str()) {
        (McpServerState::NeedsLogin, _) => "notLoggedIn",
        (_, "bearer") => "bearerToken",
        (_, "oauth") => "oAuth",
        (_, "none") => "unsupported",
        _ => "unknown",
    };
    let tools: HashMap<&str, Value> = row
        .tools
        .iter()
        .map(|t| {
            (
                t.name.as_str(),
                json!({ "name": t.name, "description": t.description, "inputSchema": { "type": "object" } }),
            )
        })
        .collect();
    let error = row.detail.as_ref().or(row.error.as_ref());
    json!({
        "name": row.name,
        "runtimeStatus": runtime,
        "pluginId": null,
        "httpOrigin": (row.transport == "http").then_some(&row.origin),
        "serverInfo": null,
        "serverCapabilities": null,
        "tools": tools,
        "toolsError": if row.tools.is_empty() { error } else { None },
        "resources": [],
        "resourceTemplates": [],
        "authStatus": auth,
    })
}

pub async fn status_list(conn: &Arc<Conn>, params: Value) -> Result<Value, RpcError> {
    let names: Vec<String> = params
        .get("serverName")
        .and_then(Value::as_str)
        .map(|n| vec![n.to_string()])
        .unwrap_or_default();
    let rows =
        harness_engine::mcp_servers::list(&home(), fallback_cwd(conn, &params).as_deref(), &names)
            .await
            .map_err(failed)?;
    Ok(json!({ "data": rows.iter().map(to_codex).collect::<Vec<_>>(), "nextCursor": null }))
}

/// `config/mcpServer/reload {name?, enabled?}`: the patched TUI's `/mcp
/// reconnect [name]` and `/mcp enable|disable <name>` (plain Codex sends none).
pub async fn reload(conn: &Arc<Conn>, params: Value) -> Result<Value, RpcError> {
    if params.get("enabled").is_some_and(Value::is_boolean) {
        set_enabled(conn, params).await
    } else {
        reconnect(conn, params).await
    }
}

/// `graff/mcp/reconnect`: one server or all.
pub async fn reconnect(conn: &Arc<Conn>, params: Value) -> Result<Value, RpcError> {
    let name = params
        .get("name")
        .and_then(Value::as_str)
        .map(str::to_string);
    let cwd = fallback_cwd(conn, &params);
    let thread = params.get("threadId").cloned().unwrap_or(Value::Null);
    if let Some(n) = &name {
        conn.notify(
            "mcpServer/startupStatus/updated",
            json!({ "threadId": thread, "name": n, "status": "starting", "error": null, "failureReason": null }),
        );
    }
    let rows =
        harness_engine::mcp_servers::act(&home(), cwd.as_deref(), McpServerVerb::Reconnect, name)
            .await
            .map_err(failed)?;
    for row in &rows {
        let (status, reason) = match row.state {
            McpServerState::Ready | McpServerState::OnDemand => ("ready", None),
            McpServerState::NeedsLogin => ("failed", Some("reauthenticationRequired")),
            _ => ("failed", None),
        };
        conn.notify(
            "mcpServer/startupStatus/updated",
            json!({
                "threadId": thread, "name": row.name, "status": status,
                "error": row.detail.as_ref().or(row.error.as_ref()), "failureReason": reason,
            }),
        );
    }
    Ok(json!({ "data": rows.iter().map(to_codex).collect::<Vec<_>>() }))
}

/// `graff/mcp/setEnabled {name, enabled}`.
pub async fn set_enabled(conn: &Arc<Conn>, params: Value) -> Result<Value, RpcError> {
    let Some(name) = params.get("name").and_then(Value::as_str) else {
        return Err(RpcError::invalid_params("missing name"));
    };
    let verb = if params
        .get("enabled")
        .and_then(Value::as_bool)
        .unwrap_or(true)
    {
        McpServerVerb::Enable
    } else {
        McpServerVerb::Disable
    };
    let rows = harness_engine::mcp_servers::act(
        &home(),
        fallback_cwd(conn, &params).as_deref(),
        verb,
        Some(name.to_string()),
    )
    .await
    .map_err(failed)?;
    Ok(json!({ "data": rows.iter().map(to_codex).collect::<Vec<_>>() }))
}

/// `mcpServer/oauth/login`: start graff's sign-in, answer with the page it
/// prints (the TUI opens it), and report completion when graff exits.
pub async fn oauth_login(conn: &Arc<Conn>, params: Value) -> Result<Value, RpcError> {
    let Some(name) = params
        .get("name")
        .and_then(Value::as_str)
        .map(str::to_string)
    else {
        return Err(RpcError::invalid_params("missing name"));
    };
    let thread = params.get("threadId").cloned().unwrap_or(Value::Null);
    let cwd = fallback_cwd(conn, &params);
    let mut command =
        harness_adapters::graff_mcp_command("login", std::slice::from_ref(&name), cwd.as_deref())
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?;
    command
        .env("GRAFF_NO_BROWSER", "1")
        .stdin(harness_adapters::process::Stdio::null())
        .stdout(harness_adapters::process::Stdio::piped())
        .stderr(harness_adapters::process::Stdio::piped())
        .kill_on_drop(true);
    let mut child = command
        .spawn()
        .map_err(|e| RpcError::internal(format!("could not start graff mcp login: {e}")))?;
    let stdout = child.stdout.take().expect("piped stdout");
    let mut lines = BufReader::new(stdout).lines();
    let mut seen = Vec::new();
    let url = loop {
        match tokio::time::timeout(std::time::Duration::from_secs(30), lines.next_line()).await {
            Ok(Ok(Some(line))) => {
                let line = line.trim().to_string();
                if line.starts_with("https://") || line.starts_with("http://") {
                    break line;
                }
                seen.push(line);
            }
            _ => {
                let _ = child.kill().await;
                let why = seen
                    .into_iter()
                    .rev()
                    .find(|l| !l.is_empty())
                    .unwrap_or_else(|| "no sign-in page".into());
                return Err(RpcError::internal(format!("{name}: {why}")));
            }
        }
    };
    let login_id = uuid::Uuid::new_v4().to_string();
    let (conn2, id2) = (conn.clone(), login_id.clone());
    tokio::spawn(async move {
        // Keep draining so graff never blocks on a full pipe.
        let mut tail = String::new();
        while let Ok(Some(line)) = lines.next_line().await {
            if !line.trim().is_empty() {
                tail = line;
            }
        }
        let ok = matches!(
            tokio::time::timeout(std::time::Duration::from_secs(600), child.wait()).await,
            Ok(Ok(status)) if status.success()
        );
        conn2.notify(
            "mcpServer/oauthLogin/completed",
            json!({ "name": name, "threadId": thread, "loginId": id2, "success": ok, "error": (!ok).then_some(tail) }),
        );
    });
    Ok(json!({ "authorizationUrl": url, "loginId": login_id }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use harness_proto::McpToolRow;

    fn row(state: McpServerState) -> McpServerRow {
        McpServerRow {
            name: "srv".into(),
            source: "global".into(),
            transport: "http".into(),
            origin: "https://mcp.example.com".into(),
            enabled: true,
            state,
            error: Some("the server exited during startup".into()),
            error_code: Some("McpClosed".into()),
            detail: Some("srv: missing API key".into()),
            auth: "unknown".into(),
            tool_count: 0,
            tools: Vec::new(),
        }
    }

    #[test]
    fn graff_rows_map_onto_codex_mcp_status() {
        let failed = to_codex(&row(McpServerState::Failed));
        assert_eq!(failed["runtimeStatus"], "failed");
        assert_eq!(failed["toolsError"], "srv: missing API key");
        assert_eq!(failed["httpOrigin"], "https://mcp.example.com");
        assert_eq!(failed["authStatus"], "unknown");

        let login = to_codex(&row(McpServerState::NeedsLogin));
        assert_eq!(login["runtimeStatus"], "authenticationRequired");
        assert_eq!(login["authStatus"], "notLoggedIn");

        let mut lazy = row(McpServerState::OnDemand);
        lazy.tools = vec![McpToolRow {
            name: "search".into(),
            description: "Find.".into(),
        }];
        let lazy = to_codex(&lazy);
        assert_eq!(lazy["runtimeStatus"], "connected");
        assert_eq!(lazy["tools"]["search"]["description"], "Find.");
        assert!(lazy["toolsError"].is_null());

        assert_eq!(
            to_codex(&row(McpServerState::OptIn))["runtimeStatus"],
            "disabled"
        );
        assert!(to_codex(&row(McpServerState::Unknown))["runtimeStatus"].is_null());
    }
}
