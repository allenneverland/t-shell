# tmux-chat (Historical Upstream Snapshot)

[English](./README.md)

> Note
> This file is kept as a historical upstream reference. The in-tree backend has
> now been consolidated to a single `tmuxd` server codebase under
> `vendor/reattach/tmuxd`.

**tmux-chat** is a remote tmux client for iOS.
Control your Mac/Linux tmux sessions from anywhere, and receive push notifications when tmux bell or coding-agent events happen.

## Flag Day Migration Notice

This repository has migrated to SSH onboarding + host-agent pairing.

- QR onboarding is removed.
- Cloudflare Access Service Token compatibility mode is removed.
- Claude/Codex `notify/hooks` compatibility is preserved.

See the announcement: `docs/breaking-changes-flag-day-2026.md`.

## Architecture

tmux-chat now has two paths that work together:

1. Control plane (iOS -> tmux-chatd -> tmux)
2. Notification plane (tmux bell / agent hook -> host-agent or tmux-chatd notify -> push-server -> APNs -> iOS)

```text
Control Plane
------------
iOS App --HTTPS--> tmux-chatd --local--> tmux

Notification Plane
------------------
tmux alert-bell --> host-agent --> push-server --> APNs --> iOS
Claude/Codex hook --> tmux-chatd notify --> push-server --> APNs --> iOS
```

## Components

| Component | Description |
|-----------|-------------|
| `tmux-chatd` | Rust daemon exposing tmux control APIs (`sessions` / `panes`) |
| `host-agent` | Host-side relay agent that reports tmux bell events to push-server |
| `push-server` | APNs delivery service (pairing, device registration, mute rules, metrics) |
| `ios/` | iOS app (SSH onboarding, remote tmux control, notification routing) |
| `launchd/` | launchd templates for host services |
| `ops/observability/` | Prometheus alert rules + Grafana dashboard templates |

## Requirements

