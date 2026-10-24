//! MCP servers as graff reports them (`graff mcp status --json`): the rows the
//! MCP servers settings page lists and the TUI's `/mcp` renders.

use serde::{Deserialize, Serialize};

/// What a configured server is doing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum McpServerState {
    /// Connected; its tools are live.
    Ready,
    /// Known tools; it starts (or connects) on its first call.
    OnDemand,
    Connecting,
    Failed,
    NeedsLogin,
    /// Switched off by the user, or in its own config entry.
    Off,
    /// Off by default until opted in.
    OptIn,
    /// Configured but not started this session.
    NotStarted,
    /// Never checked: no cached catalog yet.
    #[serde(other)]
    Unknown,
}

impl McpServerState {
    /// The page's status label.
    pub fn label(self) -> &'static str {
        match self {
            Self::Ready => "Connected",
            Self::OnDemand => "Starts on first use",
            Self::Connecting => "Connecting",
            Self::Failed => "Failed",
            Self::NeedsLogin => "Sign-in required",
            Self::Off => "Off",
            Self::OptIn => "Off (optional)",
            Self::NotStarted => "Not started",
            Self::Unknown => "Not checked yet",
        }
    }

    /// Whether the server is usable by the next turn.
    pub fn healthy(self) -> bool {
        matches!(self, Self::Ready | Self::OnDemand | Self::Connecting)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpToolRow {
    pub name: String,
    #[serde(default)]
    pub description: String,
}

/// One configured server.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpServerRow {
    pub name: String,
    /// project | global | imported | session
    #[serde(default)]
    pub source: String,
    /// stdio | http
    #[serde(default)]
    pub transport: String,
    /// Command basename or URL origin.
    #[serde(default)]
    pub origin: String,
    #[serde(default = "yes")]
    pub enabled: bool,
    pub state: McpServerState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    /// The server's own last error line after a failed reconnect.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    /// none | bearer | oauth | unknown
    #[serde(default)]
    pub auth: String,
    #[serde(default)]
    pub tool_count: usize,
    #[serde(default)]
    pub tools: Vec<McpToolRow>,
}

fn yes() -> bool {
    true
}

/// `graff mcp … --json` output.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct McpServerList {
    #[serde(default)]
    pub version: u32,
    pub servers: Vec<McpServerRow>,
}

/// What `McpServerAction` does to a server.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum McpServerVerb {
    /// A fresh handshake; refreshes the server's cached tools.
    Reconnect,
    Enable,
    Disable,
    /// OAuth sign-in for a remote server (opens the browser on the host).
    Login,
}

impl McpServerVerb {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Reconnect => "reconnect",
            Self::Enable => "enable",
            Self::Disable => "disable",
            Self::Login => "login",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn graff_status_json_parses_and_unknown_states_degrade() {
        let json = r#"{"version":1,"servers":[
            {"name":"codedb","source":"global","transport":"stdio","origin":"codedb","enabled":true,
             "state":"on_demand","auth":"none","toolCount":1,"tools":[{"name":"search","description":"Find."}]},
            {"name":"lic","source":"global","transport":"stdio","origin":"lic","enabled":true,"state":"failed",
             "error":"the server exited during startup","errorCode":"WriteFailed","detail":"lic: not licensed",
             "auth":"none","toolCount":0,"tools":[]},
            {"name":"future","state":"some_new_state"}]}"#;
        let list: McpServerList = serde_json::from_str(json).unwrap();
        assert_eq!(list.servers.len(), 3);
        assert_eq!(list.servers[0].state, McpServerState::OnDemand);
        assert_eq!(list.servers[0].tools[0].name, "search");
        assert_eq!(list.servers[1].detail.as_deref(), Some("lic: not licensed"));
        assert_eq!(list.servers[1].error_code.as_deref(), Some("WriteFailed"));
        assert_eq!(list.servers[2].state, McpServerState::Unknown);
        assert!(list.servers[2].enabled);
    }
}
