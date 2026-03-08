use axum::{
    extract::{Path, Query},
    http::StatusCode,
    Extension, Json,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::tmux;

pub type SharedKeyDispatchService = Arc<tmux::KeyDispatchService>;

const MAX_INPUT_EVENTS_BATCH: usize = 128;
const MAX_EVENT_KEY_LEN: usize = 64;
const MAX_EVENT_CODE_LEN: usize = 64;
const MAX_EVENT_TEXT_LEN: usize = 16;

#[derive(Deserialize)]
pub struct SendInputRequest {
    pub text: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct InputEventBatchRequest {
    pub events: Vec<InputEvent>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct InputEvent {
    pub action: InputEventAction,
    pub key: String,
    pub code: String,
    #[serde(default)]
    pub modifiers: InputEventModifiers,
    pub text: Option<String>,
    pub source: InputEventSource,
    pub timestamp_ms: Option<u64>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InputEventAction {
    Press,
    Repeat,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct InputEventModifiers {
    #[serde(default)]
    pub ctrl: bool,
    #[serde(default)]
    pub alt: bool,
    #[serde(default)]
    pub shift: bool,
    #[serde(default)]
    pub meta: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InputEventSource {
    SoftwareBar,
    HardwareKeyboard,
}

#[derive(Deserialize, Default)]
pub struct InputEventsQuery {
    pub probe: Option<bool>,
}

#[derive(Debug, Serialize)]
pub struct ErrorResponse {
    pub code: &'static str,
    pub error: String,
}

fn key_token_is_valid(token: &str) -> bool {
    let trimmed = token.trim();
    if trimmed.is_empty() || trimmed.len() > 64 {
        return false;
    }
    if trimmed != token {
        return false;
    }
    trimmed
        .chars()
        .all(|c| c.is_ascii() && !c.is_ascii_control() && !c.is_ascii_whitespace())
}

fn key_name_is_valid(value: &str, max_len: usize) -> bool {
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed != value || trimmed.len() > max_len {
        return false;
    }
    trimmed
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

fn key_value_is_valid(value: &str) -> bool {
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed != value || trimmed.len() > MAX_EVENT_KEY_LEN {
        return false;
    }

    let mut chars = trimmed.chars();
    if let Some(first) = chars.next() {
        if chars.next().is_none() {
            return first.is_ascii() && !first.is_ascii_control() && !first.is_ascii_whitespace();
        }
    }

    trimmed
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

fn text_payload_is_valid(text: &str) -> bool {
    if text.is_empty() || text.len() > MAX_EVENT_TEXT_LEN {
        return false;
    }
    text.chars().all(|c| c.is_ascii() && !c.is_ascii_control())
}

fn resolve_printable_base_from_text(text: Option<&str>) -> Option<String> {
    let text = text?;
    let mut chars = text.chars();
    let first = chars.next()?;
    if chars.next().is_some() {
        return None;
    }
    if !first.is_ascii() || first.is_ascii_control() {
        return None;
    }
    if first == ' ' {
        return Some("Space".to_string());
    }
    if first.is_ascii_alphabetic() {
        return Some(first.to_ascii_lowercase().to_string());
    }
    Some(first.to_string())
}

fn resolve_printable_base_from_key(key: &str) -> Option<String> {
    let mut chars = key.chars();
    let first = chars.next()?;
    if chars.next().is_some() {
        return None;
    }
    if !first.is_ascii() || first.is_ascii_control() || first.is_ascii_whitespace() {
        return None;
    }
    if first.is_ascii_alphabetic() {
        return Some(first.to_ascii_lowercase().to_string());
    }
    Some(first.to_string())
}

fn resolve_named_base_key(key: &str) -> Option<String> {
    let mapped = match key {
        "Enter" => Some("Enter"),
        "Escape" => Some("Escape"),
        "Tab" => Some("Tab"),
        "Backspace" => Some("BSpace"),
        "Delete" => Some("DC"),
        "Insert" => Some("IC"),
        "Space" => Some("Space"),
        "ArrowUp" => Some("Up"),
        "ArrowDown" => Some("Down"),
        "ArrowLeft" => Some("Left"),
        "ArrowRight" => Some("Right"),
        "Home" => Some("Home"),
        "End" => Some("End"),
        "PageUp" => Some("PageUp"),
        "PageDown" => Some("PageDown"),
        _ => None,
    };

    if let Some(mapped) = mapped {
        return Some(mapped.to_string());
    }

    if let Some(number) = key
        .strip_prefix('F')
        .and_then(|value| value.parse::<u8>().ok())
    {
        if (1..=24).contains(&number) {
            return Some(format!("F{number}"));
        }
    }

    None
}

fn input_event_to_tmux_token(event: &InputEvent) -> Result<String, &'static str> {
    let base = resolve_named_base_key(&event.key)
        .or_else(|| resolve_printable_base_from_text(event.text.as_deref()))
        .or_else(|| resolve_printable_base_from_key(&event.key))
        .ok_or("unsupported key")?;

    let mut prefixes: Vec<&'static str> = Vec::new();
    if event.modifiers.ctrl {
        prefixes.push("C");
    }
    if event.modifiers.alt || event.modifiers.meta {
        prefixes.push("M");
    }
    if event.modifiers.shift {
        prefixes.push("S");
    }

    let token = if prefixes.is_empty() {
        base
    } else {
        format!("{}-{base}", prefixes.join("-"))
    };

    if key_token_is_valid(&token) {
        Ok(token)
    } else {
        Err("generated invalid tmux token")
    }
}

fn validate_input_event(event: &InputEvent) -> Result<(), &'static str> {
    if !key_value_is_valid(&event.key) {
        return Err("invalid key");
    }

    if !key_name_is_valid(&event.code, MAX_EVENT_CODE_LEN) {
        return Err("invalid code");
    }

    if let Some(text) = &event.text {
        if !text_payload_is_valid(text) {
            return Err("invalid text");
        }
    }

    if event.timestamp_ms.is_none() {
        return Err("missing timestamp_ms");
    }

    Ok(())
}

fn invalid_input_event_error(index: usize, message: &str) -> (StatusCode, Json<ErrorResponse>) {
    (
        StatusCode::BAD_REQUEST,
        Json(ErrorResponse {
            code: "invalid_input_event",
            error: format!("event[{index}]: {message}"),
        }),
    )
}

fn unsupported_input_event_error(index: usize, message: &str) -> (StatusCode, Json<ErrorResponse>) {
    (
        StatusCode::UNPROCESSABLE_ENTITY,
        Json(ErrorResponse {
            code: "unsupported_input_event",
            error: format!("event[{index}]: {message}"),
        }),
    )
}

pub async fn send_input(
    Path(target): Path<String>,
    Json(payload): Json<SendInputRequest>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    match tmux::send_keys(&target, &payload.text) {
        Ok(()) => Ok(StatusCode::OK),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                code: "tmux_error",
                error: e.to_string(),
            }),
        )),
    }
}

pub async fn send_input_events(
    Extension(dispatcher): Extension<SharedKeyDispatchService>,
    Path(target): Path<String>,
    Query(query): Query<InputEventsQuery>,
    payload: Option<Json<InputEventBatchRequest>>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    if query.probe.unwrap_or(false) {
        return Ok(StatusCode::NO_CONTENT);
    }

    let payload = payload.ok_or((
        StatusCode::BAD_REQUEST,
        Json(ErrorResponse {
            code: "missing_input_events_payload",
            error: "missing input events payload".to_string(),
        }),
    ))?;

    if payload.events.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ErrorResponse {
                code: "missing_input_events_payload",
                error: "missing input events payload".to_string(),
            }),
        ));
    }

    if payload.events.len() > MAX_INPUT_EVENTS_BATCH {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(ErrorResponse {
                code: "too_many_input_events",
                error: format!("too many input events (max {MAX_INPUT_EVENTS_BATCH})"),
            }),
        ));
    }

    let mut tokens = Vec::with_capacity(payload.events.len());
    for (index, event) in payload.events.iter().enumerate() {
        validate_input_event(event).map_err(|message| invalid_input_event_error(index, message))?;
        let token = input_event_to_tmux_token(event)
            .map_err(|message| unsupported_input_event_error(index, message))?;
        tokens.push(token);
    }

    match dispatcher.enqueue_keys(target, tokens).await {
        Ok(()) => Ok(StatusCode::ACCEPTED),
        Err(tmux::KeyDispatchError::QueueFull) => Err((
            StatusCode::TOO_MANY_REQUESTS,
            Json(ErrorResponse {
                code: "key_dispatch_queue_full",
                error: "key dispatch queue is full".to_string(),
            }),
        )),
        Err(tmux::KeyDispatchError::Unavailable) => Err((
            StatusCode::SERVICE_UNAVAILABLE,
            Json(ErrorResponse {
                code: "key_dispatch_unavailable",
                error: "key dispatch service unavailable".to_string(),
            }),
        )),
        Err(tmux::KeyDispatchError::Tmux(error)) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                code: "tmux_error",
                error,
            }),
        )),
    }
}

