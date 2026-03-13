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
    pub error: String,
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
                            error: e.to_string(),
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
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                error: e.to_string(),
            }),
        )),
    }
}

pub async fn create_session(
    Json(payload): Json<CreateSessionRequest>,
) -> Result<StatusCode, (StatusCode, Json<ErrorResponse>)> {
    match tmux::create_session(&payload.name, &payload.cwd) {
        Ok(()) => Ok(StatusCode::CREATED),
        Err(e) => Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(ErrorResponse {
                error: e.to_string(),
            }),
        )),
    }
}
