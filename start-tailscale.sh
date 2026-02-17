#!/bin/sh
set -eu

SOCK="/tmp/tailscaled.sock"
PROXY_ADDR="127.0.0.1:1055"
HOSTNAME="${TAILSCALE_HOSTNAME:-railway-agent}"

if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
  echo "ERROR: TAILSCALE_AUTHKEY is not set"
  exit 1
fi

# Clean up stale socket if present
rm -f "$SOCK"

echo "[tailscale] starting tailscaled (userspace)..."
tailscaled \
  --tun=userspace-networking \
  --state=mem: \
  --socket="$SOCK" \
  --socks5-server="$PROXY_ADDR" \
  --outbound-http-proxy-listen="$PROXY_ADDR" \
  >/tmp/tailscaled.log 2>&1 &

TAILSCALED_PID="$!"

# Wait for tailscaled socket to appear and respond
echo "[tailscale] waiting for daemon..."
i=0
while :; do
  i=$((i+1))
  if tailscale --socket="$SOCK" status >/dev/null 2>&1; then
    break
  fi
  if [ "$i" -ge 50 ]; then
    echo "ERROR: tailscaled did not become ready"
    echo "---- tailscaled log ----"
    tail -n 200 /tmp/tailscaled.log || true
    exit 1
  fi
  sleep 0.2
done

echo "[tailscale] bringing interface up..."
tailscale --socket="$SOCK" up \
  --authkey="$TAILSCALE_AUTHKEY" \
  --hostname="$HOSTNAME" \
  --netfilter-mode=off \
  --accept-dns=false \
  ${TAILSCALE_EXTRA_UP_ARGS:-} \
  >/tmp/tailscale-up.log 2>&1 || {
    echo "ERROR: tailscale up failed"
    echo "---- tailscale up log ----"
    cat /tmp/tailscale-up.log || true
    exit 1
  }

echo "[tailscale] up. status:"
tailscale --socket="$SOCK" status || true

# Export proxy vars for anything you run after this script.
# In userspace-networking mode, outbound Tailnet access typically needs this.
export ALL_PROXY="socks5h://$PROXY_ADDR"
export HTTPS_PROXY="http://$PROXY_ADDR"
export HTTP_PROXY="http://$PROXY_ADDR"
export NO_PROXY="localhost,127.0.0.1"

# If you want to ensure tailscaled is killed when the container stops:
trap 'echo "[tailscale] shutting down"; kill "$TAILSCALED_PID" 2>/dev/null || true' INT TERM EXIT

if [ "$#" -eq 0 ]; then
  echo "[tailscale] no command provided; keeping container alive"
  # Keep running, but still respond to signals via trap
  while :; do sleep 3600; done
else
  echo "[app] starting: $*"
  exec "$@"
fi
