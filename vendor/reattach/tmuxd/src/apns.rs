use a2::{
    Client, ClientConfig, DefaultNotificationBuilder, Endpoint, NotificationBuilder,
    NotificationOptions,
};
use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde_json::Value;
use std::io::Cursor;

use crate::config::ApnsConfig;
use crate::error::{AppError, AppResult};
use crate::models::{ApnsEvent, DeviceRecord, DispatchResult, EventSource};

const CUSTOM_KEY_HOST_ID: &str = "hostId";
const CUSTOM_KEY_SESSION_ID: &str = "sessionId";
const CUSTOM_KEY_PANE_ID: &str = "paneId";
const CUSTOM_KEY_DEVICE_ID: &str = "deviceId";
const CUSTOM_KEY_PANE_TARGET: &str = "paneTarget";
const CUSTOM_KEY_TITLE: &str = "title";
const CUSTOM_KEY_BODY: &str = "body";
const CUSTOM_KEY_EVENT_TS: &str = "eventTs";
const CUSTOM_KEY_SOURCE: &str = "source";
const CUSTOM_KEY_HOST_ID_SNAKE: &str = "host_id";
const CUSTOM_KEY_SESSION_ID_SNAKE: &str = "session_id";
const CUSTOM_KEY_PANE_ID_SNAKE: &str = "pane_id";
const CUSTOM_KEY_DEVICE_ID_SNAKE: &str = "device_id";
const CUSTOM_KEY_PANE_TARGET_SNAKE: &str = "pane_target";
const CUSTOM_KEY_EVENT_TS_SNAKE: &str = "event_ts";

pub struct ApnsService {
    sandbox_client: Client,
    production_client: Client,
    bundle_id: String,
}

impl ApnsService {
    pub fn new(config: &ApnsConfig) -> AppResult<Self> {
        let key_bytes = STANDARD
            .decode(&config.key_base64)
            .map_err(|e| AppError::internal(format!("invalid APNS_KEY_BASE64: {}", e)))?;
        let key = String::from_utf8(key_bytes)
            .map_err(|e| AppError::internal(format!("invalid APNS key UTF-8: {}", e)))?;

        let sandbox_client = create_client(&key, &config.key_id, &config.team_id, true)?;
        let production_client = create_client(&key, &config.key_id, &config.team_id, false)?;

        Ok(Self {
            sandbox_client,
            production_client,
            bundle_id: config.bundle_id.clone(),
        })
    }

    pub async fn send_to_devices(
        &self,
        devices: &[DeviceRecord],
        event: &ApnsEvent,
    ) -> DispatchResult {
        if devices.is_empty() {
            return DispatchResult {
                sent: 0,
                failed: 0,
                invalid_device_ids: Vec::new(),
            };
        }

        let options = NotificationOptions {
            apns_topic: Some(&self.bundle_id),
            ..Default::default()
        };

        let mut sent = 0u64;
        let mut failed = 0u64;
        let mut invalid_device_ids = Vec::new();

        'send_each_device: for device in devices {
            let title = build_notification_title(&device.server_name, &event.title, event.source);
            let builder = DefaultNotificationBuilder::new()
                .set_title(&title)
                .set_body(&event.body)
                .set_sound("default");

            let mut payload = builder.build(&device.apns_token, options.clone());
            for (key, value) in build_custom_data_entries(device, event) {
                if let Err(error) = payload.add_custom_data(key, &value) {
                    failed += 1;
                    tracing::error!(
                        device_id = %device.device_id,
                        key = %key,
                        ?error,
                        "failed to attach APNs custom payload data"
                    );
                    continue 'send_each_device;
                }
            }

            let client = if device.sandbox {
                &self.sandbox_client
            } else {
                &self.production_client
            };

            match client.send(payload).await {
                Ok(_) => {
                    sent += 1;
                }
                Err(a2::Error::ResponseError(ref response)) => {
                    if let Some(ref error_body) = response.error {
                        if error_body.reason == a2::ErrorReason::BadDeviceToken {
                            failed += 1;
                            invalid_device_ids.push(device.id.clone());
                            continue;
                        }
                    }
                    failed += 1;
                    tracing::error!(
                        token = %device.apns_token,
                        "APNs response error: {:?}",
                        response
                    );
                }
                Err(e) => {
                    failed += 1;
                    tracing::error!(token = %device.apns_token, "APNs send error: {:?}", e);
                }
            }
        }

        DispatchResult {
            sent,
            failed,
            invalid_device_ids,
        }
    }
}

