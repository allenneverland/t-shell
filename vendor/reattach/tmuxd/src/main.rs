mod apns;
mod config;
mod control_api;
mod db;
mod error;
mod metrics;
mod models;
mod push_api;
mod state;
mod tmux;
mod token;

use std::sync::Arc;

use axum::{
    extract::{Request, State},
    http::StatusCode,
    middleware::{self, Next},
    response::Response,
    routing::{delete, get, post},
    Extension, Router,
};
use clap::{Args, Parser, Subcommand, ValueEnum};
use config::ServeArgs;
use db::Database;
use error::AppResult;
use metrics::Metrics;
use state::AppState;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

const HOOK_NOTIFY_COMMAND: &str = "tmuxd notify";
const CODEX_NOTIFY_LINE: &str = "notify = [\"tmuxd\", \"notify\"]";

#[derive(Parser)]
#[command(name = "tmuxd")]
#[command(version)]
#[command(about = "Unified tmux control + APNs notification daemon")]
struct Cli {
    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// Run the tmuxd server
    Serve(ServeArgs),
    /// Send a push notification event to tmuxd
    Notify {
        /// Event source type (agent or bell)
        #[arg(long, value_enum, default_value = "agent")]
        source: NotifySource,
        /// Agent event JSON payload. If omitted, JSON is read from stdin.
        #[arg(long)]
        from_agent_json: Option<String>,
        /// Agent event JSON payload (positional compatibility)
        agent_json: Option<String>,
        /// Manual notification body (debug override)
        #[arg(long)]
        body: Option<String>,
        /// Manual notification title (debug override)
        #[arg(short, long)]
        title: Option<String>,
        /// Tmux pane target (e.g., "dev:0.0"). Auto-detected if running inside tmux.
        #[arg(long)]
        target: Option<String>,
        /// Server port (default: uses config.toml port, then 8787)
        #[arg(short, long)]
        port: Option<u16>,
        /// Service token. Falls back to TMUXD_SERVICE_TOKEN.
        #[arg(long)]
        service_token: Option<String>,
        /// Print success output (default is silent)
        #[arg(short, long)]
        verbose: bool,
    },
    /// Manage coding-agent and tmux bell notification hooks
    Hooks {
        #[command(subcommand)]
        action: Option<HookAction>,
    },
}

#[derive(Clone, Copy, ValueEnum)]
enum NotifySource {
    Agent,
    Bell,
}

impl NotifySource {
    fn as_path(self) -> &'static str {
        match self {
            Self::Agent => "agent",
            Self::Bell => "bell",
        }
    }
}

#[derive(Subcommand)]
enum HookAction {
    /// Install Claude Code + Codex + tmux alert-bell hooks
    Install,
    /// Uninstall Claude Code + Codex + tmux alert-bell hooks
    Uninstall,
    /// Verify tmux alert-bell hook status
    Verify(HookVerifyArgs),
}

#[derive(Args)]
struct HookVerifyArgs {
    /// Output verification report as JSON
    #[arg(long)]
    json: bool,
    /// Return non-zero when verification is not fully healthy
    #[arg(long)]
    strict: bool,
    /// Perform runtime bell probes (runtime hook trigger + raw BEL in tmux)
    #[arg(long)]
    probe_runtime: bool,
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "tmuxd=info".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    let result = match cli.command {
        Some(Commands::Serve(args)) => run_daemon(Some(args)).await,
        Some(Commands::Notify {
            source,
            from_agent_json,
            agent_json,
            body,
            title,
            target,
            port,
            service_token,
            verbose,
        }) => {
            run_notify_command(
                source,
                from_agent_json.or(agent_json),
                body,
                title,
                target,
                port,
                service_token,
                verbose,
            )
            .await;
            Ok(())
        }
        Some(Commands::Hooks { action }) => {
            run_hooks_command(action).map_err(error::AppError::internal)
        }
        None => run_daemon(None).await,
    };

    if let Err(err) = result {
        eprintln!("tmuxd fatal error: {}", err);
        std::process::exit(1);
    }
}

struct NotifyPayload {
    title: String,
    body: String,
    cwd: Option<String>,
    pane_target: Option<String>,
}

fn extract_last_assistant_message(transcript_path: &str) -> Option<String> {
    let content = std::fs::read_to_string(transcript_path).ok()?;
    for line in content.lines().rev() {
        let value: serde_json::Value = serde_json::from_str(line).ok()?;
        let role = value.get("type").and_then(|v| v.as_str()).unwrap_or("");
        if role != "assistant" {
            continue;
        }

        let texts = value
            .pointer("/message/content")
            .and_then(|v| v.as_array())
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| {
                        let t = item.get("type").and_then(|v| v.as_str())?;
                        if t != "text" {
                            return None;
                        }
                        item.get("text")
                            .and_then(|v| v.as_str())
                            .map(str::to_string)
                    })
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();

        if !texts.is_empty() {
            return Some(texts.join("\n"));
        }
    }
    None
}

fn parse_agent_notify_payload(input: &str) -> Result<Option<NotifyPayload>, String> {
    let value: serde_json::Value =
        serde_json::from_str(input).map_err(|e| format!("Invalid JSON input: {}", e))?;

    let event_type = value.get("type").and_then(|v| v.as_str());
    if let Some(t) = event_type {
        if t != "agent-turn-complete" {
            return Ok(None);
        }
    }

    let cwd = value
        .get("cwd")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty());

    let mut title = if let Some(agent) = value.get("agent").and_then(|v| v.as_str()) {
        if !agent.is_empty() {
            agent.to_string()
        } else if event_type.is_some() {
            "Codex".to_string()
        } else {
            "Coding Agent".to_string()
        }
    } else if event_type.is_some() {
        "Codex".to_string()
    } else {
        "Coding Agent".to_string()
    };

    let mut body = value
        .get("last-assistant-message")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Waiting for input".to_string());

    if body == "Waiting for input" {
        if let Some(path) = value.get("transcript_path").and_then(|v| v.as_str()) {
            if !path.is_empty() {
                if let Some(last) = extract_last_assistant_message(path) {
                    body = last;
                }
            }
        }
    }

    if let Some(ref c) = cwd {
        if let Some(dir_name) = std::path::Path::new(c).file_name().and_then(|v| v.to_str()) {
            title = dir_name.to_string();
        }
    }

    Ok(Some(NotifyPayload {
        title,
        body,
        cwd,
        pane_target: None,
    }))
}

fn auto_detect_tmux_target_from_env() -> Option<String> {
    let tmux_pane = std::env::var("TMUX_PANE").ok()?;
    let output = std::process::Command::new("tmux")
        .args([
            "display-message",
            "-p",
            "-t",
            &tmux_pane,
            "#{session_name}:#{window_index}.#{pane_index}",
        ])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8(output.stdout)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn auto_detect_tmux_target_from_cwd(cwd: &str) -> Option<String> {
    let output = std::process::Command::new("tmux")
        .args([
            "list-panes",
            "-a",
            "-F",
            "#{session_name}:#{window_index}.#{pane_index}:#{pane_current_path}",
        ])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }

    let out = String::from_utf8(output.stdout).ok()?;
    out.lines().find_map(|line| {
        line.rfind(':').and_then(|idx| {
            let (target, path_part) = line.split_at(idx);
            let path = path_part.strip_prefix(':').unwrap_or(path_part);
            if path == cwd {
                Some(target.to_string())
            } else {
                None
            }
        })
    })
}

fn title_for_target_and_cwd(target: &str, cwd: Option<&str>) -> String {
    if let Some(c) = cwd {
        if let Some(dir_name) = std::path::Path::new(c).file_name().and_then(|v| v.to_str()) {
            let session_window = target.split('.').next().unwrap_or(target);
            return format!("{} · {}", session_window, dir_name);
        }
    }
    target.to_string()
}

fn read_stdin_if_available() -> Option<String> {
    use std::io::IsTerminal;
    use std::io::Read;

    if std::io::stdin().is_terminal() {
        return None;
    }

    let mut input = String::new();
    if std::io::stdin().read_to_string(&mut input).is_ok() {
        let trimmed = input.trim().to_string();
        if !trimmed.is_empty() {
            return Some(trimmed);
        }
    }
    None
}

