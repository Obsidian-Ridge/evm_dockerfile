#!/usr/bin/env bash
# Check reachability and list Prometheus metrics from all stack services.
# Bash-only (no curl): uses /dev/tcp like docker-compose healthchecks.
# Run on Ubuntu host with stack up: ./scripts/list-stack-metrics.sh
#
# Use this to:
#  - See why "InstanceDown" fires (target unreachable from host?)
#  - Discover actual metric names (e.g. Lighthouse) to fix dashboards.

set -e
HOST="${METRICS_HOST:-localhost}"

# host port path
RETH_PORT="${RETH_PORT:-9001}"
LIGHTHOUSE_PORT="${LIGHTHOUSE_PORT:-8008}"
BASE_RETH_PORT="${BASE_RETH_PORT:-9002}"
ROLLUP_CLIENT_PORT="${ROLLUP_CLIENT_PORT:-7300}"

fetch_url() {
  local host=$1 port=$2 reqpath="${3:-/}"
  timeout 3 bash -c "exec 3<>/dev/tcp/$host/$port && printf 'GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n' '$reqpath' '$host' >&3 && cat <&3; exec 3>&-" 2>/dev/null || true
}

# Returns 0 if body contains at least one line that looks like a metric (# HELP, # TYPE, or metric_name)
reachable() {
  local body=$1
  echo "$body" | grep -qE '^(# HELP|# TYPE|[a-zA-Z_][a-zA-Z0-9_]*)' && return 0 || return 1
}

# Strip HTTP headers (everything before first empty line)
body_only() {
  sed -n '/^$/,$p' | sed '1d'
}

# Print first N metric names: from lines starting with name, or from # HELP / # TYPE lines
metric_names() {
  local n="${1:-80}" body
  body=$(cat | body_only)
  { echo "$body" | grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*'; echo "$body" | sed -n 's/^# \(HELP\|TYPE\) \([a-zA-Z_][a-zA-Z0-9_]*\) .*/\2/p'; } | sort -u | head -n "$n"
}

# First 50 lines of body (to debug chunked or unknown format)
body_preview() {
  cat | body_only | head -n 50
}

section() {
  echo ""
  echo "========== $1 =========="
}

# --- L1 reth ---
section "L1 reth ($HOST:$RETH_PORT) path=/"
out=$(fetch_url "$HOST" "$RETH_PORT" "/")
if reachable "$out"; then
  echo "Reachable: yes"
  echo "Sample metric names:"
  echo "$out" | metric_names 40
else
  echo "Reachable: no (connection refused or no metrics)"
fi

# --- Lighthouse (beacon) ---
section "Lighthouse ($HOST:$LIGHTHOUSE_PORT) path=/metrics"
out=$(fetch_url "$HOST" "$LIGHTHOUSE_PORT" "/metrics")
if reachable "$out"; then
  echo "Reachable: yes"
  names=$(echo "$out" | metric_names 60)
  echo "Sample metric names (use these in lighthouse-beacon dashboard if different):"
  echo "$names"
  if [ -z "$names" ]; then
    echo "(none extracted; body preview below)"
    echo "$out" | body_preview
  else
    echo ""
    echo "Peers/head/sync related:"
    echo "$out" | body_only | grep -iE 'peer|head|slot|sync' | head -20
  fi
else
  echo "Reachable: no (connection refused or no metrics)"
fi

# --- L2 base-reth ---
section "L2 base-reth ($HOST:$BASE_RETH_PORT) path=/"
out=$(fetch_url "$HOST" "$BASE_RETH_PORT" "/")
if reachable "$out"; then
  echo "Reachable: yes"
  echo "Sample metric names:"
  echo "$out" | metric_names 40
else
  echo "Reachable: no"
fi

# --- rollup-client (op-node) ---
section "rollup-client / op-node ($HOST:$ROLLUP_CLIENT_PORT) path=/"
out=$(fetch_url "$HOST" "$ROLLUP_CLIENT_PORT" "/")
if reachable "$out"; then
  echo "Reachable: yes"
  names=$(echo "$out" | metric_names 40)
  echo "Sample metric names:"
  echo "$names"
  if [ -z "$names" ]; then
    echo "(none extracted; body preview below)"
    echo "$out" | body_preview
  fi
else
  echo "Reachable: no"
fi

section "Done"
echo ""
echo "If any service shows 'Reachable: no', Prometheus (in Docker) may still scrape it via"
echo "internal hostnames (reth:9001, lighthouse:8008, etc.). InstanceDown means the"
echo "scrape from Prometheus to that target is failing."
