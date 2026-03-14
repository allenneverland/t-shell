use axum::{extract::State, Json};
use serde::Serialize;

use crate::{state::AppState, tmux};

const CAPABILITIES_SCHEMA_VERSION: u32 = 9;
const INPUT_EVENTS_MAX_BATCH: u32 = 128;
const PANE_INBOX_REQUIRED_FIELDS: [&str; 5] = [
    "pane_activity",
    "current_command",
    "preview_text",
    "has_unread_notification",
    "last_message_ts",
];

#[derive(Serialize)]
pub struct HealthzResponse {
    pub status: &'static str,
}

#[derive(Serialize)]
pub struct CapabilitiesResponse {
    pub daemon: &'static str,
    pub version: &'static str,
    pub capabilities_schema_version: u32,
    pub features: FeatureCapabilities,
    pub endpoints: EndpointCapabilities,
}

#[derive(Serialize)]
pub struct FeatureCapabilities {
    pub input_events_v1: InputEventsCapability,
    pub pane_inbox_v1: PaneInboxCapability,
}

#[derive(Serialize)]
pub struct InputEventsCapability {
    pub enabled: bool,
    pub max_batch: u32,
    pub supports_repeat: bool,
}

#[derive(Serialize)]
pub struct PaneInboxCapability {
    pub enabled: bool,
    pub required_pane_fields: Vec<&'static str>,
    pub runtime_compatible: bool,
    pub minimum_tmux_version: String,
    pub detected_tmux_version: Option<String>,
    pub missing_capabilities: Vec<String>,
}

#[derive(Serialize)]
pub struct EndpointCapabilities {
    pub healthz: bool,
    pub capabilities: bool,
    pub diagnostics: bool,
    pub sessions: bool,
    pub panes: bool,
    pub pane_input_events: bool,
    pub push_self_test: bool,
    pub notify: bool,
}

pub async fn healthz() -> Json<HealthzResponse> {
    Json(HealthzResponse { status: "ok" })
}

pub async fn capabilities(State(_state): State<AppState>) -> Json<CapabilitiesResponse> {
    let runtime = tmux::pane_inbox_runtime_capability();
    Json(CapabilitiesResponse {
        daemon: "tmuxd",
        version: env!("CARGO_PKG_VERSION"),
        capabilities_schema_version: CAPABILITIES_SCHEMA_VERSION,
        features: FeatureCapabilities {
            input_events_v1: InputEventsCapability {
                enabled: true,
                max_batch: INPUT_EVENTS_MAX_BATCH,
                supports_repeat: true,
            },
            pane_inbox_v1: PaneInboxCapability {
                enabled: runtime.compatible,
                required_pane_fields: PANE_INBOX_REQUIRED_FIELDS.to_vec(),
                runtime_compatible: runtime.compatible,
                minimum_tmux_version: runtime.minimum_tmux_version,
                detected_tmux_version: runtime.detected_tmux_version,
                missing_capabilities: runtime.missing_capabilities,
            },
        },
        endpoints: EndpointCapabilities {
            healthz: true,
            capabilities: true,
            diagnostics: true,
            sessions: true,
            panes: true,
            pane_input_events: true,
            push_self_test: true,
            notify: false,
        },
    })
}

pub async fn diagnostics() -> Json<tmux::TmuxDiagnostics> {
    Json(tmux::collect_diagnostics())
}

#[cfg(test)]
mod tests {
    use super::{
        CapabilitiesResponse, EndpointCapabilities, FeatureCapabilities, InputEventsCapability,
        PaneInboxCapability,
    };

    #[test]
    fn capabilities_json_includes_input_events_contract_fields() {
        let payload = CapabilitiesResponse {
            daemon: "tmuxd",
            version: "1.0.22",
            capabilities_schema_version: 9,
            features: FeatureCapabilities {
                input_events_v1: InputEventsCapability {
                    enabled: true,
                    max_batch: 128,
                    supports_repeat: true,
                },
                pane_inbox_v1: PaneInboxCapability {
                    enabled: true,
                    required_pane_fields: vec![
                        "pane_activity",
                        "current_command",
                        "preview_text",
                        "has_unread_notification",
                        "last_message_ts",
                    ],
                    runtime_compatible: true,
                    minimum_tmux_version: "3.1.0".to_string(),
                    detected_tmux_version: Some("tmux 3.4".to_string()),
                    missing_capabilities: vec![],
                },
            },
            endpoints: EndpointCapabilities {
                healthz: true,
                capabilities: true,
                diagnostics: true,
                sessions: true,
                panes: true,
                pane_input_events: true,
                push_self_test: true,
                notify: false,
            },
        };

        let value = serde_json::to_value(payload).expect("serialize capabilities payload");
        assert_eq!(
            value
                .get("capabilities_schema_version")
                .and_then(|v| v.as_u64()),
            Some(9)
        );
        assert_eq!(
            value
                .pointer("/features/input_events_v1/enabled")
                .and_then(|v| v.as_bool()),
            Some(true)
        );
        assert_eq!(
            value
                .pointer("/features/input_events_v1/max_batch")
                .and_then(|v| v.as_u64()),
            Some(128)
        );
        assert_eq!(
            value
                .pointer("/features/input_events_v1/supports_repeat")
                .and_then(|v| v.as_bool()),
            Some(true)
        );
        assert_eq!(
            value
                .pointer("/features/pane_inbox_v1/enabled")
                .and_then(|v| v.as_bool()),
            Some(true)
        );
        assert_eq!(
            value
                .pointer("/features/pane_inbox_v1/runtime_compatible")
                .and_then(|v| v.as_bool()),
            Some(true)
        );
        assert_eq!(
            value
                .pointer("/features/pane_inbox_v1/required_pane_fields/0")
                .and_then(|v| v.as_str()),
            Some("pane_activity")
        );
        assert_eq!(
            value
                .pointer("/features/pane_inbox_v1/required_pane_fields/4")
                .and_then(|v| v.as_str()),
            Some("last_message_ts")
        );
        assert_eq!(
            value
                .pointer("/endpoints/pane_input_events")
                .and_then(|v| v.as_bool()),
            Some(true)
        );
        assert_eq!(
            value
                .pointer("/endpoints/push_self_test")
                .and_then(|v| v.as_bool()),
            Some(true)
        );
        assert!(value.pointer("/features/shortcut_keys").is_none());
        assert!(value.pointer("/endpoints/pane_key").is_none());
    }
}
