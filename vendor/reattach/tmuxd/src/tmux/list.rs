use serde::Serialize;
use std::process::Command;

use crate::tmux::TmuxError;

#[derive(Debug, Serialize)]
pub struct Pane {
    pub index: u32,
    pub active: bool,
    pub target: String,
    pub current_path: String,
    pub pane_activity: i64,
    pub current_command: String,
    pub preview_text: String,
}

#[derive(Debug, Serialize)]
pub struct Window {
    pub index: u32,
    pub name: String,
    pub active: bool,
    pub panes: Vec<Pane>,
}

#[derive(Debug, Serialize)]
pub struct Session {
    pub name: String,
    pub attached: bool,
    pub windows: Vec<Window>,
}

#[derive(Debug)]
struct ParsedPaneRow {
    session_name: String,
    session_attached: bool,
    window_index: u32,
    window_name: String,
    window_active: bool,
    pane_index: u32,
    pane_active: bool,
    current_path: String,
    pane_activity: i64,
    current_command: String,
}

fn parse_session_attached(value: &str) -> bool {
    value.parse::<u32>().map(|count| count > 0).unwrap_or(false)
}

fn parse_pane_activity(value: &str) -> Result<i64, TmuxError> {
    value.parse::<i64>().map_err(|_| {
        TmuxError::IncompatibleRuntime {
            detail: "tmux list-panes did not return a valid pane_activity value. Upgrade tmux/tmuxd to a version that supports #{pane_activity}.".to_string(),
            missing_capabilities: vec!["pane_activity".to_string()],
        }
    })
}

fn parse_pane_row(line: &str) -> Result<Option<ParsedPaneRow>, TmuxError> {
    if line.trim().is_empty() {
        return Ok(None);
    }

    let parts: Vec<&str> = line.splitn(10, '|').collect();
    if parts.len() != 10 {
        return Ok(None);
    }

    Ok(Some(ParsedPaneRow {
        session_name: parts[0].to_string(),
        session_attached: parse_session_attached(parts[1]),
        window_index: parts[2].parse().unwrap_or(0),
        window_name: parts[3].to_string(),
        window_active: parts[4] == "1",
        pane_index: parts[5].parse().unwrap_or(0),
        pane_active: parts[6] == "1",
        current_path: parts[7].to_string(),
        pane_activity: parse_pane_activity(parts[8])?,
        current_command: parts[9].trim().to_string(),
    }))
}

fn capture_pane_preview_text(target: &str) -> String {
    let output = Command::new("tmux")
        .args(["capture-pane", "-p", "-t", target, "-S", "-40"])
        .output();
    let Ok(output) = output else {
        return String::new();
    };
    if !output.status.success() {
        return String::new();
    }

    let raw = String::from_utf8_lossy(&output.stdout);
    for line in raw.lines().rev() {
        let clean = sanitize_preview_line(line);
        if !clean.is_empty() {
            return truncate_preview_text(&clean, 140);
        }
    }
    String::new()
}

fn sanitize_preview_line(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    let mut chars = raw.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '\u{1b}' {
            if chars.peek().copied() == Some('[') {
                let _ = chars.next();
                for esc_ch in chars.by_ref() {
                    if ('@'..='~').contains(&esc_ch) {
                        break;
                    }
                }
            }
            continue;
        }
        if ch.is_control() && ch != '\t' {
            continue;
        }
        out.push(if ch == '\t' { ' ' } else { ch });
    }
    out.trim().to_string()
}

fn truncate_preview_text(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        return value.to_string();
    }
    let mut result = value
        .chars()
        .take(max_chars.saturating_sub(1))
        .collect::<String>();
    result.push('…');
    result
}

fn infer_missing_capabilities_from_error(stderr: &str) -> Vec<String> {
    let lower = stderr.to_lowercase();
    let mut missing = Vec::new();
    if lower.contains("pane_activity") {
        missing.push("pane_activity".to_string());
    }
    if lower.contains("pane_current_command") || lower.contains("current_command") {
        missing.push("pane_current_command".to_string());
    }
    missing.sort();
    missing.dedup();
    missing
}

