use axum::{extract::State, http::StatusCode, Json};
use serde::{Deserialize, Serialize};

use crate::{state::AppState, tmux};

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
                                    PaneResponse {
                                        index: p.index,
                                        active: p.active,
                                        target,
                                        current_path: p.current_path,
                                        pane_activity: p.pane_activity,
                                        current_command: p.current_command,
                                        preview_text: p.preview_text,
                                        has_unread_notification,
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
    use super::tmux_error_response;
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
}