pub async fn send_key_legacy(
    Path(_target): Path<String>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    Err((
        StatusCode::GONE,
        Json(ErrorResponse {
            code: "shortcut_contract_removed",
            error: "/panes/{target}/key has been removed; use /panes/{target}/input-events"
                .to_string(),
        }),
    ))
}

pub async fn send_keys_legacy(
    Path(_target): Path<String>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    Err((
        StatusCode::GONE,
        Json(ErrorResponse {
            code: "shortcut_contract_removed",
            error: "/panes/{target}/keys has been removed; use /panes/{target}/input-events"
                .to_string(),
        }),
    ))
}

pub async fn send_escape(
    Path(target): Path<String>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    match tmux::send_escape(&target) {
        Ok(()) => Ok(StatusCode::OK),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                code: "tmux_error",
                error: e.to_string(),
            }),
        )),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use axum::http::Uri;
    use axum::{
        extract::{Path, Query},
        Extension, Json,
    };

    use super::{
        input_event_to_tmux_token, send_input_events, send_key_legacy, InputEvent,
        InputEventAction, InputEventBatchRequest, InputEventModifiers, InputEventSource,
        InputEventsQuery,
    };
    use axum::http::StatusCode;

    fn event(key: &str, code: &str, text: Option<&str>) -> InputEvent {
        InputEvent {
            action: InputEventAction::Press,
            key: key.to_string(),
            code: code.to_string(),
            modifiers: InputEventModifiers::default(),
            text: text.map(ToString::to_string),
            source: InputEventSource::SoftwareBar,
            timestamp_ms: Some(1),
        }
    }

    #[test]
    fn maps_named_keys_and_modifiers_to_tmux_tokens() {
        let mut ctrl_c = event("c", "KeyC", Some("c"));
        ctrl_c.modifiers.ctrl = true;
        assert_eq!(input_event_to_tmux_token(&ctrl_c).unwrap(), "C-c");

        let mut alt_left = event("ArrowLeft", "ArrowLeft", None);
        alt_left.modifiers.alt = true;
        assert_eq!(input_event_to_tmux_token(&alt_left).unwrap(), "M-Left");

        let shift_tab = InputEvent {
            action: InputEventAction::Press,
            key: "Tab".to_string(),
            code: "Tab".to_string(),
            modifiers: InputEventModifiers {
                shift: true,
                ..InputEventModifiers::default()
            },
            text: None,
            source: InputEventSource::SoftwareBar,
            timestamp_ms: Some(1),
        };
        assert_eq!(input_event_to_tmux_token(&shift_tab).unwrap(), "S-Tab");
    }

    #[test]
    fn rejects_unsupported_keys() {
        let unsupported = event("UnknownKey", "UnknownKey", None);
        assert!(input_event_to_tmux_token(&unsupported).is_err());
    }

    #[tokio::test]
    async fn probe_returns_no_content() {
        let dispatcher = Arc::new(crate::tmux::KeyDispatchService::new(1));
        let result = send_input_events(
            Extension(dispatcher),
            Path("dev:0.0".to_string()),
            Query(InputEventsQuery { probe: Some(true) }),
            None,
        )
        .await;
        assert!(matches!(result, Ok(StatusCode::NO_CONTENT)));
    }

    #[tokio::test]
    async fn legacy_key_route_returns_gone() {
        let result = send_key_legacy(Path("dev:0.0".to_string())).await;
        assert!(matches!(result, Err((StatusCode::GONE, _))));
    }

    #[test]
    fn query_accepts_boolean_probe_flag() {
        let uri: Uri = "/panes/dev:0.0/input-events?probe=true"
            .parse()
            .expect("valid probe=true URI");
        let query = Query::<InputEventsQuery>::try_from_uri(&uri).expect("probe=true should parse");
        assert!(matches!(query.0.probe, Some(true)));
    }

    #[test]
    fn query_rejects_numeric_probe_flag() {
        let uri: Uri = "/panes/dev:0.0/input-events?probe=1"
            .parse()
            .expect("valid probe=1 URI");
        let query = Query::<InputEventsQuery>::try_from_uri(&uri);
        assert!(
            query.is_err(),
            "probe=1 must be rejected (bool-only contract)"
        );
    }

    #[tokio::test]
    async fn input_events_endpoint_rejects_empty_payload() {
        let dispatcher = Arc::new(crate::tmux::KeyDispatchService::new(1));
        let result = send_input_events(
            Extension(dispatcher),
            Path("dev:0.0".to_string()),
            Query(InputEventsQuery::default()),
            Some(Json(InputEventBatchRequest { events: vec![] })),
        )
        .await;

        assert!(matches!(result, Err((StatusCode::BAD_REQUEST, _))));
    }
}
