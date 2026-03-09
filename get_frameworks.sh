#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Force anonymous, non-interactive git access for all dependency fetches.
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/usr/bin/false
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

GIT_ANON_ARGS=(
  -c credential.helper=
  -c credential.interactive=never
  -c core.askPass=/usr/bin/false
)

echo "[deps] syncing submodules (anonymous mode)"
git -C "$ROOT_DIR" "${GIT_ANON_ARGS[@]}" submodule sync --recursive
git -C "$ROOT_DIR" "${GIT_ANON_ARGS[@]}" submodule update --init --recursive

echo "[deps] resolving xcfs packages (anonymous mode)"
(
  cd "$ROOT_DIR/xcfs"
  swift package resolve
)

echo "[deps] done"
