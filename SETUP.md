# Ethereum L1 Node Setup (Reth + Lighthouse)

Guide for running an optimized Ethereum mainnet node with **Reth** (execution) and **Lighthouse** (consensus) on Ubuntu: what the config does, how to set it up, and how to tune the OS for stability and performance.

---

## Table of contents

1. [Stack overview](#1-stack-overview)
2. [docker-compose.yml explained](#2-docker-composeyml-explained)
3. [reth.toml explained](#3-rethtoml-explained)
4. [Ubuntu setup](#4-ubuntu-setup)
5. [Network optimizations (Linux)](#5-network-optimizations-linux)
6. [CPU optimizations](#6-cpu-optimizations)
7. [OS optimizations](#7-os-optimizations)
8. [Port forwarding & firewall](#8-port-forwarding--firewall)
9. [Quick reference](#9-quick-reference)

---

## 1. Stack overview

| Component   | Role |
|------------|------|
| **Reth**   | Execution layer: chain data, execution, P2P (port 30303), HTTP/WS RPC (8545/8546), Engine API (8551). |
| **Lighthouse** | Consensus layer: beacon chain, P2P (9000, 9001 QUIC), Beacon API (5052). Talks to Reth over Engine API (JWT on 8551). |
| **Docker bridge** | Both containers share `eth-network`; Lighthouse reaches Reth at `http://reth:8551`. |

RPC/APIs are bound to `127.0.0.1` on the host so they are not exposed to the LAN. P2P ports (30303, 9000, 9001) are published so you can forward them on your router for more peers.

---

## 2. docker-compose.yml explained

### Reth service

| Section | Purpose |
|--------|--------|
| **image** | `ghcr.io/paradigmxyz/reth:latest` — official Reth image. |
| **ulimits nofile** | 1048576 soft/hard — allows many open files (peers, DB, sockets). Prevents "too many open files" under load. |
| **command** | `node` with `--chain mainnet`, `--datadir /data`, plus RPC, Engine API, P2P, and peer options (see below). |
| **volumes** | `./reth-data:/data` (chain + DB), `./reth.toml:/data/reth.toml` (config), `./jwt:/jwt` (JWT secret for Engine API). |
| **ports** | 8545/8546/8551 and 9001 bound to 127.0.0.1; 30303 TCP/UDP published for P2P. |
| **healthcheck** | `curl` on 8545 every 30s; 5 retries before unhealthy. |
| **networks** | `eth-network` (bridge). |

**Notable CLI flags:**

- **RPC:** `--http` / `--ws` on 8545/8546, APIs `eth,net,web3,rpc,admin`.
- **Engine API:** `--authrpc.*` on 8551, JWT at `/jwt/jwt.hex` (used by Lighthouse).
- **P2P:** port 30303, discv5, `--dns-retries 3`, `--peers-file /data/peers.txt`, `--enforce-enr-fork-id`.
- **Peers:** 150 outbound, 150 inbound, `--nat any`.
- **Metrics:** `--metrics 0.0.0.0:9001` (Prometheus).

### Lighthouse service

| Section | Purpose |
|--------|--------|
| **image** | `sigp/lighthouse:latest`. |
| **depends_on** | `reth` — starts after Reth; no `service_healthy` so it doesn’t wait for Reth’s healthcheck. |
| **ulimits nofile** | Same as Reth for many connections. |
| **command** | `lighthouse beacon_node --network mainnet`, `--execution-endpoint http://reth:8551`, `--execution-jwt /jwt/jwt.hex`, `--checkpoint-sync-url https://mainnet.checkpoint.sigp.io`, HTTP on 5052, P2P on 9000/9001, metrics on 8008. |
| **volumes** | `./lighthouse-data:/data`, `./jwt:/jwt`. |
| **ports** | 5052 and 8008 on 127.0.0.1; 9000 TCP/UDP and 9001 UDP for P2P. |
| **healthcheck** | `curl` on 5052 health endpoint. |
| **networks** | `eth-network`. |

### Networks

- **eth-network:** bridge driver. Containers resolve each other by name (`reth`, `lighthouse`).

---

## 3. reth.toml explained

Reth reads `reth.toml` from the datadir (`/data/reth.toml` in the container). It tunes peers, sync, and per-connection behavior.

### [peers]

| Option | Meaning |
|--------|--------|
| `refill_slots_interval` | How often to try to fill peer slots (default 5s). |
| `connect_trusted_nodes_only` | `false` = use discovery + optional bootnodes. |
| `max_backoff_count` | After this many failed dial attempts, stop retrying that peer for a while. |
| `ban_duration` | How long to ban misbehaving peers (e.g. 12h). |
| `incoming_ip_throttle_duration` | Throttle repeated connection attempts from the same IP. |

### [peers.connection_info]

| Option | Meaning |
|--------|--------|
| `max_outbound` / `max_inbound` | Match CLI: 150 each (avoids default 30 inbound cap). |
| `max_concurrent_outbound_dials` | How many outbound connection attempts at once (higher = faster peer refill). |

### [peers.backoff_durations]

Wait times before re-dialing after failed connections (low/medium/high/max). Reduces hammering of bad or unreachable peers.

### [peers.reputation_weights]

Penalties applied when peers misbehave (bad blocks, timeouts, protocol violations). Lower reputation can lead to disconnect or ban.

### [stages.headers] and [stages.bodies]

- **downloader_max_concurrent_requests** — More parallel requests = faster sync if you have bandwidth/CPU.
- **downloader_min_concurrent_requests** — Keeps a minimum number of requests in flight.
- **downloader_max_buffered_*** — How much to buffer before writing to disk.
- **commit_threshold** (headers) — How many headers to batch before a disk write.

Tuning these trades off sync speed vs memory and disk I/O.

### [sessions]

- **session_command_buffer** / **session_event_buffer** — Per-peer queue sizes.
- **pending_session_timeout** — Time to wait for a new connection to establish before failing.
- **initial_internal_request_timeout** / **protocol_breach_request_timeout** — Timeouts for protocol requests.
- **limits** — Max pending/established inbound/outbound sessions; should be ≥ your peer limits (150).

---

## 4. Ubuntu setup

### Prerequisites

- Ubuntu 22.04 LTS (or similar).
- Docker Engine and Docker Compose (Compose V2 plugin).
- At least 16 GB RAM (more recommended for sync); ~1.2 TB+ free for mainnet (TLC NVMe recommended).

### Install Docker (if needed)

```bash
# Add Docker's repo and install
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER
# Log out and back in (or newgrp docker) so docker runs without sudo
```

### Project layout

Clone or copy the project to a directory, e.g. `evm_dockerfile`. You need:

- `docker-compose.yml`
- `reth.toml`
- A `jwt` directory with a JWT secret file.

### Create JWT secret

Reth and Lighthouse use a shared JWT secret for the Engine API. Create it once:

```bash
mkdir -p jwt
openssl rand -hex 32 > jwt/jwt.hex
chmod 600 jwt/jwt.hex
```

### First run

```bash
cd /path/to/evm_dockerfile
docker compose up -d
```

- First run will create `reth-data/` and `lighthouse-data/` and start syncing.
- Reth sync can take many hours/days depending on hardware and network.
- Lighthouse uses checkpoint sync so it catches up quickly, then follows the chain.

### Useful commands

```bash
# Logs
docker compose logs -f reth
docker compose logs -f lighthouse

# Stop
docker compose down

# Restart (keeps data)
docker compose up -d
```

---

## 5. Network optimizations (Linux)

These sysctl settings can improve throughput and connection handling for a node with many peers. Adjust or skip based on your RAM and interface speed.

### Backup current settings

```bash
sudo sysctl -a 2>/dev/null | grep -E '^net\.' > ~/sysctl-net-backup.txt
```

### Create a tuning file

```bash
sudo tee /etc/sysctl.d/99-ethereum-node.conf << 'EOF'
# Increase max open files system-wide
fs.file-max = 2097152

# TCP buffer sizes (tune if you have high bandwidth; values in bytes)
# min, default, max for receive/send
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576

# Allow more connections in backlog and more pending connections
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535

# TCP behavior
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# Increase local port range for outbound connections
net.ipv4.ip_local_port_range = 1024 65535
EOF
```

Apply:

```bash
sudo sysctl --system
```

Revert by removing the file and running `sudo sysctl --system` again, or by restoring from your backup.

---

## 6. CPU optimizations

Reth’s execution is largely single-threaded; consistent high frequency helps more than many cores.

### Use the performance governor

Avoid powersave/ondemand so the CPU doesn’t ramp down under load:

```bash
# Install cpupower if needed
sudo apt-get install -y linux-tools-common linux-tools-$(uname -r)

# Check current governor
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor

# Set performance governor (temporary; lost on reboot)
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

To make it persistent (example with systemd):

```bash
sudo tee /etc/systemd/system/cpufreq-performance.service << 'EOF'
[Unit]
Description=Set CPU governor to performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > $f; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now cpufreq-performance.service
```

---

## 7. OS optimizations

### File descriptor limits (host)

Containers have their own ulimits (already set in compose). If you run anything else or hit limits on the host:

```bash
# /etc/security/limits.d/99-ethereum-node.conf
* soft nofile 1048576
* hard nofile 1048576
```

Then log out and back in (or reboot). `fs.file-max` in sysctl (above) sets the system-wide cap.

### Optional: tmpfs for JWT (security)

Keeping JWT on disk is fine; if you want it only in RAM you could use a tmpfs mount for `jwt/`. The compose expects a file at `./jwt/jwt.hex`, so this is optional and left as an exercise.

### Disk

- Prefer **TLC NVMe** for `reth-data` and `lighthouse-data` (Reth docs recommend at least ~1.2 TB for mainnet full node).
- Avoid QLC for heavy write workloads.

---

## 8. Port forwarding & firewall

### Router

Forward these to the **Ubuntu host’s LAN IP** (e.g. from `ip addr` or `hostname -I`):

| Port  | Protocol | Service   |
|-------|----------|-----------|
| 30303 | TCP      | Reth P2P  |
| 30303 | UDP      | Reth P2P  |
| 9000  | TCP      | Lighthouse P2P |
| 9000  | UDP      | Lighthouse P2P |
| 9001  | UDP      | Lighthouse QUIC |

### Host firewall (ufw example)

Allow SSH, then P2P ports; leave RPC/API ports bound only to 127.0.0.1 (no firewall rule needed for 8545/8546/8551/5052 if you don’t open them to LAN):

```bash
sudo ufw allow 22/tcp
sudo ufw allow 30303/tcp
sudo ufw allow 30303/udp
sudo ufw allow 9000/tcp
sudo ufw allow 9000/udp
sudo ufw allow 9001/udp
sudo ufw enable
```

---

## 9. Quick reference

### Host ports (all 127.0.0.1 unless you change compose)

| Port | Service        | Use              |
|------|----------------|------------------|
| 8545 | Reth           | HTTP RPC         |
| 8546 | Reth           | WebSocket RPC    |
| 8551 | Reth           | Engine API (Lighthouse) |
| 9001 | Reth           | Metrics          |
| 5052 | Lighthouse     | Beacon API       |
| 8008 | Lighthouse     | Metrics          |

### P2P (forward on router)

| Port  | Protocol | Client    |
|-------|----------|-----------|
| 30303 | TCP+UDP  | Reth      |
| 9000  | TCP+UDP  | Lighthouse |
| 9001  | UDP      | Lighthouse QUIC |

### Files and dirs

| Path              | Purpose                    |
|-------------------|----------------------------|
| `docker-compose.yml` | Stack definition          |
| `reth.toml`       | Reth config (mounted at /data/reth.toml) |
| `jwt/jwt.hex`     | JWT secret (Reth + Lighthouse) |
| `reth-data/`      | Reth chain and DB          |
| `lighthouse-data/`| Lighthouse DB              |

### Apply all optimizations (summary)

1. Install Docker and Docker Compose; add user to `docker` group.
2. Create `jwt/jwt.hex` with `openssl rand -hex 32`.
3. Put `docker-compose.yml` and `reth.toml` in the same directory; run `docker compose up -d`.
4. (Optional) Add `/etc/sysctl.d/99-ethereum-node.conf` and run `sudo sysctl --system`.
5. (Optional) Set CPU governor to `performance` and make it persistent.
6. (Optional) Add limits in `/etc/security/limits.d/` and re-login.
7. Forward 30303, 9000, 9001 on the router to the Ubuntu host; allow them in ufw if used.

After that, the node will sync; peer count should rise (especially with port forwarding and reth.toml loaded). Use `docker compose logs -f reth` and `docker compose logs -f lighthouse` to monitor.
