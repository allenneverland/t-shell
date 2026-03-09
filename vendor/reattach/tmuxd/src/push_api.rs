use std::sync::atomic::Ordering;

use axum::{
    extract::{Path, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::IntoResponse,
    Json,
};
use chrono::Utc;

use crate::{
    db::Database,
    error::{AppError, AppResult},
    models::{
        ApnsEvent, CreateMuteRequest, EventSource, IngestEventRequest, IngestEventResponse,
        IosMetricsIngestRequest, RegisterDeviceRequest,
    },
    state::AppState,
};

pub async fn healthz() -> &'static str {
    "ok"
}

pub async fn metrics(State(state): State<AppState>) -> impl IntoResponse {
    (
        [(
            header::CONTENT_TYPE,
            HeaderValue::from_static("text/plain; version=0.0.4; charset=utf-8"),
        )],
        state.metrics.render_prometheus(),
    )
}

pub async fn metrics_json(State(state): State<AppState>) -> Json<crate::metrics::MetricsSnapshot> {
    Json(state.metrics.snapshot())
}

pub async fn register_device(
    State(state): State<AppState>,
    Json(req): Json<RegisterDeviceRequest>,
) -> AppResult<Json<crate::models::RegisterDeviceResponse>> {
    let response = state.db.register_device_direct(req)?;
    Ok(Json(response))
}

pub async fn ingest_bell(
    State(state): State<AppState>,
    Json(req): Json<IngestEventRequest>,
) -> AppResult<Json<IngestEventResponse>> {
    ingest_event(&state, req, EventSource::Bell).await
}

pub async fn ingest_agent(
    State(state): State<AppState>,
    Json(req): Json<IngestEventRequest>,
) -> AppResult<Json<IngestEventResponse>> {
    ingest_event(&state, req, EventSource::Agent).await
}

pub async fn create_mute(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<CreateMuteRequest>,
) -> AppResult<Json<crate::models::CreateMuteResponse>> {
    let token = authorize_device_api(&state.db, &headers)?;
    let response = state.db.create_mute(&token.subject_id, req)?;
    Ok(Json(response))
}

