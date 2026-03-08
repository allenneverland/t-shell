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
use clap::{Parser, Subcommand, ValueEnum};
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
        /// Server port (default: 8787)
        #[arg(short, long, default_value = "8787")]
        port: u16,
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
            run_hooks_command(action);
            Ok(())
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
    port: u16,
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

    let url = format!("http://localhost:{}/v1/push/events/{}", port, source.as_path());
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
            eprintln!("Make sure tmuxd daemon is running on port {}", port);
            std::process::exit(1);
        }
    }
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
        .route("/v1/tmux/panes/{target}/input", post(control_api::send_input))
        .route(
            "/v1/tmux/panes/{target}/input-events",
            post(control_api::send_input_events),
        )
        .route("/v1/tmux/panes/{target}/key", post(control_api::send_key_legacy))
        .route(
            "/v1/tmux/panes/{target}/keys",
            post(control_api::send_keys_legacy),
        )
        .route(
            "/v1/tmux/panes/{target}/escape",
            post(control_api::send_escape),
        )
        .route("/v1/tmux/panes/{target}/output", get(control_api::get_output))
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
        .route("/v1/push/mutes", get(push_api::list_mutes).post(push_api::create_mute))
        .route("/v1/push/mutes/{id}", delete(push_api::delete_mute))
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

fn run_hooks_command(action: Option<HookAction>) {
    match action.unwrap_or(HookAction::Install) {
        HookAction::Install => {
            install_claude_hooks();
            install_codex_hooks();
            install_tmux_bell_hook();
        }
        HookAction::Uninstall => {
            uninstall_claude_hooks();
            uninstall_codex_hooks();
            uninstall_tmux_bell_hook();
        }
    }
}

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

fn install_tmux_bell_hook() {
    let tmux_conf = match home_file(".tmux.conf") {
        Some(path) => path,
        None => {
            eprintln!("Failed to resolve ~/.tmux.conf path");
            return;
        }
    };

    let existing = std::fs::read_to_string(&tmux_conf).unwrap_or_default();
    let binary = std::env::current_exe()
        .ok()
        .and_then(|p| p.to_str().map(str::to_string))
        .unwrap_or_else(|| "tmuxd".to_string());

    let run_shell = format!(
        "{} notify --source bell --target '#{{session_name}}:#{{window_index}}.#{{pane_index}}' --title 'tmux bell' --body 'tmux bell'",
        shell_quote(&binary)
    );
    let escaped = run_shell.replace('\\', "\\\\").replace('"', "\\\"");
    let managed = format!(
        "{TMUX_MANAGED_START}\nset-window-option -g monitor-bell on\nset-option -g bell-action any\nset-hook -g alert-bell \"run-shell \\\"{escaped}\\\"\"\n{TMUX_MANAGED_END}\n"
    );

    let updated = upsert_managed_tmux_block(&existing, &managed);
    if updated != existing {
        if let Err(e) = std::fs::write(&tmux_conf, updated) {
            eprintln!("Failed to write {}: {}", tmux_conf.display(), e);
            return;
        }
        println!("Updated {}", tmux_conf.display());
    }

    let _ = std::process::Command::new("tmux")
        .arg("source-file")
        .arg(tmux_conf.to_string_lossy().to_string())
        .status();
}

fn uninstall_tmux_bell_hook() {
    let tmux_conf = match home_file(".tmux.conf") {
        Some(path) => path,
        None => {
            eprintln!("Failed to resolve ~/.tmux.conf path");
            return;
        }
    };

    let existing = std::fs::read_to_string(&tmux_conf).unwrap_or_default();
    let updated = remove_managed_tmux_block(&existing);
    if updated != existing {
        if let Err(e) = std::fs::write(&tmux_conf, updated) {
            eprintln!("Failed to write {}: {}", tmux_conf.display(), e);
            return;
        }
        println!("Updated {}", tmux_conf.display());
    }

    let _ = std::process::Command::new("tmux")
        .args(["set-hook", "-gu", "alert-bell"])
        .status();
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

fn shell_quote(raw: &str) -> String {
    let mut quoted = String::from("'");
    for ch in raw.chars() {
        if ch == '\'' {
            quoted.push_str("'\"'\"'");
        } else {
            quoted.push(ch);
        }
    }
    quoted.push('\'');
    quoted
}
