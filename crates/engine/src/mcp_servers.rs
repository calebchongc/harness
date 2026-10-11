//! graff's MCP servers on this device, for the MCP servers settings page and
//! the TUI's `/mcp`: `graff mcp status|reconnect|enable|disable|login`, run
//! with the graff home this engine signs graff in under and in the project
//! folder whose `.mcp.json` counts.
//!
//! Harness starts a new graff for every run, so nothing here holds an MCP
//! connection. A reconnect is a fresh handshake that refreshes the server's
//! cached tools, which is what the next turn starts from.

use std::path::Path;
use std::time::Duration;

use harness_proto::{McpServerList, McpServerRow, McpServerVerb};

use crate::EngineError;

const STATUS_TIMEOUT: Duration = Duration::from_secs(60);
/// Every server's handshake runs concurrently; `npx` servers can take a while
/// to download the first time.
const RECONNECT_TIMEOUT: Duration = Duration::from_secs(150);
/// A person finishing an OAuth page in the browser.
const LOGIN_TIMEOUT: Duration = Duration::from_secs(300);

/// Every configured server, from config and caches alone (nothing starts).
pub async fn list(
    graff_home: &Path,
    cwd: Option<&Path>,
    names: &[String],
) -> Result<Vec<McpServerRow>, EngineError> {
    let out = run("status", names, graff_home, cwd, STATUS_TIMEOUT).await?;
    parse(&out)
}

/// Apply `verb` and return the affected rows. `name` None is only valid for
/// a reconnect, which then checks every switched-on server.
pub async fn act(
    graff_home: &Path,
    cwd: Option<&Path>,
    verb: McpServerVerb,
    name: Option<String>,
) -> Result<Vec<McpServerRow>, EngineError> {
    let names: Vec<String> = name.into_iter().collect();
    if names.is_empty() && verb != McpServerVerb::Reconnect {
        return Err(EngineError::Other(format!(
            "Say which MCP server to {}.",
            verb.as_str()
        )));
    }
    match verb {
        McpServerVerb::Login => {
            run("login", &names, graff_home, cwd, LOGIN_TIMEOUT).await?;
            list(graff_home, cwd, &names).await
        }
        McpServerVerb::Reconnect => {
            parse(&run("reconnect", &names, graff_home, cwd, RECONNECT_TIMEOUT).await?)
        }
        McpServerVerb::Enable | McpServerVerb::Disable => {
            parse(&run(verb.as_str(), &names, graff_home, cwd, STATUS_TIMEOUT).await?)
        }
    }
}

async fn run(
    verb: &str,
    names: &[String],
    graff_home: &Path,
    cwd: Option<&Path>,
    timeout: Duration,
) -> Result<String, EngineError> {
    let cwd = cwd.filter(|dir| dir.is_dir());
    let mut command = harness_adapters::graff_mcp_command(verb, names, cwd)
        .await
        .map_err(|err| {
            EngineError::Other(match err {
                harness_adapters::HarnessError::NotInstalled(_) => {
                    "The `graff` CLI was not found on this device — install it first.".into()
                }
                other => format!("Could not resolve the graff CLI: {other}"),
            })
        })?;
    command
        .stdin(harness_adapters::process::Stdio::null())
        .kill_on_drop(true);
    // graff finds its MCP config, caches and sign-ins from HOME.
    #[cfg(unix)]
    command.env("HOME", graff_home);
    #[cfg(not(unix))]
    let _ = graff_home;
    let output = tokio::time::timeout(timeout, command.output())
        .await
        .map_err(|_| EngineError::Other(format!("graff mcp {verb} did not finish in time.")))?
        .map_err(|err| EngineError::Other(format!("Could not run graff mcp {verb}: {err}")))?;
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let last = stderr
            .lines()
            .chain(stdout.lines())
            .rev()
            .find(|l| !l.trim().is_empty())
            .unwrap_or("graff exited with an error");
        return Err(EngineError::Other(last.trim().to_string()));
    }
    Ok(stdout)
}

/// The rows from `--json` output. An older graff prints its usage text
/// instead, which is not JSON.
pub fn parse(stdout: &str) -> Result<Vec<McpServerRow>, EngineError> {
    let json = stdout.lines().find(|l| l.trim_start().starts_with('{'));
    json.and_then(|line| serde_json::from_str::<McpServerList>(line).ok())
        .map(|list| list.servers)
        .ok_or_else(|| {
            EngineError::Other(
                "This graff can't list MCP servers yet. Update graff to manage them here.".into(),
            )
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use harness_proto::McpServerState;

    #[test]
    fn parses_graff_rows_and_explains_an_older_graff() {
        let rows = parse(
            r#"{"version":1,"servers":[{"name":"a","state":"ready","toolCount":2,"tools":[]}]}"#,
        )
        .unwrap();
        assert_eq!(rows[0].state, McpServerState::Ready);
        assert_eq!(rows[0].tool_count, 2);
        let old = "usage:\n  graff mcp install …\n";
        let err = parse(old).unwrap_err().to_string();
        assert!(err.contains("Update graff"), "{err}");
    }

    #[tokio::test]
    async fn enable_and_disable_need_a_name() {
        let home = std::env::temp_dir();
        for verb in [
            McpServerVerb::Enable,
            McpServerVerb::Disable,
            McpServerVerb::Login,
        ] {
            let err = act(&home, None, verb, None).await.unwrap_err().to_string();
            assert!(err.contains("Say which MCP server"), "{err}");
        }
    }
}
