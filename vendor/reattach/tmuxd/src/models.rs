use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
pub struct StartPairingRequest {
    pub device_id: String,
    pub device_name: String,
    pub server_name: String,
}

#[derive(Debug, Serialize)]
pub struct StartPairingResponse {
    pub pairing_id: String,
    pub pairing_token: String,
    pub device_register_token: String,
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
pub struct CompletePairingRequest {
    pub pairing_token: String,
    pub host_name: String,
    pub platform: String,
}

#[derive(Debug, Serialize)]
pub struct CompletePairingResponse {
    pub host_id: String,
    pub ingest_token: String,
    pub ingest_url: String,
}

#[derive(Debug, Deserialize)]
pub struct RegisterDeviceRequest {
    pub token: String,
    #[serde(default)]
    pub sandbox: bool,
    pub device_id: String,
    #[serde(default)]
    pub device_name: Option<String>,
    pub server_name: String,
}

#[derive(Debug, Serialize)]
pub struct RegisterDeviceResponse {
    pub registration_id: String,
    pub device_api_token: String,
}

#[derive(Debug, Deserialize)]
pub struct IngestEventRequest {
    pub pane_target: Option<String>,
    pub title: Option<String>,
    pub body: Option<String>,
    pub event_ts: Option<DateTime<Utc>>,
}

#[derive(Debug, Serialize)]
pub struct IngestEventResponse {
    pub attempted: u64,
    pub muted: u64,
    pub delivered: u64,
    pub failed: u64,
}

#[derive(Debug, Deserialize)]
pub struct IosMetricsIngestRequest {
    #[serde(default)]
    pub notification_tap_total: u64,
    #[serde(default)]
    pub route_success_total: u64,
    #[serde(default)]
    pub route_fallback_total: u64,
}

#[derive(Debug, Deserialize)]
pub struct CreateMuteRequest {
    pub scope: MuteScope,
    pub session_name: Option<String>,
    pub pane_target: Option<String>,
    #[serde(default)]
    pub source: MuteSource,
    pub until: Option<DateTime<Utc>>,
}

#[derive(Debug, Serialize)]
pub struct CreateMuteResponse {
    pub id: String,
}

#[derive(Debug, Serialize)]
pub struct MuteRule {
    pub id: String,
    pub scope: MuteScope,
    pub session_name: Option<String>,
    pub pane_target: Option<String>,
    pub source: MuteSource,
    pub until: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum MuteScope {
    Host,
    Session,
    Pane,
}

impl MuteScope {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Host => "host",
            Self::Session => "session",
            Self::Pane => "pane",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum MuteSource {
    Bell,
    Agent,
    #[default]
    All,
}

impl MuteSource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Bell => "bell",
            Self::Agent => "agent",
            Self::All => "all",
        }
    }

    pub fn matches(self, source: EventSource) -> bool {
        match self {
            Self::All => true,
            Self::Bell => source == EventSource::Bell,
            Self::Agent => source == EventSource::Agent,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EventSource {
    Bell,
    Agent,
}

impl EventSource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Bell => "bell",
            Self::Agent => "agent",
        }
    }
}

#[derive(Debug, Clone)]
pub struct TokenRecord {
    pub id: String,
    pub scope: String,
    pub subject_id: String,
    pub consumed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone)]
pub struct DeviceRecord {
    pub id: String,
    pub device_id: String,
    pub server_name: String,
    pub apns_token: String,
    pub sandbox: bool,
}

#[derive(Debug, Clone)]
pub struct ApnsEvent {
    pub source: EventSource,
    pub title: String,
    pub body: String,
    pub pane_target: Option<String>,
    pub event_ts: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct DispatchResult {
    pub sent: u64,
    pub failed: u64,
    pub invalid_device_ids: Vec<String>,
}
