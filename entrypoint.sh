#!/usr/bin/env bash
set -euo pipefail

# Ensure the workspace lives on the persistent /data volume.
mkdir -p /data/.openclaw/workspace
mkdir -p /root/.openclaw
rm -rf /root/.openclaw
ln -s /data/.openclaw /root/.openclaw

if [[ -n "${DEFAULT_MODEL:-}" ]]; then
  if ! command -v openclaw >/dev/null 2>&1; then
    echo "error: DEFAULT_MODEL is set but 'openclaw' was not found on PATH" >&2
    exit 1
  fi

  echo "Setting OpenClaw default model to: ${DEFAULT_MODEL}"
  openclaw models set "${DEFAULT_MODEL}"
fi

# If Tailscale auth key is set, bring up Tailscale then run the app (app inherits proxy env).
if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
  exec /app/start-tailscale.sh "$@"
fi

exec "$@"