async fn run_notify_command(
    source: NotifySource,
    from_agent_json: Option<String>,
    body: Option<String>,
    title: Option<String>,
    target: Option<String>,
    port: Option<u16>,
    service_token: Option<String>,
    verbose: bool,
) {
    use serde_json::json;

    let mut payload = if body.is_some() || title.is_some() {
        NotifyPayload {
            title: title.unwrap_or_else(|| "TmuxChat".to_string()),
            body: body.unwrap_or_else(|| "Notification".to_string()),
            cwd: None,
            pane_target: None,
        }
    } else {
        let input = from_agent_json.or_else(read_stdin_if_available).unwrap_or_else(|| {
            eprintln!("No input provided.");
            eprintln!(
                "Use --from-agent-json '<json>' or pipe JSON via stdin, or pass --body/--title for debug."
            );
            std::process::exit(2);
        });

        match parse_agent_notify_payload(&input) {
            Ok(Some(p)) => p,
            Ok(None) => {
                // Non-target event type; skip as success.
                return;
            }
            Err(e) => {
                eprintln!("{}", e);
                std::process::exit(2);
            }
        }
    };

    let pane_target = target
        .or(payload.pane_target.clone())
        .or_else(auto_detect_tmux_target_from_env)
        .or_else(|| {
            payload
                .cwd
                .as_deref()
                .and_then(auto_detect_tmux_target_from_cwd)
        });

    if let Some(ref t) = pane_target {
        payload.title = title_for_target_and_cwd(t, payload.cwd.as_deref());
    }

    let token = service_token
        .or_else(|| std::env::var("TMUXD_SERVICE_TOKEN").ok())
        .or_else(|| config::Config::load(None).ok().map(|cfg| cfg.service_token))
        .unwrap_or_default();
    if token.trim().is_empty() {
        eprintln!("TMUXD_SERVICE_TOKEN is required for notify command.");
        std::process::exit(2);
    }

    let resolved_port = resolve_notify_port(port);
    let url = format!(
        "http://localhost:{}/v1/push/events/{}",
        resolved_port,
        source.as_path()
    );
    let body = json!({
        "title": payload.title,
        "body": payload.body,
        "pane_target": pane_target,
    });

    let client = reqwest::Client::new();
    match client
        .post(&url)
        .header("Authorization", format!("Bearer {}", token))
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await
    {
        Ok(response) => {
            if response.status().is_success() {
                if verbose {
                    if let Some(ref t) = pane_target {
                        println!("Notification sent successfully (target: {})", t);
                    } else {
                        println!("Notification sent successfully");
                    }
                }
            } else {
                eprintln!("Failed to send notification: HTTP {}", response.status());
                std::process::exit(1);
            }
        }
        Err(e) => {
            eprintln!("Failed to connect to tmuxd: {}", e);
            eprintln!(
                "Make sure tmuxd daemon is running on port {}",
                resolved_port
            );
            std::process::exit(1);
        }
    }
}

fn resolve_notify_port(port_override: Option<u16>) -> u16 {
    port_override.unwrap_or_else(config::notify_default_port)
}

async fn run_daemon(args: Option<ServeArgs>) -> AppResult<()> {
    let config = Arc::new(config::Config::load(args.as_ref())?);

    std::fs::create_dir_all(&config.data_dir)?;
    let db = Arc::new(Database::new(&config.db_path)?);

    let imported =
        db.import_legacy_device_tokens_once(config.legacy_device_tokens_file.as_deref())?;
    if imported > 0 {
        tracing::info!(imported, "imported legacy APNs device tokens");
    }

    let apns = if let Some(apns_config) = &config.apns {
        match apns::ApnsService::new(apns_config) {
            Ok(service) => {
                tracing::info!("APNs service initialized");
                Some(Arc::new(service))
            }
            Err(e) => {
                tracing::warn!("failed to initialize APNs service: {}", e);
                None
            }
        }
    } else {
        tracing::warn!(
            "APNs credentials are not configured; events will be accepted but not delivered"
        );
        None
    };

    let state = AppState {
        config: config.clone(),
        db,
        apns,
        metrics: Arc::new(Metrics::default()),
    };

    let key_dispatcher: control_api::SharedKeyDispatchService =
        Arc::new(tmux::KeyDispatchService::default());

    let control_routes = Router::new()
        .route("/v1/diagnostics", get(control_api::diagnostics))
        .route("/v1/tmux/sessions", get(control_api::list_sessions))
        .route("/v1/tmux/sessions", post(control_api::create_session))
        .route("/v1/tmux/panes/{target}", delete(control_api::delete_pane))
        .route(
            "/v1/tmux/panes/{target}/input",
            post(control_api::send_input),
        )
        .route(
            "/v1/tmux/panes/{target}/input-events",
            post(control_api::send_input_events),
        )
        .route(
            "/v1/tmux/panes/{target}/key",
            post(control_api::send_key_legacy),
        )
        .route(
            "/v1/tmux/panes/{target}/keys",
            post(control_api::send_keys_legacy),
        )
        .route(
            "/v1/tmux/panes/{target}/escape",
            post(control_api::send_escape),
        )
        .route(
            "/v1/tmux/panes/{target}/output",
            get(control_api::get_output),
        )
        .layer(Extension(key_dispatcher))
        .layer(middleware::from_fn_with_state(
            config.clone(),
            service_auth_middleware,
        ));

    let push_service_routes = Router::new()
        .route("/v1/push/devices/register", post(push_api::register_device))
        .route("/v1/push/events/bell", post(push_api::ingest_bell))
        .route("/v1/push/events/agent", post(push_api::ingest_agent))
        .layer(middleware::from_fn_with_state(
            config.clone(),
            service_auth_middleware,
        ));

    let push_device_api_routes = Router::new()
        .route("/v1/push/self-test", post(push_api::push_self_test))
        .route(
            "/v1/push/mutes",
            get(push_api::list_mutes).post(push_api::create_mute),
        )
        .route("/v1/push/mutes/{id}", delete(push_api::delete_mute))
        .route(
            "/v1/push/panes/{target}/read",
            post(push_api::mark_pane_read),
        )
        .route("/v1/push/metrics/ios", post(push_api::ingest_ios_metrics));

    let public_routes = Router::new()
        .route("/v1/healthz", get(control_api::healthz))
        .route("/v1/capabilities", get(control_api::capabilities))
        .route("/v1/metrics", get(push_api::metrics))
        .route("/v1/metrics.json", get(push_api::metrics_json));

    let app = public_routes
        .merge(control_routes)
        .merge(push_service_routes)
        .merge(push_device_api_routes)
        .with_state(state);

    let addr: std::net::SocketAddr = format!("{}:{}", config.bind_addr, config.port)
        .parse()
        .map_err(|e| error::AppError::internal(format!("invalid bind address: {}", e)))?;

    tracing::info!("starting tmuxd on {}", addr);
    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .map_err(|e| error::AppError::internal(format!("bind failed: {}", e)))?;

    axum::serve(listener, app)
        .await
        .map_err(|e| error::AppError::internal(format!("server failed: {}", e)))
}

async fn service_auth_middleware(
    State(config): State<Arc<config::Config>>,
    request: Request,
    next: Next,
) -> Result<Response, StatusCode> {
    let auth_header = request
        .headers()
        .get("Authorization")
        .and_then(|v| v.to_str().ok());

    let token = match auth_header {
        Some(header) if header.starts_with("Bearer ") => header[7..].trim(),
        _ => return Err(StatusCode::UNAUTHORIZED),
    };

    if token.is_empty() || token != config.service_token {
        return Err(StatusCode::UNAUTHORIZED);
    }

    Ok(next.run(request).await)
}

