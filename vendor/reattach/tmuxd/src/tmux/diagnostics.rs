use serde::Serialize;
use std::env;
use std::path::PathBuf;
use std::process::{id, Command};

use crate::tmux;

#[derive(Debug, Serialize)]
pub struct TmuxDiagnostics {
    pub daemon_user: String,
    pub daemon_version: &'static str,
    pub process_pid: u32,
    pub process_executable: Option<String>,
    pub build_tag: Option<&'static str>,
    pub build_commit: Option<&'static str>,
    pub tmux_binary: Option<String>,
    pub tmux_socket: Option<String>,
    pub session_count: usize,
    pub can_list_sessions: bool,
    pub last_tmux_error: Option<String>,
}

pub fn collect_diagnostics() -> TmuxDiagnostics {
    let daemon_user = detect_daemon_user();
    let daemon_version = env!("CARGO_PKG_VERSION");
    let process_pid = id();
    let process_executable = detect_process_executable();
    let build_tag = option_env!("TMUXD_BUILD_TAG");
    let build_commit = option_env!("TMUXD_BUILD_COMMIT");
    let tmux_binary = detect_tmux_binary();
    let tmux_socket = detect_tmux_socket();

    let (session_count, can_list_sessions, last_tmux_error) = match tmux::list_sessions() {
        Ok(sessions) => (sessions.len(), true, None),
        Err(error) => (0, false, Some(error.to_string())),
    };

    TmuxDiagnostics {
        daemon_user,
        daemon_version,
        process_pid,
        process_executable,
        build_tag,
        build_commit,
        tmux_binary,
        tmux_socket,
        session_count,
        can_list_sessions,
        last_tmux_error,
    }
}

fn detect_daemon_user() -> String {
    if let Ok(user) = env::var("USER") {
        let trimmed = user.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
    }

    let output = Command::new("id").arg("-un").output();
    if let Ok(output) = output {
        if output.status.success() {
            let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !value.is_empty() {
                return value;
            }
        }
    }

    "unknown".to_string()
}

fn detect_tmux_binary() -> Option<String> {
    let path = env::var_os("PATH")?;
    for dir in env::split_paths(&path) {
        let candidate: PathBuf = dir.join("tmux");
        if candidate.is_file() {
            return Some(candidate.to_string_lossy().to_string());
        }
    }
    None
}

fn detect_tmux_socket() -> Option<String> {
    let output = Command::new("tmux")
        .args(["display-message", "-p", "#{socket_path}"])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}

fn detect_process_executable() -> Option<String> {
    std::env::current_exe()
        .ok()
        .map(|path| path.to_string_lossy().to_string())
}

#[cfg(test)]
mod tests {
    use super::TmuxDiagnostics;

    #[test]
    fn diagnostics_json_includes_process_and_build_fields() {
        let payload = TmuxDiagnostics {
            daemon_user: "alice".to_string(),
            daemon_version: "1.0.24",
            process_pid: 12345,
            process_executable: Some("/usr/local/bin/tmuxd".to_string()),
            build_tag: Some("v1.0.24"),
            build_commit: Some("abcdef0"),
            tmux_binary: Some("/usr/bin/tmux".to_string()),
            tmux_socket: Some("/tmp/tmux.sock".to_string()),
            session_count: 2,
            can_list_sessions: true,
            last_tmux_error: None,
        };

        let value = serde_json::to_value(payload).expect("serialize diagnostics payload");
        assert_eq!(
            value.get("daemon_version").and_then(|v| v.as_str()),
            Some("1.0.24")
        );
        assert_eq!(
            value.get("process_pid").and_then(|v| v.as_u64()),
            Some(12345)
        );
        assert_eq!(
            value.get("process_executable").and_then(|v| v.as_str()),
            Some("/usr/local/bin/tmuxd")
        );
        assert_eq!(
            value.get("build_tag").and_then(|v| v.as_str()),
            Some("v1.0.24")
        );
        assert_eq!(
            value.get("build_commit").and_then(|v| v.as_str()),
            Some("abcdef0")
        );
    }
}