pub fn list_sessions() -> Result<Vec<Session>, TmuxError> {
    let output = Command::new("tmux")
        .args([
            "list-panes",
            "-a",
            "-F",
            "#{session_name}|#{session_attached}|#{window_index}|#{window_name}|#{window_active}|#{pane_index}|#{pane_active}|#{pane_current_path}|#{pane_activity}|#{pane_current_command}",
        ])
        .output()
        .map_err(TmuxError::Io)?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if stderr.contains("no server running")
            || stderr.contains("no sessions")
            || stderr.contains("No such file or directory")
        {
            return Ok(vec![]);
        }
        let missing_capabilities = infer_missing_capabilities_from_error(&stderr);
        if !missing_capabilities.is_empty() || stderr.to_lowercase().contains("unknown format") {
            return Err(TmuxError::IncompatibleRuntime {
                detail: format!(
                    "tmux list-panes failed for pane inbox runtime capability requirements: {}",
                    stderr.trim()
                ),
                missing_capabilities,
            });
        }
        return Err(TmuxError::Command(stderr.to_string()));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut sessions: Vec<Session> = Vec::new();

    for line in stdout.lines() {
        let Some(parsed) = parse_pane_row(line)? else {
            continue;
        };

        let target = format!(
            "{}:{}.{}",
            parsed.session_name, parsed.window_index, parsed.pane_index
        );
        let preview_text = {
            let preview = capture_pane_preview_text(&target);
            if !preview.is_empty() {
                preview
            } else {
                truncate_preview_text(&sanitize_preview_line(&parsed.current_command), 140)
            }
        };

        let pane = Pane {
            index: parsed.pane_index,
            active: parsed.pane_active,
            target,
            current_path: parsed.current_path,
            pane_activity: parsed.pane_activity,
            current_command: parsed.current_command,
            preview_text,
        };

        let session = sessions.iter_mut().find(|s| s.name == parsed.session_name);
        match session {
            Some(session) => {
                let window = session
                    .windows
                    .iter_mut()
                    .find(|w| w.index == parsed.window_index);
                match window {
                    Some(window) => {
                        window.panes.push(pane);
                    }
                    None => {
                        session.windows.push(Window {
                            index: parsed.window_index,
                            name: parsed.window_name,
                            active: parsed.window_active,
                            panes: vec![pane],
                        });
                    }
                }
            }
            None => {
                sessions.push(Session {
                    name: parsed.session_name,
                    attached: parsed.session_attached,
                    windows: vec![Window {
                        index: parsed.window_index,
                        name: parsed.window_name,
                        active: parsed.window_active,
                        panes: vec![pane],
                    }],
                });
            }
        }
    }

    Ok(sessions)
}

#[cfg(test)]
mod tests {
    use super::{
        infer_missing_capabilities_from_error, parse_pane_activity, parse_session_attached,
        sanitize_preview_line, truncate_preview_text,
    };
    use crate::tmux::TmuxError;

    #[test]
    fn parse_session_attached_treats_positive_counts_as_attached() {
        assert!(!parse_session_attached("0"));
        assert!(parse_session_attached("1"));
        assert!(parse_session_attached("2"));
    }

    #[test]
    fn parse_session_attached_rejects_invalid_values() {
        assert!(!parse_session_attached(""));
        assert!(!parse_session_attached("attached"));
    }

    #[test]
    fn parse_pane_activity_accepts_valid_unix_timestamps() {
        assert_eq!(parse_pane_activity("0").unwrap(), 0);
        assert_eq!(parse_pane_activity("1719000000").unwrap(), 1719000000);
    }

    #[test]
    fn parse_pane_activity_rejects_invalid_values() {
        let error = parse_pane_activity("not-a-number").unwrap_err();
        match error {
            TmuxError::IncompatibleRuntime {
                detail,
                missing_capabilities,
            } => {
                assert!(detail.contains("pane_activity"));
                assert_eq!(missing_capabilities, vec!["pane_activity".to_string()]);
            }
            _ => panic!("expected command error"),
        }
    }

    #[test]
    fn infer_missing_capabilities_from_error_detects_known_fields() {
        let inferred = infer_missing_capabilities_from_error(
            "unknown format: pane_activity and pane_current_command",
        );
        assert_eq!(
            inferred,
            vec![
                "pane_activity".to_string(),
                "pane_current_command".to_string()
            ]
        );
    }

    #[test]
    fn sanitize_preview_line_removes_ansi_and_control_bytes() {
        let line = "\u{1b}[31mhello\u{1b}[0m\tworld\u{7}";
        assert_eq!(sanitize_preview_line(line), "hello world");
    }

    #[test]
    fn truncate_preview_text_adds_ellipsis_when_needed() {
        assert_eq!(truncate_preview_text("abcdef", 4), "abc…");
        assert_eq!(truncate_preview_text("abc", 4), "abc");
    }
}