fn run_hooks_command(action: Option<HookAction>) -> Result<(), String> {
    match action.unwrap_or(HookAction::Install) {
        HookAction::Install => {
            install_claude_hooks();
            install_codex_hooks();
            install_tmux_bell_hook()
        }
        HookAction::Uninstall => {
            uninstall_claude_hooks();
            uninstall_codex_hooks();
            uninstall_tmux_bell_hook()
        }
        HookAction::Verify(args) => {
            let binary = std::env::current_exe()
                .ok()
                .and_then(|p| p.to_str().map(str::to_string))
                .unwrap_or_else(|| "tmuxd".to_string());
            let report = verify_tmux_bell_hook(&binary, args.probe_runtime);

            if args.json {
                let json = serde_json::to_string(&report)
                    .map_err(|e| format!("failed to serialize verify report: {e}"))?;
                println!("{json}");
            } else {
                println!(
                    "persistent_config_ok={}",
                    if report.persistent_config_ok {
                        "true"
                    } else {
                        "false"
                    }
                );
                println!(
                    "runtime_server_present={}",
                    if report.runtime_server_present {
                        "true"
                    } else {
                        "false"
                    }
                );
                println!(
                    "runtime_hook_ok={}",
                    if report.runtime_hook_ok {
                        "true"
                    } else {
                        "false"
                    }
                );
                println!(
                    "runtime_options_ok={}",
                    if report.runtime_options_ok {
                        "true"
                    } else {
                        "false"
                    }
                );
                println!(
                    "runtime_probe_performed={}",
                    if report.runtime_probe_performed {
                        "true"
                    } else {
                        "false"
                    }
                );
                println!(
                    "runtime_probe_hook_ok={}",
                    if report.runtime_probe_hook_ok {
                        "true"
                    } else {
                        "false"
                    }
                );
                println!(
                    "runtime_probe_raw_bel_ok={}",
                    if report.runtime_probe_raw_bel_ok {
                        "true"
                    } else {
                        "false"
                    }
                );
                println!(
                    "runtime_probe_compatible={}",
                    if report.runtime_probe_compatible {
                        "true"
                    } else {
                        "false"
                    }
                );
                println!("minimum_tmux_version={}", report.minimum_tmux_version);
                if let Some(version) = &report.detected_tmux_version {
                    println!("detected_tmux_version={version}");
                } else {
                    println!("detected_tmux_version=<unknown>");
                }
                println!(
                    "overall_ok={}",
                    if report.overall_ok { "true" } else { "false" }
                );
                if !report.required_capabilities.is_empty() {
                    println!("required_capabilities:");
                    for capability in &report.required_capabilities {
                        println!("  - {capability}");
                    }
                }
                if !report.missing_capabilities.is_empty() {
                    println!("missing_capabilities:");
                    for capability in &report.missing_capabilities {
                        println!("  - {capability}");
                    }
                }
                if !report.runtime_probe_reason_codes.is_empty() {
                    println!("runtime_probe_reason_codes:");
                    for code in &report.runtime_probe_reason_codes {
                        println!("  - {code}");
                    }
                }
                if !report.reasons.is_empty() {
                    println!("reasons:");
                    for reason in &report.reasons {
                        println!("  - {reason}");
                    }
                }
                if !report.warnings.is_empty() {
                    println!("warnings:");
                    for warning in &report.warnings {
                        println!("  - {warning}");
                    }
                }
            }

            if args.strict && !report.overall_ok {
                let detail = if !report.reasons.is_empty() {
                    report.reasons.join("; ")
                } else if !report.runtime_probe_reason_codes.is_empty() {
                    report.runtime_probe_reason_codes.join(", ")
                } else {
                    "unknown verification failure".to_string()
                };
                return Err(format!("tmux bell hook verification failed: {}", detail));
            }
            Ok(())
        }
    }
}

#[derive(serde::Serialize)]
struct HookVerifyReport {
    persistent_config_ok: bool,
    runtime_server_present: bool,
    runtime_hook_ok: bool,
    runtime_options_ok: bool,
    runtime_probe_performed: bool,
    runtime_probe_hook_ok: bool,
    runtime_probe_raw_bel_ok: bool,
    runtime_probe_compatible: bool,
    minimum_tmux_version: String,
    detected_tmux_version: Option<String>,
    required_capabilities: Vec<String>,
    missing_capabilities: Vec<String>,
    runtime_probe_reason_codes: Vec<String>,
    overall_ok: bool,
    reasons: Vec<String>,
    warnings: Vec<String>,
}

enum RuntimeHookProbe {
    HookOutput(String),
    ServerNotRunning(String),
    MissingTmuxBinary,
    QueryFailed(String),
}

#[derive(Default)]
struct RuntimeBellProbeReport {
    hook_ok: bool,
    raw_bel_ok: bool,
    reason_codes: Vec<String>,
    reasons: Vec<String>,
}

const REASON_RUNTIME_SERVER_NOT_RUNNING: &str = "runtime_server_not_running";
const REASON_RUNTIME_HOOK_EMPTY: &str = "runtime_hook_empty";
const REASON_RUNTIME_HOOK_NOT_ROUTED: &str = "runtime_hook_not_routed";
const REASON_RUNTIME_MONITOR_BELL_OFF: &str = "runtime_monitor_bell_off";
const REASON_RUNTIME_BELL_ACTION_NONE: &str = "runtime_bell_action_none";
const REASON_RUNTIME_OPTIONS_QUERY_FAILED: &str = "runtime_options_query_failed";
const REASON_RUNTIME_PROBE_SET_HOOK_FAILED: &str = "runtime_probe_set_hook_failed";
const REASON_RUNTIME_PROBE_TRIGGER_HOOK_FAILED: &str = "runtime_probe_trigger_hook_failed";
const REASON_RUNTIME_PROBE_TRIGGER_HOOK_NOT_OBSERVED: &str =
    "runtime_probe_trigger_hook_not_observed";
const REASON_RUNTIME_PROBE_NEW_WINDOW_FAILED: &str = "runtime_probe_new_window_failed";
const REASON_RUNTIME_PROBE_RAW_BEL_NOT_OBSERVED: &str = "runtime_probe_raw_bel_not_observed";
const REASON_RUNTIME_PROBE_RESTORE_HOOK_FAILED: &str = "runtime_probe_restore_hook_failed";

fn home_file(path: &str) -> Option<std::path::PathBuf> {
    let mut home = dirs::home_dir()?;
    home.push(path);
    Some(home)
}

fn ensure_claude_event_hook(
    hooks_obj: &mut serde_json::Map<String, serde_json::Value>,
    event_name: &str,
    matcher: &str,
) {
    let event = hooks_obj
        .entry(event_name.to_string())
        .or_insert_with(|| serde_json::json!([]));
    if !event.is_array() {
        *event = serde_json::json!([]);
    }
    let event_arr = event.as_array_mut().expect("array expected");

    let has_entry = event_arr.iter().any(|entry| {
        entry.get("matcher").and_then(|v| v.as_str()) == Some(matcher)
            && entry
                .get("hooks")
                .and_then(|v| v.as_array())
                .map(|arr| {
                    arr.iter().any(|h| {
                        h.get("type").and_then(|v| v.as_str()) == Some("command")
                            && h.get("command").and_then(|v| v.as_str())
                                == Some(HOOK_NOTIFY_COMMAND)
                    })
                })
                .unwrap_or(false)
    });

    if !has_entry {
        event_arr.push(serde_json::json!({
            "matcher": matcher,
            "hooks": [{
                "type": "command",
                "command": HOOK_NOTIFY_COMMAND,
                "timeout": 10
            }]
        }));
    }
}

fn prune_claude_event_hook(
    hooks_obj: &mut serde_json::Map<String, serde_json::Value>,
    event_name: &str,
) {
    let Some(event) = hooks_obj.get_mut(event_name) else {
        return;
    };
    let Some(event_arr) = event.as_array_mut() else {
        return;
    };

    event_arr.retain(|entry| {
        let has_tmux_chat_hook = entry
            .get("hooks")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter().any(|h| {
                    h.get("type").and_then(|v| v.as_str()) == Some("command")
                        && h.get("command").and_then(|v| v.as_str()) == Some(HOOK_NOTIFY_COMMAND)
                })
            })
            .unwrap_or(false);
        !has_tmux_chat_hook
    });
}

