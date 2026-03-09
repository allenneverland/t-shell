# tmuxd Backend (Unified)

This directory now contains a single Rust backend service:

- `tmuxd`: unified control plane + notification plane server

`tmuxd` replaces the previous split architecture (`tmux-chatd` + `push-server` + `host-agent`) with one service codebase and one deployment target.

## What `tmuxd` provides

- tmux control APIs (`/v1/tmux/*`)
- APNs device registration (`/v1/push/devices/register`)
- bell / agent event ingest (`/v1/push/events/*`)
- mute rules and iOS routing metrics (`/v1/push/mutes`, `/v1/push/metrics/ios`)
- local notify CLI (`tmuxd notify`)
- hooks installation (`tmuxd hooks install`)

## Runtime

- Config file: `~/.config/tmuxd/config.toml`
- Data dir: `~/.local/share/tmuxd`
- Default listen: `0.0.0.0:8787` (configure via `bind_addr` / `port`)

Example config:

```toml
bind_addr = "0.0.0.0"
port = 8787
service_token = "CHANGE_ME"

[apns]
key_base64 = "..."
key_id = "..."
team_id = "..."
bundle_id = "..."
```

## Build

```bash
cd vendor/reattach/tmuxd
cargo build --release
```

## Release

`tmuxd` release assets are built and published by GitHub Actions.

1. Create and push a tag matching `tmuxd-v*` (for example `tmuxd-v0.2.0`).
2. Workflow `.github/workflows/release-tmuxd.yml` builds multi-platform binaries.
3. The workflow uploads `tmuxd-<platform>.tar.gz` assets to the tag release.