- macOS or Linux host
- [tmux](https://github.com/tmux/tmux)
- iOS device with notification permission enabled
- SSH access from iOS device to host (network path is user choice: VPN, Tailscale, tunnel, etc.)

Host-side deployment docs (2 systems, Traditional Chinese):
- `docs/deployment-push-server.zh-TW.md`
- `docs/deployment-tmux.zh-TW.md`

iOS app release doc (Traditional Chinese):
- `docs/deployment-ios.zh-TW.md`

## Quick Start

### 1. Install tmux-chatd on the host

Option A: Homebrew (macOS)

```bash
brew tap allenneverland/tmux-chat
brew install tmux-chatd
brew services start tmux-chatd
```

Option B: install script (macOS / Linux)

```bash
curl -fsSL https://raw.githubusercontent.com/allenneverland/tmux-chat/main/install.sh | sh
```

### 2. Start tmux-chatd service

macOS (launchd example):

```bash
mkdir -p ~/Library/Logs/tmux-chat
# create and load ~/Library/LaunchAgents/com.allenneverland.tmux-chatd.plist
launchctl load ~/Library/LaunchAgents/com.allenneverland.tmux-chatd.plist
```

Linux (systemd example):

```bash
# create and enable /etc/systemd/system/tmux-chatd.service
sudo systemctl daemon-reload
sudo systemctl enable --now tmux-chatd
```

### 3. Choose network path for the control URL

Examples:

- Local network: `http://192.168.x.x:8787`
- VPN/Tailscale: `http://<private-ip>:8787`
- Reverse proxy/tunnel with TLS: `https://your-domain.example.com`

### 4. Add server from iOS via SSH onboarding

In the iOS app:

1. Tap `Add Server via SSH`.
2. Enter control plane URL (tmux-chatd URL).
3. Enter SSH host/user/port and authentication.
4. Continue setup.

The app will:

- verify SSH access
- install `host-agent` remotely
- issue control credentials (`tmux-chatd devices issue --json` on host)
- run push pairing and APNs registration
- save server configuration and verify tmux API

After onboarding, verify notification readiness on the host:

```bash
~/.local/bin/host-agent status --json
~/.local/bin/tmuxd hooks verify --json --strict --probe-runtime
```

Ensure `notification_ready` is `true` and `readiness_errors` is empty.
`hooks verify --probe-runtime` validates both runtime hook execution and raw BEL (`printf '\a'`) delivery inside tmux.

If legacy Bash auto-notify files still exist from older releases, `host-agent status --json` reports them in `warnings` (for manual cleanup).

### 5. Optional: coding-agent notification hooks

Auto install:

```bash
tmux-chatd hooks install
```

Manual setup:

- Claude Code (`~/.claude/settings.json`):
  - `hooks.Stop` matcher `""` command `tmux-chatd notify`
  - `hooks.Notification` matcher `"permission_prompt"` command `tmux-chatd notify`
- Codex (`~/.codex/config.toml`, top-level):

```toml
notify = ["tmux-chatd", "notify"]
```

## Advanced: Manual Device Registration (Troubleshooting)

If SSH onboarding is temporarily unavailable, you can issue credentials manually on host:

```bash
tmux-chatd devices issue --name "<device-name>" --json
```

Then add the server in app using:

- `server_url`
- `device_id`
- `device_token`

## Development

### Requirements

- [Rust](https://rustup.rs/)
- Xcode 26.3+ (for iOS)
- Apple Developer account (for APNs testing)

CI pins iOS builds to Xcode 26.3. Keep local development on the same major version to avoid SDK/API mismatch.

### Build

```bash
git clone https://github.com/allenneverland/tmux-chat.git
cd tmux-chat

cp config.local.mk.sample config.local.mk
cp ios/TmuxChat/Config.xcconfig.sample ios/TmuxChat/Config.xcconfig

make build
make install
make start
```

### Local config

`config.local.mk`:

```makefile
PUSH_SERVER_BASE_URL = http://127.0.0.1:8790
PUSH_SERVER_COMPAT_NOTIFY_TOKEN = CHANGE_ME
```

`ios/TmuxChat/Config.xcconfig`:

```xcconfig
BASE_URL = https:/$()/your-domain.example.com
PUSH_SERVER_BASE_URL = https://your-push-server.example.com
```

### One-click Tailscale-only init

Generate all local templates in one command (interactive):

```bash
make tailscale-only-init
```

This writes:
- `ops/deploy/push-server.env`
- `config.local.mk`
- `ios/TmuxChat/Config.xcconfig`
- `ops/deploy/tmux-chatd.service.tailscale.example`

### Common Make targets

```bash
make build
make install
make uninstall
make start
make stop
make restart
make reinstall
make logs
make status
make install-hooks
make uninstall-hooks
```

### push-server in Docker

One-click deploy (recommended, secrets in env file):

```bash
make push-server-env-init
# run interactive wizard (it asks and writes ops/deploy/push-server.env)
make push-server-deploy
make push-server-status
```

By default the container binds to `127.0.0.1:8790` (to avoid conflicts with
`tailscale serve --https=8790`). To publish directly on the host interface,
override it explicitly:

```bash
PUSH_SERVER_HOST_PORT=8790 make push-server-deploy
```

`ops/deploy/push-server.env` is gitignored and keeps APNs secrets out of command history.

Default host data dir is rootless:

```bash
~/.local/share/tmux-chat/push-server
```

If you set `XDG_DATA_HOME`, it uses `$XDG_DATA_HOME/tmux-chat/push-server`.
To pin a system-level directory explicitly:

```bash
PUSH_SERVER_HOST_DATA_DIR=/var/lib/tmux-chat/push-server make push-server-deploy
```

If a legacy `/var/lib/tmux-chat/push-server` exists but is not writable, deployment stops intentionally to avoid data split. Move data first, then set `PUSH_SERVER_HOST_DATA_DIR` to the new path.

Additional Docker targets:

```bash
make push-server-docker-fmt
make push-server-docker-test
make push-server-docker-build
make push-server-docker-image
make push-server-docker-run
```

`push-server` secret env vars (put in `ops/deploy/push-server.env`):

```bash
APNS_KEY_BASE64=...
APNS_KEY_ID=...
APNS_TEAM_ID=...
APNS_BUNDLE_ID=...
PUSH_SERVER_COMPAT_NOTIFY_TOKEN=...
```

Metrics endpoints:

```bash
GET /metrics
GET /metrics.json
```

Observability templates:

- `ops/observability/prometheus-alert-rules.yml`
- `ops/observability/grafana-dashboard-tmux-chat-slo.json`

## Security Notes

- tmux-chat enables remote command execution; deploy with care.
- `tmux-chatd` defaults to `127.0.0.1:8787`.
- All control APIs require bearer token credentials.
- Prefer HTTPS or private network transport.
- Rotate/revoke unused devices with:

```bash
tmux-chatd devices list
tmux-chatd devices revoke <device-id>
```

## Breaking Changes Reference

- `docs/breaking-changes-flag-day-2026.md`
- `plans/phase0/breaking-changes-lock.md`

## License

MIT
