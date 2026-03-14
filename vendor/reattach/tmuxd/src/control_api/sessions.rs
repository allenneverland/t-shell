use axum::{extract::State, http::StatusCode, Json};
use chrono::Utc;
use serde::{Deserialize, Serialize};

use crate::{db::PaneInboxSnapshot, state::AppState, tmux};

#[derive(Serialize)]
pub struct PaneResponse {
    pub index: u32,
    pub active: bool,
    pub target: String,
    pub current_path: String,
    pub pane_activity: i64,
    pub current_command: String,
    pub preview_text: String,
    pub has_unread_notification: bool,
    pub last_message_ts: i64,
}

#[derive(Serialize)]
pub struct WindowResponse {
    pub index: u32,
    pub name: String,
    pub active: bool,
    pub panes: Vec<PaneResponse>,
}

#[derive(Serialize)]
pub struct SessionResponse {
    pub name: String,
    pub attached: bool,
    pub windows: Vec<WindowResponse>,
}

#[derive(Deserialize)]
pub struct CreateSessionRequest {
    pub name: String,
    pub cwd: String,
}

#[derive(Debug, Serialize)]
pub struct ErrorResponse {
    pub code: &'static str,
    pub error: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub missing_capabilities: Vec<String>,
}

fn tmux_error_response(error: tmux::TmuxError) -> (StatusCode, Json<ErrorResponse>) {
    match error {
        tmux::TmuxError::IncompatibleRuntime {
            detail,
            missing_capabilities,
        } => (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(ErrorResponse {
                code: "incompatible_tmux_runtime",
                error: detail,
                missing_capabilities,
            }),
        ),
        tmux::TmuxError::Command(detail) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                code: "tmux_error",
                error: detail,
                missing_capabilities: Vec::new(),
            }),
        ),
        tmux::TmuxError::PayloadParse { detail } => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                code: "sessions_payload_parse_error",
                error: detail,
                missing_capabilities: Vec::new(),
            }),
        ),
        tmux::TmuxError::Io(detail) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                code: "tmux_io_error",
                error: detail.to_string(),
                missing_capabilities: Vec::new(),
            }),
        ),
    }
}

pub async fn list_sessions(
    State(state): State<AppState>,
) -> Result<Json<Vec<SessionResponse>>, (StatusCode, Json<ErrorResponse>)> {
    match tmux::list_sessions() {
        Ok(sessions) => {
            let pane_snapshots: Vec<PaneInboxSnapshot> = sessions
                .iter()
                .flat_map(|session| session.windows.iter())
                .flat_map(|window| window.panes.iter())
                .map(|pane| PaneInboxSnapshot {
                    pane_target: pane.target.clone(),
                    pane_activity: pane.pane_activity,
                    preview_text: pane.preview_text.clone(),
                })
                .collect();
            let last_message_ts_by_target = match state
                .db
                .resolve_pane_inbox_last_message_ts(&pane_snapshots, Utc::now())
            {
                Ok(values) => values,
                Err(e) => {
                    return Err((
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(ErrorResponse {
                            code: "db_error",
                            error: e.to_string(),
                            missing_capabilities: Vec::new(),
                        }),
                    ))
                }
            };
            let unread_targets = match state.db.list_unread_pane_targets() {
                Ok(values) => values,
                Err(e) => {
                    return Err((
                        StatusCode::INTERNAL_SERVER_ERROR,
                        Json(ErrorResponse {
                            code: "db_error",
                            error: e.to_string(),
                            missing_capabilities: Vec::new(),
                        }),
                    ))
                }
            };
            let response: Vec<SessionResponse> = sessions
                .into_iter()
                .map(|s| SessionResponse {
                    name: s.name,
                    attached: s.attached,
                    windows: s
                        .windows
                        .into_iter()
                        .map(|w| WindowResponse {
                            index: w.index,
                            name: w.name,
                            active: w.active,
                            panes: w
                                .panes
                                .into_iter()
                                .map(|p| {
                                    let target = p.target;
                                    let has_unread_notification = unread_targets.contains(&target);
                                    let pane_activity = p.pane_activity.max(0);
                                    let last_message_ts = last_message_ts_by_target
                                        .get(&target)
                                        .copied()
                                        .unwrap_or(pane_activity);
                                    PaneResponse {
                                        index: p.index,
                                        active: p.active,
                                        target,
                                        current_path: p.current_path,
                                        pane_activity,
                                        current_command: p.current_command,
                                        preview_text: p.preview_text,
                                        has_unread_notification,
                                        last_message_ts,
                                    }
                                })
                                .collect(),
                        })
                        .collect(),
                })
                .collect();
            Ok(Json(response))
        }
        Err(e) => Err(tmux_error_response(e)),
    }
}

pub async fn create_session(
    Json(payload): Json<CreateSessionRequest>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    match tmux::create_session(&payload.name, &payload.cwd) {
        Ok(()) => Ok(StatusCode::CREATED),
        Err(e) => Err(tmux_error_response(e)),
    }
}

#[cfg(test)]
mod tests {
    use super::{tmux_error_response, PaneResponse};
    use crate::tmux::TmuxError;
    use axum::http::StatusCode;

    #[test]
    fn incompatible_runtime_maps_to_422_with_machine_readable_code() {
        let (status, body) = tmux_error_response(TmuxError::IncompatibleRuntime {
            detail: "missing pane_activity".to_string(),
            missing_capabilities: vec!["pane_activity".to_string()],
        });
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(body.0.code, "incompatible_tmux_runtime");
        assert_eq!(
            body.0.missing_capabilities,
            vec!["pane_activity".to_string()]
        );
    }

    #[test]
    fn generic_tmux_error_maps_to_500_code() {
        let (status, body) = tmux_error_response(TmuxError::Command("tmux failed".to_string()));
        assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(body.0.code, "tmux_error");
    }

    #[test]
    fn payload_parse_error_maps_to_dedicated_500_code() {
        let (status, body) = tmux_error_response(TmuxError::PayloadParse {
            detail: "field count mismatch".to_string(),
        });
        assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(body.0.code, "sessions_payload_parse_error");
    }

    #[test]
    fn pane_response_serializes_last_message_timestamp() {
        let payload = PaneResponse {
            index: 1,
            active: true,
            target: "ops:1.1".to_string(),
            current_path: "/tmp".to_string(),
            pane_activity: 123,
            current_command: "bash".to_string(),
            preview_text: "hello".to_string(),
            has_unread_notification: false,
            last_message_ts: 456,
        };

        let value = serde_json::to_value(payload).expect("serialize pane response");
        assert_eq!(
            value.get("last_message_ts").and_then(|v| v.as_i64()),
            Some(456)
        );
    }
}
