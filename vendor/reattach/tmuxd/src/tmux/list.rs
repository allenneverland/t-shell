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
}

fn parse_session_attached(value: &str) -> bool {
    value.parse::<u32>().map(|count| count > 0).unwrap_or(false)
}

fn parse_pane_activity(value: &str) -> Result<i64, TmuxError> {
    value.parse::<i64>().map_err(|_| {
        TmuxError::Command(
            "tmux list-panes did not return a valid pane_activity value. Upgrade tmux/tmuxd to a version that supports #{pane_activity}.".to_string(),
        )
    })
}

fn parse_pane_row(line: &str) -> Result<Option<ParsedPaneRow>, TmuxError> {
    if line.trim().is_empty() {
        return Ok(None);
    }

    let parts: Vec<&str> = line.split('|').collect();
    if parts.len() != 9 {
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
    }))
}

pub fn list_sessions() -> Result<Vec<Session>, TmuxError> {
    let output = Command::new("tmux")
        .args([
            "list-panes",
            "-a",
            "-F",
            "#{session_name}|#{session_attached}|#{window_index}|#{window_name}|#{window_active}|#{pane_index}|#{pane_active}|#{pane_current_path}|#{pane_activity}",
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

        let pane = Pane {
            index: parsed.pane_index,
            active: parsed.pane_active,
            target,
            current_path: parsed.current_path,
            pane_activity: parsed.pane_activity,
        };

        let session = sessions
            .iter_mut()
            .find(|s| s.name == parsed.session_name);
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
    use super::{parse_pane_activity, parse_session_attached};
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
            TmuxError::Command(msg) => {
                assert!(msg.contains("pane_activity"));
            }
            _ => panic!("expected command error"),
        }
    }
}
