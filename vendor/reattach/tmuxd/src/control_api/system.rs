use axum::Json;
use serde::Serialize;

use crate::tmux;

const CAPABILITIES_SCHEMA_VERSION: u32 = 5;
const INPUT_EVENTS_MAX_BATCH: u32 = 128;

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
}

#[derive(Serialize)]
pub struct InputEventsCapability {
    pub enabled: bool,
    pub max_batch: u32,
    pub supports_repeat: bool,
}

#[derive(Serialize)]
pub struct EndpointCapabilities {
    pub healthz: bool,
    pub capabilities: bool,
    pub diagnostics: bool,
    pub sessions: bool,
    pub panes: bool,
    pub pane_input_events: bool,
    pub notify: bool,
}

pub async fn healthz() -> Json<HealthzResponse> {
    Json(HealthzResponse { status: "ok" })
}

pub async fn capabilities() -> Json<CapabilitiesResponse> {
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
        },
        endpoints: EndpointCapabilities {
            healthz: true,
            capabilities: true,
            diagnostics: true,
            sessions: true,
            panes: true,
            pane_input_events: true,
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
    };

    #[test]
    fn capabilities_json_includes_input_events_contract_fields() {
        let payload = CapabilitiesResponse {
            daemon: "tmuxd",
            version: "1.0.22",
            capabilities_schema_version: 5,
            features: FeatureCapabilities {
                input_events_v1: InputEventsCapability {
                    enabled: true,
                    max_batch: 128,
                    supports_repeat: true,
                },
            },
            endpoints: EndpointCapabilities {
                healthz: true,
                capabilities: true,
                diagnostics: true,
                sessions: true,
                panes: true,
                pane_input_events: true,
                notify: false,
            },
        };

        let value = serde_json::to_value(payload).expect("serialize capabilities payload");
        assert_eq!(
            value
                .get("capabilities_schema_version")
                .and_then(|v| v.as_u64()),
            Some(5)
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
                .pointer("/endpoints/pane_input_events")
                .and_then(|v| v.as_bool()),
            Some(true)
        );
        assert!(value.pointer("/features/shortcut_keys").is_none());
        assert!(value.pointer("/endpoints/pane_key").is_none());
    }
}
