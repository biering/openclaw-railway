#!/bin/sh
set -eu

SOCK="/tmp/tailscaled.sock"
PROXY_ADDR="127.0.0.1:1055"
HOSTNAME="${TAILSCALE_HOSTNAME:-railway-agent}"

if [ -z "${TAILSCALE_AUTHKEY:-}" ]; then
  echo "ERROR: TAILSCALE_AUTHKEY is not set"
  exit 1
fi

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

# Wait for the unix socket to exist
echo "[tailscale] waiting for socket..."
i=0
while [ ! -S "$SOCK" ]; do
  i=$((i+1))
  if [ "$i" -ge 100 ]; then
    echo "ERROR: tailscaled socket never appeared"
    echo "---- tailscaled log ----"
    tail -n 200 /tmp/tailscaled.log || true
    exit 1
  fi
  sleep 0.1
done

echo "[tailscale] attempting 'tailscale up'..."
if ! tailscale --socket="$SOCK" up \
  --authkey="$TAILSCALE_AUTHKEY" \
  --hostname="$HOSTNAME" \
  --netfilter-mode=off \
  --accept-dns=false \
  ${TAILSCALE_EXTRA_UP_ARGS:-} \
  >/tmp/tailscale-up.log 2>&1
then
  echo "ERROR: tailscale up failed"
  echo "---- tailscale up log ----"
  cat /tmp/tailscale-up.log || true
  echo "---- tailscaled log ----"
  tail -n 200 /tmp/tailscaled.log || true
  exit 1
fi

echo "[tailscale] up. status:"
tailscale --socket="$SOCK" status || true

# Proxy env vars for userspace mode
export ALL_PROXY="socks5h://$PROXY_ADDR"
export HTTPS_PROXY="http://$PROXY_ADDR"
export HTTP_PROXY="http://$PROXY_ADDR"
export NO_PROXY="localhost,127.0.0.1"

trap 'echo "[tailscale] shutting down"; kill "$TAILSCALED_PID" 2>/dev/null || true' INT TERM EXIT

if [ "$#" -eq 0 ]; then
  echo "[tailscale] no command provided; keeping container alive"
  while :; do sleep 3600; done
else
  echo "[app] starting: $*"
  exec "$@"
fi