pub async fn list_mutes(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> AppResult<Json<Vec<crate::models::MuteRule>>> {
    let token = authorize_device_api(&state.db, &headers)?;
    let response = state.db.list_mutes(&token.subject_id)?;
    Ok(Json(response))
}

pub async fn delete_mute(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(mute_id): Path<String>,
) -> AppResult<StatusCode> {
    let token = authorize_device_api(&state.db, &headers)?;
    let deleted = state.db.delete_mute(&token.subject_id, &mute_id)?;
    if deleted {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(AppError::NotFound("mute rule not found".to_string()))
    }
}

pub async fn ingest_ios_metrics(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<IosMetricsIngestRequest>,
) -> AppResult<StatusCode> {
    let _token = authorize_device_api(&state.db, &headers)?;
    validate_ios_metrics_request(&req)?;

    state.metrics.observe_ios_routing(
        req.notification_tap_total,
        req.route_success_total,
        req.route_fallback_total,
    );

    Ok(StatusCode::NO_CONTENT)
}

async fn ingest_event(
    state: &AppState,
    req: IngestEventRequest,
    source: EventSource,
) -> AppResult<Json<IngestEventResponse>> {
    if source == EventSource::Bell {
        state
            .metrics
            .events_bell_total
            .fetch_add(1, Ordering::Relaxed);
    } else {
        state
            .metrics
            .events_agent_total
            .fetch_add(1, Ordering::Relaxed);
    }

    let IngestEventRequest {
        pane_target,
        title,
        body,
        event_ts,
    } = req;
    let event_ts = event_ts.unwrap_or_else(Utc::now);
    let (title, body) = resolve_event_text(source, title, body, pane_target.as_deref());

    let event = ApnsEvent {
        source,
        title,
        body,
        pane_target,
        event_ts,
    };

    let candidates = state.db.list_all_devices()?;

    let mut muted = 0u64;
    let mut deliverable = Vec::new();
    for device in candidates {
        let is_muted =
            state
                .db
                .is_muted(&device.device_id, source, event.pane_target.as_deref())?;
        if is_muted {
            muted += 1;
        } else {
            deliverable.push(device);
        }
    }

    let attempted = deliverable.len() as u64;
    let (delivered, failed) = if let Some(apns) = &state.apns {
        let dispatch = apns.send_to_devices(&deliverable, &event).await;

        if !dispatch.invalid_device_ids.is_empty() {
            state
                .metrics
                .invalid_token_detected_total
                .fetch_add(dispatch.invalid_device_ids.len() as u64, Ordering::Relaxed);
            let removed = state.db.revoke_devices(&dispatch.invalid_device_ids)?;
            state
                .metrics
                .invalid_token_removed_total
                .fetch_add(removed, Ordering::Relaxed);
        }

        (dispatch.sent, dispatch.failed)
    } else {
        tracing::warn!("APNs not configured; dropping event");
        (0, attempted)
    };

    state
        .metrics
        .apns_sent_total
        .fetch_add(delivered, Ordering::Relaxed);
    state
        .metrics
        .apns_failed_total
        .fetch_add(failed, Ordering::Relaxed);

    let now = Utc::now();
    if now >= event.event_ts {
        let latency_ms = (now - event.event_ts).num_milliseconds().max(0) as u64;
        state.metrics.observe_latency_ms(latency_ms);
    }

    Ok(Json(IngestEventResponse {
        attempted,
        muted,
        delivered,
        failed,
    }))
}

fn resolve_event_text(
    source: EventSource,
    title: Option<String>,
    body: Option<String>,
    pane_target: Option<&str>,
) -> (String, String) {
    let title = title.unwrap_or_else(|| default_event_title(source, pane_target));
    let body = body.unwrap_or_else(|| default_event_body(source));
    (title, body)
}

fn default_event_title(source: EventSource, pane_target: Option<&str>) -> String {
    match source {
        EventSource::Bell => {
            format_bell_title(pane_target).unwrap_or_else(|| "tmux bell".to_string())
        }
        EventSource::Agent => "Coding Agent".to_string(),
    }
}

fn default_event_body(source: EventSource) -> String {
    match source {
        EventSource::Bell => "tmux bell".to_string(),
        EventSource::Agent => "Waiting for input".to_string(),
    }
}

fn format_bell_title(pane_target: Option<&str>) -> Option<String> {
    let pane_target = pane_target?.trim();
    let (session, window_pane) = pane_target.split_once(':')?;
    let (window, pane) = window_pane.split_once('.')?;
    if session.is_empty() || window.is_empty() || pane.is_empty() {
        return None;
    }
    if !window.chars().all(|ch| ch.is_ascii_digit()) || !pane.chars().all(|ch| ch.is_ascii_digit())
    {
        return None;
    }

    Some(format!(
        "session={} window={} pane={}",
        session, window, pane
    ))
}

fn authorize_device_api(
    db: &Database,
    headers: &HeaderMap,
) -> AppResult<crate::models::TokenRecord> {
    let bearer = bearer_token(headers)?;
    let token = db.validate_token(&bearer, &[Database::token_scope_device_api()])?;
    if token.consumed_at.is_some() {
        return Err(AppError::unauthorized("device token already consumed"));
    }
    Ok(token)
}

fn bearer_token(headers: &HeaderMap) -> AppResult<String> {
    let value = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .ok_or_else(|| AppError::unauthorized("missing Authorization header"))?;

    let token = value
        .strip_prefix("Bearer ")
        .ok_or_else(|| AppError::unauthorized("invalid Authorization scheme"))?
        .trim();

    if token.is_empty() {
        return Err(AppError::unauthorized("empty bearer token"));
    }

    Ok(token.to_string())
}

fn validate_ios_metrics_request(req: &IosMetricsIngestRequest) -> AppResult<()> {
    const MAX_DELTA: u64 = 1_000_000;
    let values = [
        req.notification_tap_total,
        req.route_success_total,
        req.route_fallback_total,
    ];

    if values.iter().all(|v| *v == 0) {
        return Err(AppError::bad_request(
            "at least one iOS metric delta must be greater than zero",
        ));
    }

    if values.iter().any(|v| *v > MAX_DELTA) {
        return Err(AppError::bad_request(format!(
            "iOS metric delta must be <= {} per request",
            MAX_DELTA
        )));
    }

    Ok(())
}
