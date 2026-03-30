#!/usr/bin/env bash
# List peer-related Prometheus metrics from reth and base-reth.
# Bash-only (no curl): uses /dev/tcp like docker-compose healthchecks.
# Run on Ubuntu host with stack up: ./scripts/list-reth-metrics.sh

set -e
L1_HOST="${RETH_L1_HOST:-localhost}"
L1_PORT="${RETH_L1_PORT:-9001}"
L2_HOST="${RETH_L2_HOST:-localhost}"
L2_PORT="${RETH_L2_PORT:-9002}"

fetch_metrics() {
  local host=$1 port=$2
  local out
  out=$(timeout 3 bash -c "exec 3<>/dev/tcp/$host/$port && printf 'GET / HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n' '$host' >&3 && cat <&3; exec 3>&-" 2>/dev/null) || true
  if echo "$out" | grep -qi peer; then
    echo "$out" | grep -i peer
  else
    echo "(no peer metrics or unreachable)"
  fi
}

echo "=== L1 reth ($L1_HOST:$L1_PORT) - peer-related metrics ==="
fetch_metrics "$L1_HOST" "$L1_PORT"
echo ""
echo "=== L2 base-reth ($L2_HOST:$L2_PORT) - peer-related metrics ==="
fetch_metrics "$L2_HOST" "$L2_PORT"