fn install_claude_hooks() {
    let claude_file = match home_file(".claude/settings.json") {
        Some(p) => p,
        None => {
            eprintln!("Failed to resolve home directory for Claude settings");
            return;
        }
    };
    if let Some(dir) = claude_file.parent() {
        if let Err(e) = std::fs::create_dir_all(dir) {
            eprintln!("Failed to create {}: {}", dir.display(), e);
            return;
        }
    }

    let mut root: serde_json::Value = if claude_file.exists() {
        match std::fs::read_to_string(&claude_file)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
        {
            Some(v) => v,
            None => serde_json::json!({}),
        }
    } else {
        serde_json::json!({})
    };

    if !root.is_object() {
        root = serde_json::json!({});
    }
    let root_obj = root.as_object_mut().expect("object expected");
    let hooks = root_obj
        .entry("hooks")
        .or_insert_with(|| serde_json::json!({}));
    if !hooks.is_object() {
        *hooks = serde_json::json!({});
    }
    let hooks_obj = hooks.as_object_mut().expect("object expected");
    ensure_claude_event_hook(hooks_obj, "Stop", "");
    ensure_claude_event_hook(hooks_obj, "Notification", "permission_prompt");

    match serde_json::to_string_pretty(&root)
        .ok()
        .and_then(|s| std::fs::write(&claude_file, format!("{}\n", s)).ok())
    {
        Some(_) => println!("Updated {}", claude_file.display()),
        None => eprintln!("Failed to write {}", claude_file.display()),
    }
}

fn uninstall_claude_hooks() {
    let claude_file = match home_file(".claude/settings.json") {
        Some(p) => p,
        None => {
            eprintln!("Failed to resolve home directory for Claude settings");
            return;
        }
    };
    if !claude_file.exists() {
        println!("No Claude settings file found");
        return;
    }

    let mut root: serde_json::Value = match std::fs::read_to_string(&claude_file)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
    {
        Some(v) => v,
        None => {
            eprintln!("Failed to parse {}", claude_file.display());
            return;
        }
    };
    if let Some(hooks) = root.get_mut("hooks").and_then(|v| v.as_object_mut()) {
        prune_claude_event_hook(hooks, "Stop");
        prune_claude_event_hook(hooks, "Notification");
    }

    match serde_json::to_string_pretty(&root)
        .ok()
        .and_then(|s| std::fs::write(&claude_file, format!("{}\n", s)).ok())
    {
        Some(_) => println!("Updated {}", claude_file.display()),
        None => eprintln!("Failed to write {}", claude_file.display()),
    }
}

fn install_codex_hooks() {
    let codex_file = match home_file(".codex/config.toml") {
        Some(p) => p,
        None => {
            eprintln!("Failed to resolve home directory for Codex config");
            return;
        }
    };
    if let Some(dir) = codex_file.parent() {
        if let Err(e) = std::fs::create_dir_all(dir) {
            eprintln!("Failed to create {}: {}", dir.display(), e);
            return;
        }
    }
    let existing = std::fs::read_to_string(&codex_file).unwrap_or_default();
    let has_other_notify = existing.lines().any(|line| {
        let t = line.trim();
        t.starts_with("notify =") && t != CODEX_NOTIFY_LINE
    });
    if has_other_notify {
        println!(
            "Skipped Codex update: notify is already configured in {}",
            codex_file.display()
        );
        println!("Add tmuxd manually if needed: {}", CODEX_NOTIFY_LINE);
        return;
    }

    let filtered: Vec<&str> = existing
        .lines()
        .filter(|line| {
            let t = line.trim();
            t != "# tmuxd push notification hook" && t != CODEX_NOTIFY_LINE
        })
        .collect();
    let mut out = format!("# tmuxd push notification hook\n{}\n", CODEX_NOTIFY_LINE);
    if !filtered.is_empty() {
        out.push('\n');
        out.push_str(&filtered.join("\n"));
        out.push('\n');
    }
    match std::fs::write(&codex_file, out) {
        Ok(_) => println!("Updated {}", codex_file.display()),
        Err(e) => eprintln!("Failed to write {}: {}", codex_file.display(), e),
    }
}

fn uninstall_codex_hooks() {
    let codex_file = match home_file(".codex/config.toml") {
        Some(p) => p,
        None => {
            eprintln!("Failed to resolve home directory for Codex config");
            return;
        }
    };
    if !codex_file.exists() {
        println!("No Codex config file found");
        return;
    }
    let existing = std::fs::read_to_string(&codex_file).unwrap_or_default();
    let filtered: Vec<&str> = existing
        .lines()
        .filter(|line| {
            let t = line.trim();
            t != "# tmuxd push notification hook" && t != CODEX_NOTIFY_LINE
        })
        .collect();
    let mut out = filtered.join("\n");
    if !out.is_empty() {
        out.push('\n');
    }
    match std::fs::write(&codex_file, out) {
        Ok(_) => println!("Updated {}", codex_file.display()),
        Err(e) => eprintln!("Failed to write {}: {}", codex_file.display(), e),
    }
}

const TMUX_MANAGED_START: &str = "# >>> TMUXD START >>>";
const TMUX_MANAGED_END: &str = "# <<< TMUXD END <<<";
const TMUX_BELL_TARGET_FORMAT: &str = "#{session_name}:#{window_index}.#{pane_index}";
const TMUX_BELL_TITLE: &str = "tmux bell";
const TMUX_BELL_BODY: &str = "tmux bell";

struct TmuxBellHookSpec {
    notify_shell_command: String,
    runtime_hook_command: String,
    persistent_hook_line: String,
}

fn install_tmux_bell_hook() -> Result<(), String> {
    let tmux_conf = match home_file(".tmux.conf") {
        Some(path) => path,
        None => {
            return Err("failed to resolve ~/.tmux.conf path".to_string());
        }
    };

    let existing = std::fs::read_to_string(&tmux_conf).unwrap_or_default();
    let binary = std::env::current_exe()
        .ok()
        .and_then(|p| p.to_str().map(str::to_string))
        .unwrap_or_else(|| "tmuxd".to_string());

    let hook_spec = build_tmux_bell_hook_spec(&binary);
    let managed = format!(
        "{TMUX_MANAGED_START}\nset-window-option -g monitor-bell on\nset-option -g bell-action any\n{}\n{TMUX_MANAGED_END}\n",
        hook_spec.persistent_hook_line
    );

    let updated = upsert_managed_tmux_block(&existing, &managed);
    if updated != existing {
        std::fs::write(&tmux_conf, updated)
            .map_err(|e| format!("failed to write {}: {e}", tmux_conf.display()))?;
        println!("Updated {}", tmux_conf.display());
    }

    match apply_runtime_tmux_bell_hook(&hook_spec.runtime_hook_command)? {
        RuntimeApplyResult::Applied => {
            println!("Applied tmux alert-bell runtime hook");
        }
        RuntimeApplyResult::NoServerRunning => {
            eprintln!(
                "tmux server is not running; persisted ~/.tmux.conf and skipped runtime hook apply"
            );
        }
    }

    let report = verify_tmux_bell_hook(&binary, false);
    if !report.persistent_config_ok {
        return Err(format!(
            "persistent tmux bell hook verification failed: {}",
            report.reasons.join("; ")
        ));
    }
    if report.runtime_server_present && (!report.runtime_hook_ok || !report.runtime_options_ok) {
        return Err(format!(
            "runtime tmux bell hook verification failed: {}",
            report.reasons.join("; ")
        ));
    }

    Ok(())
}

fn uninstall_tmux_bell_hook() -> Result<(), String> {
    let tmux_conf = match home_file(".tmux.conf") {
        Some(path) => path,
        None => {
            return Err("failed to resolve ~/.tmux.conf path".to_string());
        }
    };

    let existing = std::fs::read_to_string(&tmux_conf).unwrap_or_default();
    let updated = remove_managed_tmux_block(&existing);
    if updated != existing {
        std::fs::write(&tmux_conf, updated)
            .map_err(|e| format!("failed to write {}: {e}", tmux_conf.display()))?;
        println!("Updated {}", tmux_conf.display());
    }

    clear_runtime_tmux_bell_hook()?;
    Ok(())
}