fn build_custom_data_entries(
    device: &DeviceRecord,
    event: &ApnsEvent,
) -> Vec<(&'static str, Value)> {
    let mut entries = Vec::with_capacity(16);
    let host_id = device.server_name.clone();
    entries.push((CUSTOM_KEY_HOST_ID, Value::String(host_id.clone())));
    entries.push((CUSTOM_KEY_HOST_ID_SNAKE, Value::String(host_id)));
    entries.push((
        CUSTOM_KEY_DEVICE_ID,
        Value::String(device.device_id.clone()),
    ));
    entries.push((
        CUSTOM_KEY_DEVICE_ID_SNAKE,
        Value::String(device.device_id.clone()),
    ));
    if let Some(target) = &event.pane_target {
        entries.push((CUSTOM_KEY_PANE_TARGET, Value::String(target.clone())));
        entries.push((CUSTOM_KEY_PANE_TARGET_SNAKE, Value::String(target.clone())));
        entries.push((CUSTOM_KEY_PANE_ID, Value::String(target.clone())));
        entries.push((CUSTOM_KEY_PANE_ID_SNAKE, Value::String(target.clone())));
        if let Some((session, _)) = target.split_once(':') {
            if !session.trim().is_empty() {
                entries.push((CUSTOM_KEY_SESSION_ID, Value::String(session.to_string())));
                entries.push((
                    CUSTOM_KEY_SESSION_ID_SNAKE,
                    Value::String(session.to_string()),
                ));
            }
        }
    }
    entries.push((CUSTOM_KEY_TITLE, Value::String(event.title.clone())));
    entries.push((CUSTOM_KEY_BODY, Value::String(event.body.clone())));
    entries.push((
        CUSTOM_KEY_EVENT_TS,
        Value::String(event.event_ts.to_rfc3339()),
    ));
    entries.push((
        CUSTOM_KEY_EVENT_TS_SNAKE,
        Value::String(event.event_ts.to_rfc3339()),
    ));
    entries.push((
        CUSTOM_KEY_SOURCE,
        Value::String(event.source.as_str().to_string()),
    ));
    entries
}

fn create_client(key: &str, key_id: &str, team_id: &str, sandbox: bool) -> AppResult<Client> {
    let mut cursor = Cursor::new(key.as_bytes());
    let endpoint = if sandbox {
        Endpoint::Sandbox
    } else {
        Endpoint::Production
    };
    let client_config = ClientConfig::new(endpoint);
    Client::token(&mut cursor, key_id, team_id, client_config)
        .map_err(|e| AppError::internal(format!("failed to initialize APNs client: {}", e)))
}

