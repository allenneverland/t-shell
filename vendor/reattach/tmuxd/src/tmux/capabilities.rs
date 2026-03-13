use std::process::{Command, Output};
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

pub const REASON_RUNTIME_PROBE_TMUX_VERSION_UNAVAILABLE: &str =
    "runtime_probe_tmux_version_unavailable";
pub const REASON_RUNTIME_PROBE_TMUX_VERSION_UNSUPPORTED: &str =
    "runtime_probe_tmux_version_unsupported";
pub const REASON_RUNTIME_PROBE_CAPABILITY_QUERY_FAILED: &str =
    "runtime_probe_capability_query_failed";

const MINIMUM_TMUX_VERSION: (u32, u32, u32) = (3, 1, 0);
const MINIMUM_TMUX_VERSION_STRING: &str = "3.1.0";
const REQUIRED_CAPABILITIES: [&str; 2] = ["pane_activity", "pane_current_command"];

#[derive(Clone, Debug)]
pub struct PaneInboxRuntimeCapability {
    pub compatible: bool,
    pub minimum_tmux_version: String,
    pub detected_tmux_version: Option<String>,
    pub required_capabilities: Vec<String>,
    pub missing_capabilities: Vec<String>,
    pub reason_codes: Vec<String>,
    pub detail: String,
}

#[derive(Debug, Default)]
struct PaneFieldProbeResult {
    pane_activity_supported: bool,
    pane_current_command_supported: bool,
}

static PANE_INBOX_RUNTIME_CAPABILITY: OnceLock<PaneInboxRuntimeCapability> = OnceLock::new();

pub fn pane_inbox_runtime_capability() -> PaneInboxRuntimeCapability {
    PANE_INBOX_RUNTIME_CAPABILITY
        .get_or_init(detect_pane_inbox_runtime_capability)
        .clone()
}

fn detect_pane_inbox_runtime_capability() -> PaneInboxRuntimeCapability {
    let required = REQUIRED_CAPABILITIES
        .iter()
        .map(|value| (*value).to_string())
        .collect::<Vec<_>>();

    let version_output = match Command::new("tmux").arg("-V").output() {
        Ok(output) => output,
        Err(error) => {
            return incompatible_runtime(
                required.clone(),
                vec![REASON_RUNTIME_PROBE_TMUX_VERSION_UNAVAILABLE.to_string()],
                format!("failed to execute `tmux -V`: {error}"),
                None,
            )
        }
    };

    if !version_output.status.success() {
        return incompatible_runtime(
            required.clone(),
            vec![REASON_RUNTIME_PROBE_TMUX_VERSION_UNAVAILABLE.to_string()],
            format!(
                "`tmux -V` failed: {}",
                format_command_output(&version_output)
            ),
            None,
        );
    }

    let detected_tmux_version = String::from_utf8_lossy(&version_output.stdout)
        .trim()
        .to_string();
    let detected_tmux_version = if detected_tmux_version.is_empty() {
        None
    } else {
        Some(detected_tmux_version)
    };

    let Some(version) = detected_tmux_version
        .as_deref()
        .and_then(parse_tmux_version)
    else {
        return incompatible_runtime(
            required.clone(),
            vec![REASON_RUNTIME_PROBE_TMUX_VERSION_UNAVAILABLE.to_string()],
            "unable to parse tmux runtime version from `tmux -V` output".to_string(),
            detected_tmux_version,
        );
    };

    if version < MINIMUM_TMUX_VERSION {
        return incompatible_runtime(
            required.clone(),
            vec![REASON_RUNTIME_PROBE_TMUX_VERSION_UNSUPPORTED.to_string()],
            format!(
                "tmux runtime {}.{}.{} is older than required {}",
                version.0, version.1, version.2, MINIMUM_TMUX_VERSION_STRING
            ),
            detected_tmux_version,
        );
    }

    let probe = match probe_pane_field_capabilities() {
        Ok(result) => result,
        Err(detail) => {
            return incompatible_runtime(
                required.clone(),
                vec![REASON_RUNTIME_PROBE_CAPABILITY_QUERY_FAILED.to_string()],
                detail,
                detected_tmux_version,
            )
        }
    };

    let mut missing = Vec::new();
    if !probe.pane_activity_supported {
        missing.push("pane_activity".to_string());
    }
    if !probe.pane_current_command_supported {
        missing.push("pane_current_command".to_string());
    }

    if !missing.is_empty() {
        return incompatible_runtime(
            missing,
            vec![REASON_RUNTIME_PROBE_CAPABILITY_QUERY_FAILED.to_string()],
            "tmux runtime is missing pane inbox format capabilities".to_string(),
            detected_tmux_version,
        );
    }

    PaneInboxRuntimeCapability {
        compatible: true,
        minimum_tmux_version: MINIMUM_TMUX_VERSION_STRING.to_string(),
        detected_tmux_version,
        required_capabilities: required,
        missing_capabilities: Vec::new(),
        reason_codes: Vec::new(),
        detail: "tmux runtime satisfies pane inbox capability requirements".to_string(),
    }
}