fn verify_tmux_bell_hook(binary: &str, probe_runtime: bool) -> HookVerifyReport {
    let hook_spec = build_tmux_bell_hook_spec(binary);
    let expected_line = hook_spec.persistent_hook_line.clone();
    let legacy_line = format!("set-hook -g alert-bell {}", hook_spec.runtime_hook_command);
    let mut reasons = Vec::new();
    let mut warnings = Vec::new();
    let mut runtime_probe_reason_codes = Vec::new();
    let pane_inbox_runtime = tmux::pane_inbox_runtime_capability();
    let runtime_probe_compatible = pane_inbox_runtime.compatible;
    let minimum_tmux_version = pane_inbox_runtime.minimum_tmux_version.clone();
    let detected_tmux_version = pane_inbox_runtime.detected_tmux_version.clone();
    let required_capabilities = pane_inbox_runtime.required_capabilities.clone();
    let missing_capabilities = pane_inbox_runtime.missing_capabilities.clone();
    for code in &pane_inbox_runtime.reason_codes {
        push_unique(&mut runtime_probe_reason_codes, code.clone());
    }
    if probe_runtime && !runtime_probe_compatible {
        reasons.push(format!(
            "tmux runtime is incompatible with pane inbox requirements: {}",
            pane_inbox_runtime.detail
        ));
    }

    let persistent_config_ok = match home_file(".tmux.conf") {
        None => {
            reasons.push("unable to resolve ~/.tmux.conf path".to_string());
            false
        }
        Some(tmux_conf) => match std::fs::read_to_string(&tmux_conf) {
            Ok(contents) => {
                if let Some((start, end)) = managed_tmux_block_range(&contents) {
                    let block = &contents[start..end];
                    let hook_line = block
                        .lines()
                        .map(str::trim)
                        .find(|line| line.starts_with("set-hook -g alert-bell "));
                    if hook_line.is_none() {
                        reasons.push(
                            "managed tmux block is present but alert-bell hook line is missing"
                                .to_string(),
                        );
                        false
                    } else if !block.contains("notify --source bell") {
                        reasons.push(
                            "managed tmux block does not route alert-bell to `notify --source bell`"
                                .to_string(),
                        );
                        false
                    } else if hook_line == Some(legacy_line.as_str()) {
                        reasons.push(
                            "managed tmux block uses legacy alert-bell hook quoting that breaks `tmux source-file` with `set-hook: too many arguments`"
                                .to_string(),
                        );
                        false
                    } else if hook_line != Some(expected_line.as_str()) {
                        reasons.push(
                            "managed tmux block exists but alert-bell hook line does not match current tmuxd binary path or escaping format"
                                .to_string(),
                        );
                        false
                    } else {
                        true
                    }
                } else {
                    reasons.push("managed tmux block is missing from ~/.tmux.conf".to_string());
                    false
                }
            }
            Err(e) => {
                reasons.push(format!("failed to read ~/.tmux.conf: {e}"));
                false
            }
        },
    };

    let (runtime_server_present, runtime_hook_ok) = match probe_runtime_tmux_alert_hook() {
        RuntimeHookProbe::HookOutput(output) => {
            if output.contains("notify --source bell") {
                (true, true)
            } else if output.trim() == "alert-bell" {
                reasons.push(
                    "runtime alert-bell hook is empty (`tmux show-hooks` returned only `alert-bell`)"
                        .to_string(),
                );
                push_unique(
                    &mut runtime_probe_reason_codes,
                    REASON_RUNTIME_HOOK_EMPTY.to_string(),
                );
                (true, false)
            } else {
                reasons.push(format!(
                    "runtime alert-bell hook is present but not routed to tmuxd notify: {output}"
                ));
                push_unique(
                    &mut runtime_probe_reason_codes,
                    REASON_RUNTIME_HOOK_NOT_ROUTED.to_string(),
                );
                (true, false)
            }
        }
        RuntimeHookProbe::ServerNotRunning(detail) => {
            let warning = if !detail.is_empty() {
                format!("runtime tmux server is not running ({detail})")
            } else {
                "runtime tmux server is not running".to_string()
            };
            warnings.push(warning.clone());
            if probe_runtime {
                reasons.push(warning);
                push_unique(
                    &mut runtime_probe_reason_codes,
                    REASON_RUNTIME_SERVER_NOT_RUNNING.to_string(),
                );
            }
            (false, false)
        }
        RuntimeHookProbe::MissingTmuxBinary => {
            reasons.push("tmux binary is missing on host".to_string());
            (false, false)
        }
        RuntimeHookProbe::QueryFailed(detail) => {
            reasons.push(format!(
                "failed to inspect runtime alert-bell hook: {detail}"
            ));
            (false, false)
        }
    };

    let runtime_options_ok = if runtime_server_present {
        verify_runtime_tmux_bell_options(&mut reasons, &mut runtime_probe_reason_codes)
    } else {
        false
    };

    let mut runtime_probe_performed = false;
    let mut runtime_probe_hook_ok = !probe_runtime;
    let mut runtime_probe_raw_bel_ok = !probe_runtime;
    if probe_runtime && runtime_server_present {
        runtime_probe_performed = true;
        let probe = execute_runtime_tmux_bell_probe(&hook_spec.runtime_hook_command);
        runtime_probe_hook_ok = probe.hook_ok;
        runtime_probe_raw_bel_ok = probe.raw_bel_ok;
        for code in probe.reason_codes {
            push_unique(&mut runtime_probe_reason_codes, code);
        }
        reasons.extend(probe.reasons);
    }

    let overall_ok = if probe_runtime {
        persistent_config_ok
            && runtime_server_present
            && runtime_hook_ok
            && runtime_options_ok
            && runtime_probe_hook_ok
            && runtime_probe_raw_bel_ok
            && runtime_probe_compatible
    } else {
        persistent_config_ok && (!runtime_server_present || (runtime_hook_ok && runtime_options_ok))
    };

    HookVerifyReport {
        persistent_config_ok,
        runtime_server_present,
        runtime_hook_ok,
        runtime_options_ok,
        runtime_probe_performed,
        runtime_probe_hook_ok,
        runtime_probe_raw_bel_ok,
        runtime_probe_compatible,
        minimum_tmux_version,
        detected_tmux_version,
        required_capabilities,
        missing_capabilities,
        runtime_probe_reason_codes,
        overall_ok,
        reasons,
        warnings,
    }
}

enum RuntimeApplyResult {
    Applied,
    NoServerRunning,
}

fn apply_runtime_tmux_bell_hook(hook_command: &str) -> Result<RuntimeApplyResult, String> {
    ensure_tmux_binary_available()?;

    if !tmux_server_is_running()? {
        return Ok(RuntimeApplyResult::NoServerRunning);
    }

    run_tmux_command(
        &["set-window-option", "-g", "monitor-bell", "on"],
        "set monitor-bell",
    )?;
    run_tmux_command(
        &["set-option", "-g", "bell-action", "any"],
        "set bell-action",
    )?;
    enforce_runtime_tmux_bell_options()?;
    run_tmux_command(
        &["set-hook", "-g", "alert-bell", hook_command],
        "set alert-bell hook",
    )?;
    Ok(RuntimeApplyResult::Applied)
}

fn clear_runtime_tmux_bell_hook() -> Result<(), String> {
    ensure_tmux_binary_available()?;
    if !tmux_server_is_running()? {
        return Ok(());
    }
    run_tmux_command(&["set-hook", "-gu", "alert-bell"], "unset alert-bell hook")
}

fn ensure_tmux_binary_available() -> Result<(), String> {
    match std::process::Command::new("tmux").arg("-V").output() {
        Ok(output) => {
            if output.status.success() {
                Ok(())
            } else {
                Err(format!(
                    "tmux is not usable: {}",
                    format_tmux_command_output(&output)
                ))
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            Err("tmux command not found on host".to_string())
        }
        Err(e) => Err(format!("failed to execute `tmux -V`: {e}")),
    }
}

fn tmux_server_is_running() -> Result<bool, String> {
    let output = std::process::Command::new("tmux")
        .args(["list-sessions"])
        .output()
        .map_err(|e| format!("failed to execute `tmux list-sessions`: {e}"))?;
    if output.status.success() {
        return Ok(true);
    }
    let detail = format_tmux_command_output(&output);
    if is_tmux_no_server_output(&detail) {
        Ok(false)
    } else {
        Err(format!("`tmux list-sessions` failed: {detail}"))
    }
}

fn probe_runtime_tmux_alert_hook() -> RuntimeHookProbe {
    let output = match std::process::Command::new("tmux")
        .args(["show-hooks", "-g", "alert-bell"])
        .output()
    {
        Ok(output) => output,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return RuntimeHookProbe::MissingTmuxBinary;
        }
        Err(e) => return RuntimeHookProbe::QueryFailed(e.to_string()),
    };

    if output.status.success() {
        let stdout = String::from_utf8(output.stdout).unwrap_or_default();
        return RuntimeHookProbe::HookOutput(stdout.trim().to_string());
    }

    let detail = format_tmux_command_output(&output);
    if is_tmux_no_server_output(&detail) {
        return RuntimeHookProbe::ServerNotRunning(detail);
    }
    RuntimeHookProbe::QueryFailed(detail)
}

