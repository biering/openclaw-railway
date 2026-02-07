#!/usr/bin/env bash
set -euo pipefail

# Ensure the workspace lives on the persistent /data volume.
mkdir -p /data/.openclaw/workspace
mkdir -p /root/.openclaw
rm -rf /root/.openclaw
ln -s /data/.openclaw /root/.openclaw

exec "$@"
