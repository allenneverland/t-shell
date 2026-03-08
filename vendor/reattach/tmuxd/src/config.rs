use std::path::PathBuf;

use clap::Args;
use serde::Deserialize;

use crate::error::{AppError, AppResult};

const DEFAULT_PORT: u16 = 8787;
const DEFAULT_BIND_ADDR: &str = "127.0.0.1";

#[derive(Args, Debug, Clone, Default)]
pub struct ServeArgs {
    /// Optional tmuxd config.toml path
    #[arg(long, env = "TMUXD_CONFIG_FILE")]
    pub config: Option<PathBuf>,

    /// Bind address
    #[arg(long, env = "TMUXD_BIND_ADDR")]
    pub bind_addr: Option<String>,

    /// Listen port
    #[arg(long, env = "TMUXD_PORT")]
    pub port: Option<u16>,

    /// Data directory for sqlite and runtime state
    #[arg(long, env = "TMUXD_DATA_DIR")]
    pub data_dir: Option<PathBuf>,

    /// Service token for protected control + push ingress APIs
    #[arg(long, env = "TMUXD_SERVICE_TOKEN")]
    pub service_token: Option<String>,

    /// Optional legacy device token file for one-time import
    #[arg(long, env = "TMUXD_LEGACY_DEVICE_TOKENS_FILE")]
    pub legacy_device_tokens_file: Option<PathBuf>,

    #[arg(long, env = "APNS_KEY_BASE64")]
    pub apns_key_base64: Option<String>,
    #[arg(long, env = "APNS_KEY_ID")]
    pub apns_key_id: Option<String>,
    #[arg(long, env = "APNS_TEAM_ID")]
    pub apns_team_id: Option<String>,
    #[arg(long, env = "APNS_BUNDLE_ID")]
    pub apns_bundle_id: Option<String>,
}

#[derive(Clone, Debug)]
pub struct Config {
    pub bind_addr: String,
    pub port: u16,
    pub data_dir: PathBuf,
    pub db_path: PathBuf,
    pub service_token: String,
    pub legacy_device_tokens_file: Option<PathBuf>,
    pub apns: Option<ApnsConfig>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct ApnsConfig {
    pub key_base64: String,
    pub key_id: String,
    pub team_id: String,
    pub bundle_id: String,
}

#[derive(Debug, Default, Deserialize)]
struct FileConfig {
    bind_addr: Option<String>,
    port: Option<u16>,
    data_dir: Option<PathBuf>,
    service_token: Option<String>,
    legacy_device_tokens_file: Option<PathBuf>,
    apns: Option<ApnsConfig>,
}

impl Config {
    pub fn load(args: Option<&ServeArgs>) -> AppResult<Self> {
        let cfg_path = resolve_config_file_path(args);
        let file_cfg = load_file_config(&cfg_path)?;

        let bind_addr = args
            .and_then(|a| a.bind_addr.clone())
            .or(file_cfg.bind_addr)
            .unwrap_or_else(|| DEFAULT_BIND_ADDR.to_string());

        let port = args.and_then(|a| a.port).or(file_cfg.port).unwrap_or(DEFAULT_PORT);

        let data_dir = args
            .and_then(|a| a.data_dir.clone())
            .or(file_cfg.data_dir)
            .unwrap_or_else(default_data_dir);

        let db_path = data_dir.join("tmuxd.sqlite3");

        let service_token = args
            .and_then(|a| a.service_token.clone())
            .or(file_cfg.service_token)
            .unwrap_or_default();

        if service_token.trim().is_empty() {
            return Err(AppError::bad_request(
                "missing TMUXD_SERVICE_TOKEN (or service_token in config.toml)",
            ));
        }

        let legacy_device_tokens_file = args
            .and_then(|a| a.legacy_device_tokens_file.clone())
            .or(file_cfg.legacy_device_tokens_file)
            .or_else(default_legacy_device_tokens_file);

        let file_apns = file_cfg.apns;
        let apns = match (
            args.and_then(|a| a.apns_key_base64.clone())
                .or_else(|| std::env::var("APNS_KEY_BASE64").ok())
                .or_else(|| file_apns.as_ref().map(|v| v.key_base64.clone())),
            args.and_then(|a| a.apns_key_id.clone())
                .or_else(|| std::env::var("APNS_KEY_ID").ok())
                .or_else(|| file_apns.as_ref().map(|v| v.key_id.clone())),
            args.and_then(|a| a.apns_team_id.clone())
                .or_else(|| std::env::var("APNS_TEAM_ID").ok())
                .or_else(|| file_apns.as_ref().map(|v| v.team_id.clone())),
            args.and_then(|a| a.apns_bundle_id.clone())
                .or_else(|| std::env::var("APNS_BUNDLE_ID").ok())
                .or_else(|| file_apns.as_ref().map(|v| v.bundle_id.clone())),
        ) {
            (Some(key_base64), Some(key_id), Some(team_id), Some(bundle_id)) => Some(ApnsConfig {
                key_base64,
                key_id,
                team_id,
                bundle_id,
            }),
            _ => None,
        };

        Ok(Self {
            bind_addr,
            port,
            data_dir,
            db_path,
            service_token,
            legacy_device_tokens_file,
            apns,
        })
    }
}

pub fn default_config_file_path() -> PathBuf {
    dirs::config_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("tmuxd")
        .join("config.toml")
}

fn resolve_config_file_path(args: Option<&ServeArgs>) -> PathBuf {
    args.and_then(|a| a.config.clone())
        .or_else(|| std::env::var("TMUXD_CONFIG_FILE").ok().map(PathBuf::from))
        .unwrap_or_else(default_config_file_path)
}

fn load_file_config(path: &PathBuf) -> AppResult<FileConfig> {
    if !path.exists() {
        return Ok(FileConfig::default());
    }

    let content = std::fs::read_to_string(path)?;
    let cfg = toml::from_str::<FileConfig>(&content)
        .map_err(|e| AppError::bad_request(format!("invalid config file {}: {}", path.display(), e)))?;
    Ok(cfg)
}

fn default_data_dir() -> PathBuf {
    if let Ok(path) = std::env::var("TMUXD_DATA_DIR") {
        return PathBuf::from(path);
    }

    dirs::data_local_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join("tmuxd")
}

fn default_legacy_device_tokens_file() -> Option<PathBuf> {
    let path = dirs::data_local_dir()?
        .join("tmux-chatd")
        .join("device_tokens.json");
    if path.exists() {
        Some(path)
    } else {
        None
    }
}