fn verify_runtime_tmux_bell_options(
    reasons: &mut Vec<String>,
    reason_codes: &mut Vec<String>,
) -> bool {
    let mut runtime_options_ok = true;

    let sessions = match tmux_list_sessions() {
        Ok(sessions) => sessions,
        Err(detail) => {
            runtime_options_ok = false;
            reasons.push(format!(
                "failed to inspect runtime tmux sessions for bell-action: {detail}"
            ));
            push_unique(
                reason_codes,
                REASON_RUNTIME_OPTIONS_QUERY_FAILED.to_string(),
            );
            Vec::new()
        }
    };

    for session in sessions {
        let context = format!("inspect bell-action for session {session}");
        match run_tmux_command_capture(
            &["show-options", "-v", "-t", session.as_str(), "bell-action"],
            context.as_str(),
        ) {
            Ok(value) => {
                if value.trim().eq_ignore_ascii_case("none") {
                    runtime_options_ok = false;
                    reasons.push(format!(
                        "runtime bell-action is disabled (`none`) for session `{session}`"
                    ));
                    push_unique(reason_codes, REASON_RUNTIME_BELL_ACTION_NONE.to_string());
                }
            }
            Err(detail) => {
                runtime_options_ok = false;
                reasons.push(format!(
                    "failed to read runtime bell-action for session `{session}`: {detail}"
                ));
                push_unique(
                    reason_codes,
                    REASON_RUNTIME_OPTIONS_QUERY_FAILED.to_string(),
                );
            }
        }
    }

    let windows = match tmux_list_windows() {
        Ok(windows) => windows,
        Err(detail) => {
            runtime_options_ok = false;
            reasons.push(format!(
                "failed to inspect runtime tmux windows for monitor-bell: {detail}"
            ));
            push_unique(
                reason_codes,
                REASON_RUNTIME_OPTIONS_QUERY_FAILED.to_string(),
            );
            Vec::new()
        }
    };

    for window in windows {
        let context = format!("inspect monitor-bell for window {window}");
        match run_tmux_command_capture(
            &[
                "show-window-options",
                "-v",
                "-t",
                window.as_str(),
                "monitor-bell",
            ],
            context.as_str(),
        ) {
            Ok(value) => {
                if !value.trim().eq_ignore_ascii_case("on") {
                    runtime_options_ok = false;
                    reasons.push(format!(
                        "runtime monitor-bell is not `on` for window `{window}` (actual: `{}`)",
                        value.trim()
                    ));
                    push_unique(reason_codes, REASON_RUNTIME_MONITOR_BELL_OFF.to_string());
                }
            }
            Err(detail) => {
                runtime_options_ok = false;
                reasons.push(format!(
                    "failed to read runtime monitor-bell for window `{window}`: {detail}"
                ));
                push_unique(
                    reason_codes,
                    REASON_RUNTIME_OPTIONS_QUERY_FAILED.to_string(),
                );
            }
        }
    }

    runtime_options_ok
}

fn execute_runtime_tmux_bell_probe(expected_hook_command: &str) -> RuntimeBellProbeReport {
    let mut report = RuntimeBellProbeReport::default();

    let probe_id = format!(
        "{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
    );
    let base_dir = std::env::temp_dir().join("tmuxd-runtime-probe");
    let _ = std::fs::create_dir_all(&base_dir);

    let trigger_hook_marker = base_dir.join(format!("trigger-hook-{probe_id}.ok"));
    let raw_bel_marker = base_dir.join(format!("raw-bell-{probe_id}.ok"));
    let _ = std::fs::remove_file(&trigger_hook_marker);
    let _ = std::fs::remove_file(&raw_bel_marker);

    let trigger_hook_script = format!(
        "touch {}",
        shell_escape_single_quoted(trigger_hook_marker.to_string_lossy().as_ref())
    );
    let trigger_probe_hook_command = format!(
        "run-shell -b {}",
        shell_escape_single_quoted(&trigger_hook_script)
    );
    let raw_bel_hook_script = format!(
        "touch {}",
        shell_escape_single_quoted(raw_bel_marker.to_string_lossy().as_ref())
    );
    let raw_bel_probe_hook_command = format!(
        "run-shell -b {}",
        shell_escape_single_quoted(&raw_bel_hook_script)
    );
    // Avoid send-keys timing races: run BEL from a detached one-shot window command.
    let raw_bel_probe_command = format!(
        "sh -lc {}",
        shell_escape_single_quoted("sleep 0.20; printf '\\a'; sleep 0.05")
    );

    if let Err(detail) = run_tmux_command(
        &[
            "set-hook",
            "-g",
            "alert-bell",
            trigger_probe_hook_command.as_str(),
        ],
        "configure runtime bell probe hook",
    ) {
        report.reasons.push(format!(
            "failed to configure runtime bell probe hook: {detail}"
        ));
        push_unique(
            &mut report.reason_codes,
            REASON_RUNTIME_PROBE_SET_HOOK_FAILED.to_string(),
        );
    } else {
        match run_tmux_command(
            &["set-hook", "-R", "-g", "alert-bell"],
            "execute runtime `set-hook -R alert-bell` probe",
        ) {
            Ok(()) => {
                if wait_for_file_marker(trigger_hook_marker.as_path(), 1500) {
                    report.hook_ok = true;
                } else {
                    report.reasons.push(
                        "runtime `set-hook -R alert-bell` probe did not execute hook payload"
                            .to_string(),
                    );
                    push_unique(
                        &mut report.reason_codes,
                        REASON_RUNTIME_PROBE_TRIGGER_HOOK_NOT_OBSERVED.to_string(),
                    );
                }
            }
            Err(detail) => {
                report.reasons.push(format!(
                    "runtime `set-hook -R alert-bell` probe failed: {detail}"
                ));
                push_unique(
                    &mut report.reason_codes,
                    REASON_RUNTIME_PROBE_TRIGGER_HOOK_FAILED.to_string(),
                );
            }
        }

        if let Err(detail) = run_tmux_command(
            &[
                "set-hook",
                "-g",
                "alert-bell",
                raw_bel_probe_hook_command.as_str(),
            ],
            "configure runtime raw BEL probe hook",
        ) {
            report.reasons.push(format!(
                "failed to configure runtime raw BEL probe hook: {detail}"
            ));
            push_unique(
                &mut report.reason_codes,
                REASON_RUNTIME_PROBE_SET_HOOK_FAILED.to_string(),
            );
        } else if let Some(session) = tmux_list_sessions().ok().and_then(|v| v.into_iter().next()) {
            let created_window = run_tmux_command_capture(
                &[
                    "new-window",
                    "-d",
                    "-t",
                    session.as_str(),
                    "-P",
                    "-F",
                    "#{session_name}:#{window_index}.#{pane_index}",
                    raw_bel_probe_command.as_str(),
                ],
                "create runtime raw BEL probe window",
            );

            match created_window {
                Ok(pane_target) => {
                    let pane_target = pane_target.trim().to_string();
                    let window_target = pane_target
                        .split('.')
                        .next()
                        .map(str::to_string)
                        .unwrap_or_else(|| pane_target.clone());

                    if let Err(detail) = run_tmux_command(
                        &[
                            "set-window-option",
                            "-t",
                            window_target.as_str(),
                            "monitor-bell",
                            "on",
                        ],
                        "set monitor-bell on probe window",
                    ) {
                        report.reasons.push(format!(
                            "failed to set monitor-bell on runtime raw BEL probe window: {detail}"
                        ));
                    }

                    if wait_for_file_marker(raw_bel_marker.as_path(), 2500) {
                        report.raw_bel_ok = true;
                    } else {
                        report.reasons.push(
                            "runtime raw BEL probe did not trigger `alert-bell` hook".to_string(),
                        );
                        push_unique(
                            &mut report.reason_codes,
                            REASON_RUNTIME_PROBE_RAW_BEL_NOT_OBSERVED.to_string(),
                        );
                    }

                    let _ = run_tmux_command(
                        &["kill-window", "-t", window_target.as_str()],
                        "cleanup runtime raw BEL probe window",
                    );
                }
                Err(detail) => {
                    report.reasons.push(format!(
                        "failed to create runtime raw BEL probe window: {detail}"
                    ));
                    push_unique(
                        &mut report.reason_codes,
                        REASON_RUNTIME_PROBE_NEW_WINDOW_FAILED.to_string(),
                    );
                }
            }
        } else {
            report
                .reasons
                .push("runtime raw BEL probe could not find an active tmux session".to_string());
            push_unique(
                &mut report.reason_codes,
                REASON_RUNTIME_SERVER_NOT_RUNNING.to_string(),
            );
        }
    }

    if let Err(detail) = run_tmux_command(
        &["set-hook", "-g", "alert-bell", expected_hook_command],
        "restore runtime alert-bell hook after probe",
    ) {
        report.reasons.push(format!(
            "failed to restore runtime alert-bell hook after probe: {detail}"
        ));
        push_unique(
            &mut report.reason_codes,
            REASON_RUNTIME_PROBE_RESTORE_HOOK_FAILED.to_string(),
        );
    }

    let _ = std::fs::remove_file(&trigger_hook_marker);
    let _ = std::fs::remove_file(&raw_bel_marker);
    report
}