fn build_notification_title(server_name: &str, title: &str, source: EventSource) -> String {
    if source == EventSource::Bell {
        return title.to_string();
    }

    if server_name.trim().is_empty() {
        return title.to_string();
    }

    let full = format!("{}: {}", server_name, title);
    const MAX_LEN: usize = 40;
    if full.chars().count() <= MAX_LEN {
        return full;
    }

    let prefix = format!("{}: ...", server_name);
    let remaining = MAX_LEN.saturating_sub(prefix.chars().count());
    let chars: Vec<char> = title.chars().collect();
    let skip = chars.len().saturating_sub(remaining);
    format!("{}{}", prefix, chars[skip..].iter().collect::<String>())
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use chrono::{TimeZone, Utc};
    use serde_json::Value;

    use super::{
        build_custom_data_entries, build_notification_title, CUSTOM_KEY_BODY, CUSTOM_KEY_DEVICE_ID,
        CUSTOM_KEY_DEVICE_ID_SNAKE, CUSTOM_KEY_EVENT_TS, CUSTOM_KEY_EVENT_TS_SNAKE,
        CUSTOM_KEY_HOST_ID, CUSTOM_KEY_HOST_ID_SNAKE, CUSTOM_KEY_PANE_ID, CUSTOM_KEY_PANE_ID_SNAKE,
        CUSTOM_KEY_PANE_TARGET, CUSTOM_KEY_PANE_TARGET_SNAKE, CUSTOM_KEY_SESSION_ID,
        CUSTOM_KEY_SESSION_ID_SNAKE, CUSTOM_KEY_SOURCE, CUSTOM_KEY_TITLE,
    };
    use crate::models::{ApnsEvent, DeviceRecord, EventSource};

    fn make_device() -> DeviceRecord {
        DeviceRecord {
            id: "row-1".to_string(),
            device_id: "ios-device-123".to_string(),
            server_name: "dev-server".to_string(),
            apns_token: "apns-token".to_string(),
            sandbox: true,
        }
    }

    fn make_event(pane_target: Option<&str>, source: EventSource) -> ApnsEvent {
        let event_ts = Utc
            .with_ymd_and_hms(2026, 3, 1, 10, 11, 12)
            .single()
            .expect("valid timestamp");
        ApnsEvent {
            source,
            title: "Bell".to_string(),
            body: "Pane bell detected".to_string(),
            pane_target: pane_target.map(str::to_string),
            event_ts,
        }
    }

    fn as_map(entries: Vec<(&'static str, Value)>) -> BTreeMap<&'static str, Value> {
        entries.into_iter().collect()
    }

    #[test]
    fn custom_data_contains_required_fields() {
        let device = make_device();
        let event = make_event(Some("work:0.1"), EventSource::Bell);
        let map = as_map(build_custom_data_entries(&device, &event));

        assert_eq!(
            map.get(CUSTOM_KEY_DEVICE_ID),
            Some(&Value::String("ios-device-123".to_string()))
        );
        assert_eq!(
            map.get(CUSTOM_KEY_DEVICE_ID_SNAKE),
            Some(&Value::String("ios-device-123".to_string()))
        );
        assert_eq!(
            map.get(CUSTOM_KEY_HOST_ID),
            Some(&Value::String("dev-server".to_string()))
        );
        assert_eq!(
            map.get(CUSTOM_KEY_HOST_ID_SNAKE),
            Some(&Value::String("dev-server".to_string()))
        );
        assert_eq!(
            map.get(CUSTOM_KEY_TITLE),
            Some(&Value::String("Bell".to_string()))
        );
        assert_eq!(
            map.get(CUSTOM_KEY_BODY),
            Some(&Value::String("Pane bell detected".to_string()))
        );
        assert_eq!(
            map.get(CUSTOM_KEY_SOURCE),
            Some(&Value::String("bell".to_string()))
        );
        assert_eq!(
            map.get(CUSTOM_KEY_EVENT_TS),
            Some(&Value::String(event.event_ts.to_rfc3339()))
        );
        assert_eq!(
            map.get(CUSTOM_KEY_EVENT_TS_SNAKE),
            Some(&Value::String(event.event_ts.to_rfc3339()))
        );
        assert_eq!(
            map.get(CUSTOM_KEY_PANE_ID),
            Some(&Value::String("work:0.1".to_string()))
        );
        assert_eq!(
            map.get(CUSTOM_KEY_PANE_ID_SNAKE),
            Some(&Value::String("work:0.1".to_string()))
        );
        assert_eq!(
            map.get(CUSTOM_KEY_SESSION_ID),
            Some(&Value::String("work".to_string()))
        );
        assert_eq!(
            map.get(CUSTOM_KEY_SESSION_ID_SNAKE),
            Some(&Value::String("work".to_string()))
        );
    }

    #[test]
    fn custom_data_includes_pane_target_when_present() {
        let device = make_device();
        let event = make_event(Some("main:1.0"), EventSource::Agent);
        let map = as_map(build_custom_data_entries(&device, &event));

        assert_eq!(
            map.get(CUSTOM_KEY_PANE_TARGET),
            Some(&Value::String("main:1.0".to_string()))
        );
        assert_eq!(
            map.get(CUSTOM_KEY_PANE_TARGET_SNAKE),
            Some(&Value::String("main:1.0".to_string()))
        );
        assert_eq!(
            map.get(CUSTOM_KEY_SOURCE),
            Some(&Value::String("agent".to_string()))
        );
    }

    #[test]
    fn custom_data_omits_pane_target_when_absent() {
        let device = make_device();
        let event = make_event(None, EventSource::Bell);
        let map = as_map(build_custom_data_entries(&device, &event));

        assert!(!map.contains_key(CUSTOM_KEY_PANE_TARGET));
        assert!(!map.contains_key(CUSTOM_KEY_PANE_TARGET_SNAKE));
        assert!(!map.contains_key(CUSTOM_KEY_PANE_ID));
        assert!(!map.contains_key(CUSTOM_KEY_PANE_ID_SNAKE));
        assert!(!map.contains_key(CUSTOM_KEY_SESSION_ID));
        assert!(!map.contains_key(CUSTOM_KEY_SESSION_ID_SNAKE));
    }

    #[test]
    fn build_title_keeps_short_text() {
        let title = build_notification_title("srv", "hello", EventSource::Agent);
        assert_eq!(title, "srv: hello");
    }

    #[test]
    fn bell_title_does_not_include_server_name_prefix() {
        let title =
            build_notification_title("srv", "session=dev window=3 pane=1", EventSource::Bell);
        assert_eq!(title, "session=dev window=3 pane=1");
    }
}