fn incompatible_runtime(
    mut missing_capabilities: Vec<String>,
    reason_codes: Vec<String>,
    detail: String,
    detected_tmux_version: Option<String>,
) -> PaneInboxRuntimeCapability {
    missing_capabilities.sort();
    missing_capabilities.dedup();
    PaneInboxRuntimeCapability {
        compatible: false,
        minimum_tmux_version: MINIMUM_TMUX_VERSION_STRING.to_string(),
        detected_tmux_version,
        required_capabilities: REQUIRED_CAPABILITIES
            .iter()
            .map(|value| (*value).to_string())
            .collect(),
        missing_capabilities,
        reason_codes,
        detail,
    }
}

fn probe_pane_field_capabilities() -> Result<PaneFieldProbeResult, String> {
    let socket_name = format!(
        "tmuxd-probe-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
    );

    let create_output = Command::new("tmux")
        .args([
            "-L",
            socket_name.as_str(),
            "-f",
            "/dev/null",
            "new-session",
            "-d",
            "-s",
            "tmuxd_probe",
        ])
        .output()
        .map_err(|error| format!("failed to start isolated tmux probe server: {error}"))?;

    if !create_output.status.success() {
        return Err(format!(
            "failed to start isolated tmux probe server: {}",
            format_command_output(&create_output)
        ));
    }

    let probe_output = Command::new("tmux")
        .args([
            "-L",
            socket_name.as_str(),
            "list-panes",
            "-a",
            "-F",
            "#{pane_activity}|#{pane_current_command}",
        ])
        .output()
        .map_err(|error| {
            format!("failed to query pane capabilities via `tmux list-panes`: {error}")
        })?;

    let _ = Command::new("tmux")
        .args(["-L", socket_name.as_str(), "kill-server"])
        .output();

    if !probe_output.status.success() {
        return Err(format!(
            "`tmux list-panes` probe failed: {}",
            format_command_output(&probe_output)
        ));
    }

    let stdout = String::from_utf8_lossy(&probe_output.stdout);
    let line = stdout
        .lines()
        .find(|value| !value.trim().is_empty())
        .ok_or_else(|| "tmux list-panes probe returned no rows".to_string())?;
    Ok(parse_probe_line(line))
}

fn parse_probe_line(line: &str) -> PaneFieldProbeResult {
    let mut parts = line.splitn(2, '|');
    let pane_activity = parts.next().unwrap_or_default().trim();
    let pane_current_command = parts.next().unwrap_or_default().trim();

    PaneFieldProbeResult {
        pane_activity_supported: pane_activity.parse::<i64>().is_ok(),
        pane_current_command_supported: !pane_current_command.is_empty()
            && !pane_current_command.contains("#{pane_current_command}"),
    }
}

fn parse_tmux_version(raw: &str) -> Option<(u32, u32, u32)> {
    let mut started = false;
    let mut components: Vec<u32> = Vec::new();
    let mut current = String::new();

    for ch in raw.chars() {
        if ch.is_ascii_digit() {
            started = true;
            current.push(ch);
            continue;
        }

        if !started {
            continue;
        }

        if ch == '.' {
            if current.is_empty() {
                break;
            }
            components.push(current.parse::<u32>().ok()?);
            current.clear();
            if components.len() >= 3 {
                break;
            }
            continue;
        }

        break;
    }

    if !started {
        return None;
    }

    if !current.is_empty() {
        components.push(current.parse::<u32>().ok()?);
    }

    if components.is_empty() {
        return None;
    }

    Some((
        components[0],
        *components.get(1).unwrap_or(&0),
        *components.get(2).unwrap_or(&0),
    ))
}

fn format_command_output(output: &Output) -> String {
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
    if !stderr.is_empty() {
        return stderr;
    }
    if !stdout.is_empty() {
        return stdout;
    }
    "unknown command failure".to_string()
}

#[cfg(test)]
mod tests {
    use super::{parse_probe_line, parse_tmux_version};

    #[test]
    fn parse_tmux_version_accepts_plain_and_suffix_variants() {
        assert_eq!(parse_tmux_version("tmux 3.1"), Some((3, 1, 0)));
        assert_eq!(parse_tmux_version("tmux 3.3a"), Some((3, 3, 0)));
        assert_eq!(parse_tmux_version("tmux next-3.4.1"), Some((3, 4, 1)));
    }

    #[test]
    fn parse_tmux_version_rejects_invalid_values() {
        assert_eq!(parse_tmux_version("tmux"), None);
        assert_eq!(parse_tmux_version("version unknown"), None);
    }

    #[test]
    fn parse_probe_line_detects_missing_capabilities() {
        let supported = parse_probe_line("1719000000|zsh");
        assert!(supported.pane_activity_supported);
        assert!(supported.pane_current_command_supported);

        let missing_activity = parse_probe_line("#{pane_activity}|zsh");
        assert!(!missing_activity.pane_activity_supported);
        assert!(missing_activity.pane_current_command_supported);

        let missing_command = parse_probe_line("1719000000|#{pane_current_command}");
        assert!(missing_command.pane_activity_supported);
        assert!(!missing_command.pane_current_command_supported);
    }
}