fn wait_for_file_marker(path: &std::path::Path, timeout_ms: u64) -> bool {
    let mut waited = 0u64;
    while waited <= timeout_ms {
        if path.exists() {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
        waited = waited.saturating_add(50);
    }
    path.exists()
}

fn enforce_runtime_tmux_bell_options() -> Result<(), String> {
    for session in tmux_list_sessions()? {
        run_tmux_command(
            &["set-option", "-t", session.as_str(), "bell-action", "any"],
            format!("set bell-action for session {session}").as_str(),
        )?;
    }

    for window in tmux_list_windows()? {
        run_tmux_command(
            &[
                "set-window-option",
                "-t",
                window.as_str(),
                "monitor-bell",
                "on",
            ],
            format!("set monitor-bell for window {window}").as_str(),
        )?;
    }
    Ok(())
}

fn tmux_list_sessions() -> Result<Vec<String>, String> {
    run_tmux_capture_lines(
        &["list-sessions", "-F", "#{session_name}"],
        "list tmux sessions",
    )
}

fn tmux_list_windows() -> Result<Vec<String>, String> {
    run_tmux_capture_lines(
        &[
            "list-windows",
            "-a",
            "-F",
            "#{session_name}:#{window_index}",
        ],
        "list tmux windows",
    )
}

fn run_tmux_capture_lines(args: &[&str], context: &str) -> Result<Vec<String>, String> {
    let output = run_tmux_command_capture(args, context)?;
    Ok(output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect())
}

fn run_tmux_command_capture(args: &[&str], context: &str) -> Result<String, String> {
    let output = std::process::Command::new("tmux")
        .args(args)
        .output()
        .map_err(|e| format!("failed to execute `tmux` for {context}: {e}"))?;
    if output.status.success() {
        Ok(String::from_utf8(output.stdout).unwrap_or_default())
    } else {
        Err(format!(
            "tmux command failed while {context}: {}",
            format_tmux_command_output(&output)
        ))
    }
}

fn push_unique(values: &mut Vec<String>, value: String) {
    if !values.iter().any(|existing| existing == &value) {
        values.push(value);
    }
}

fn run_tmux_command(args: &[&str], context: &str) -> Result<(), String> {
    let output = std::process::Command::new("tmux")
        .args(args)
        .output()
        .map_err(|e| format!("failed to execute `tmux` for {context}: {e}"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "tmux command failed while {context}: {}",
            format_tmux_command_output(&output)
        ))
    }
}

fn format_tmux_command_output(output: &std::process::Output) -> String {
    let stderr = String::from_utf8(output.stderr.clone())
        .unwrap_or_default()
        .trim()
        .to_string();
    let stdout = String::from_utf8(output.stdout.clone())
        .unwrap_or_default()
        .trim()
        .to_string();
    let mut parts = Vec::new();
    if !stderr.is_empty() {
        parts.push(stderr);
    }
    if !stdout.is_empty() {
        parts.push(stdout);
    }
    if parts.is_empty() {
        return format!("exit status {}", output.status);
    }
    parts.join(" | ")
}

fn is_tmux_no_server_output(text: &str) -> bool {
    let lower = text.to_lowercase();
    lower.contains("no server running")
        || lower.contains("failed to connect to server")
        || (lower.contains("no such file or directory") && lower.contains("tmux-"))
}

fn upsert_managed_tmux_block(existing: &str, managed_block: &str) -> String {
    if let Some((start, end)) = managed_tmux_block_range(existing) {
        let mut merged = String::new();
        merged.push_str(&existing[..start]);
        merged.push_str(managed_block);
        merged.push_str(&existing[end..]);
        return merged;
    }

    if existing.trim().is_empty() {
        managed_block.to_string()
    } else if existing.ends_with('\n') {
        format!("{existing}\n{managed_block}")
    } else {
        format!("{existing}\n\n{managed_block}")
    }
}

fn remove_managed_tmux_block(existing: &str) -> String {
    if let Some((start, end)) = managed_tmux_block_range(existing) {
        let mut out = String::new();
        out.push_str(&existing[..start]);
        out.push_str(&existing[end..]);
        out
    } else {
        existing.to_string()
    }
}

fn managed_tmux_block_range(existing: &str) -> Option<(usize, usize)> {
    let start = existing.find(TMUX_MANAGED_START)?;
    let end_rel = existing[start..].find(TMUX_MANAGED_END)?;
    let mut end = start + end_rel + TMUX_MANAGED_END.len();
    if existing[end..].starts_with('\n') {
        end += 1;
    }
    Some((start, end))
}

fn build_tmux_bell_notify_command(binary: &str) -> String {
    let escaped_binary = shell_escape_double_quoted(binary);
    let escaped_target = shell_escape_double_quoted(TMUX_BELL_TARGET_FORMAT);
    let escaped_title = shell_escape_double_quoted(TMUX_BELL_TITLE);
    let escaped_body = shell_escape_double_quoted(TMUX_BELL_BODY);
    format!(
        "\"{}\" notify --source bell --target \"{}\" --title \"{}\" --body \"{}\"",
        escaped_binary, escaped_target, escaped_title, escaped_body
    )
}

fn build_tmux_bell_hook_spec(binary: &str) -> TmuxBellHookSpec {
    let notify_shell_command = build_tmux_bell_notify_command(binary);
    let runtime_hook_command = format!(
        "run-shell -b {}",
        shell_escape_single_quoted(&notify_shell_command)
    );
    let persistent_hook_line = format!(
        "set-hook -g alert-bell {}",
        tmux_escape_double_quoted_argument(&runtime_hook_command)
    );
    TmuxBellHookSpec {
        notify_shell_command,
        runtime_hook_command,
        persistent_hook_line,
    }
}

fn tmux_escape_double_quoted_argument(raw: &str) -> String {
    let mut escaped = String::with_capacity(raw.len() + 2);
    escaped.push('"');
    for ch in raw.chars() {
        match ch {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            _ => escaped.push(ch),
        }
    }
    escaped.push('"');
    escaped
}

fn shell_escape_double_quoted(raw: &str) -> String {
    let mut escaped = String::with_capacity(raw.len());
    for ch in raw.chars() {
        match ch {
            '\\' => escaped.push_str("\\\\"),
            '"' => escaped.push_str("\\\""),
            '$' => escaped.push_str("\\$"),
            '`' => escaped.push_str("\\`"),
            _ => escaped.push(ch),
        }
    }
    escaped
}

fn shell_escape_single_quoted(raw: &str) -> String {
    if raw.is_empty() {
        return "''".to_string();
    }
    format!("'{}'", raw.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::{
        build_tmux_bell_hook_spec, build_tmux_bell_notify_command, is_tmux_no_server_output,
        push_unique, resolve_notify_port, tmux_escape_double_quoted_argument, wait_for_file_marker,
        TMUX_BELL_TARGET_FORMAT,
    };
    use std::fs;
    use std::path::Path;
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn notify_port_prefers_override() {
        assert_eq!(resolve_notify_port(Some(8791)), 8791);
    }

    #[test]
    fn bell_notify_command_uses_dynamic_tmux_target_format() {
        let command = build_tmux_bell_notify_command("/home/allen/.local/bin/tmuxd");
        assert!(command.contains(TMUX_BELL_TARGET_FORMAT));
    }

    #[test]
    fn bell_notify_command_keeps_single_quote_free_prefix() {
        let command = build_tmux_bell_notify_command("/home/allen/.local/bin/tmuxd");
        assert!(command.starts_with("\"/home/allen/.local/bin/tmuxd\" notify"));
        assert!(!command.starts_with("''"));
    }

    #[test]
    fn bell_hook_command_uses_single_quoted_run_shell_payload() {
        let spec = build_tmux_bell_hook_spec("/home/allen/.local/bin/tmuxd");
        assert!(spec.runtime_hook_command.starts_with("run-shell -b '"));
        assert!(spec.runtime_hook_command.contains("notify --source bell"));
        assert!(!spec.runtime_hook_command.contains("run-shell -b \"\""));
    }

    #[test]
    fn bell_hook_persistent_line_wraps_command_as_single_set_hook_argument() {
        let spec = build_tmux_bell_hook_spec("/home/allen/.local/bin/tmuxd");
        assert!(spec
            .persistent_hook_line
            .starts_with("set-hook -g alert-bell \""));
        assert!(spec.persistent_hook_line.contains("notify --source bell"));
        assert!(spec.persistent_hook_line.contains("run-shell -b '"));
        assert!(!spec
            .persistent_hook_line
            .contains("set-hook -g alert-bell run-shell -b"));
    }

    #[test]
    fn tmux_escape_double_quoted_argument_escapes_inner_quotes_and_backslashes() {
        let escaped = tmux_escape_double_quoted_argument("run-shell -b \"a\\b\"");
        assert_eq!(escaped, "\"run-shell -b \\\"a\\\\b\\\"\"");
    }

    #[test]
    fn tmux_no_server_output_detection_handles_common_messages() {
        assert!(is_tmux_no_server_output(
            "failed to connect to server: Connection refused"
        ));
        assert!(is_tmux_no_server_output(
            "no server running on /tmp/tmux-1000/default"
        ));
        assert!(is_tmux_no_server_output(
            "error connecting to /tmp/tmux-1000/default (No such file or directory)"
        ));
    }

    #[test]
    fn tmux_no_server_output_detection_ignores_other_errors() {
        assert!(!is_tmux_no_server_output("unknown option: --foo"));
        assert!(!is_tmux_no_server_output("permission denied"));
    }

    #[test]
    fn push_unique_preserves_reason_code_uniqueness() {
        let mut values = vec!["runtime_server_not_running".to_string()];
        push_unique(&mut values, "runtime_server_not_running".to_string());
        push_unique(&mut values, "runtime_hook_not_routed".to_string());
        assert_eq!(values.len(), 2);
    }

    #[test]
    fn wait_for_file_marker_detects_existing_marker() {
        let marker_path = Path::new("/tmp").join(format!(
            "tmuxd-marker-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis()
        ));
        fs::write(&marker_path, b"ok").expect("create marker");
        assert!(wait_for_file_marker(marker_path.as_path(), 100));
        let _ = fs::remove_file(marker_path);
    }

    #[test]
    fn tmux_generated_hook_command_sets_cleanly() {
        let require_integration = std::env::var("TMUXD_REQUIRE_TMUX_INTEGRATION")
            .ok()
            .map(|v| v == "1")
            .unwrap_or(false);

        let tmux_version = match Command::new("tmux").arg("-V").output() {
            Ok(output) if output.status.success() => output,
            Ok(output) => {
                if require_integration {
                    panic!(
                        "tmux exists but `tmux -V` failed: {}",
                        format_output(&output)
                    );
                }
                eprintln!("Skipping tmux integration test: {}", format_output(&output));
                return;
            }
            Err(err) => {
                if require_integration {
                    panic!("tmux is required for integration tests: {err}");
                }
                eprintln!("Skipping tmux integration test: {err}");
                return;
            }
        };

        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        let tmux_tmpdir = Path::new("/tmp").join(format!("tmuxd-it-{}-{now}", std::process::id()));
        fs::create_dir_all(&tmux_tmpdir).expect("create tmux tmpdir");

        let socket = format!("ti{}{}", std::process::id(), now);
        let new_session = run_tmux_with_tmpdir(
            &tmux_tmpdir,
            &socket,
            &["-f", "/dev/null", "new-session", "-d"],
        );
        if !new_session.status.success() {
            let detail = format_output(&new_session);
            if require_integration {
                panic!("failed to start isolated tmux server: {detail}");
            }
            eprintln!("Skipping tmux integration test: {detail}");
            return;
        }

        let list_sessions = run_tmux_with_tmpdir(&tmux_tmpdir, &socket, &["list-sessions"]);
        if !list_sessions.status.success() {
            let detail = format_output(&list_sessions);
            let _ = run_tmux_with_tmpdir(&tmux_tmpdir, &socket, &["kill-server"]);
            if require_integration {
                panic!("isolated tmux server did not stay up: {detail}");
            }
            eprintln!("Skipping tmux integration test: {detail}");
            return;
        }

        let binary = "/home/allen/.local/bin/tmuxd";
        let spec = build_tmux_bell_hook_spec(binary);
        let set_hook = run_tmux_with_tmpdir(
            &tmux_tmpdir,
            &socket,
            &[
                "set-hook",
                "-g",
                "alert-bell",
                spec.runtime_hook_command.as_str(),
            ],
        );
        if !set_hook.status.success() {
            let _ = run_tmux_with_tmpdir(&tmux_tmpdir, &socket, &["kill-server"]);
            panic!(
                "generated hook command rejected by tmux {}: {}",
                String::from_utf8_lossy(&tmux_version.stdout).trim(),
                format_output(&set_hook)
            );
        }

        let source_conf_path = tmux_tmpdir.join("tmuxd-generated-hook.conf");
        fs::write(
            &source_conf_path,
            format!("{}\n", spec.persistent_hook_line),
        )
        .expect("write generated tmux hook config");
        let source_config = run_tmux_with_tmpdir(
            &tmux_tmpdir,
            &socket,
            &["source-file", source_conf_path.to_string_lossy().as_ref()],
        );
        if !source_config.status.success() {
            let _ = run_tmux_with_tmpdir(&tmux_tmpdir, &socket, &["kill-server"]);
            panic!(
                "generated persistent hook line rejected by tmux {}: {}",
                String::from_utf8_lossy(&tmux_version.stdout).trim(),
                format_output(&source_config)
            );
        }

        let show_hooks =
            run_tmux_with_tmpdir(&tmux_tmpdir, &socket, &["show-hooks", "-g", "alert-bell"]);
        let _ = fs::remove_file(source_conf_path);
        let _ = run_tmux_with_tmpdir(&tmux_tmpdir, &socket, &["kill-server"]);
        let _ = fs::remove_dir_all(&tmux_tmpdir);
        assert!(
            show_hooks.status.success(),
            "show-hooks failed: {}",
            format_output(&show_hooks)
        );
        let hooks_output = String::from_utf8_lossy(&show_hooks.stdout);
        assert!(
            hooks_output.contains("notify --source bell"),
            "hook output missing notify route: {hooks_output}"
        );
        assert!(
            !hooks_output.contains("run-shell -b \"\""),
            "hook output contains broken quoting: {hooks_output}"
        );
        let normalized_hooks_output = hooks_output.replace("\\\"", "\"");
        assert!(
            normalized_hooks_output.contains(spec.notify_shell_command.as_str()),
            "hook output does not contain expected notify shell command:\nexpected: {}\nactual: {}",
            spec.notify_shell_command,
            hooks_output
        );
    }

    fn run_tmux_with_tmpdir(
        tmux_tmpdir: &Path,
        socket: &str,
        args: &[&str],
    ) -> std::process::Output {
        Command::new("tmux")
            .env("TMUX_TMPDIR", tmux_tmpdir)
            .args(["-L", socket])
            .args(args)
            .output()
            .expect("execute tmux command")
    }

    fn format_output(output: &std::process::Output) -> String {
        let status = output.status;
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        if stdout.is_empty() && stderr.is_empty() {
            return format!("exit status {status}");
        }
        format!("exit status {status}; stdout={stdout:?}; stderr={stderr:?}")
    }
}
