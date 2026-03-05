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
9. [Monitoring (Prometheus & Grafana)](#9-monitoring-prometheus--grafana)
10. [Quick reference](#10-quick-reference)
11. [Base L2 node (op-reth + op-node)](#11-base-l2-node-op-reth--op-node)

---

## 1. Stack overview

| Component   | Role |
|------------|------|
| **Reth**   | Execution layer: chain data, execution, P2P (port 30303), HTTP/WS RPC (8545/8546), Engine API (8551), metrics (9001). |
| **Lighthouse** | Consensus layer: beacon chain, P2P (9000, 9001 QUIC), Beacon API (5052), metrics (8008). Talks to Reth over Engine API (JWT on 8551). |
| **Prometheus** | Scrapes Reth and Lighthouse metrics; UI on 9090. |
| **Grafana** | Dashboards and alerts on Prometheus data; UI on 3000. |
| **Docker bridge** | All containers share `eth-network`; Lighthouse reaches Reth at `http://reth:8551`; Prometheus scrapes reth:9001 and lighthouse:8008. |

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

Single file with node + high-bandwidth tuning. Values are based on [Linux TCP tuning for 10G](https://wiki.xdroop.com/books/linux/page/tcp-tuning-for-10g), [Red Hat TCP buffer tuning](https://docs.redhat.com/documentation/en-us/red_hat_enterprise_linux/10/html/network_troubleshooting_and_performance_tuning/tuning-tcp-connections-for-high-throughput), and BBR recommendations:

- **net.core.***_max** ≥ **tcp_rmem/wmem max** so the global socket limit doesn’t cap TCP; 64MB gives headroom.
- **tcp_rmem/wmem** max 32MB is enough for 2.5G (and 10G with moderate RTT); default 128KB avoids latency spikes from oversized defaults.
- **tcp_mtu_probing=1** enables path MTU discovery when black holes are detected, recommended for high-BW/jumbo frames.
- **fq** + **bbr** are recommended together for high-bandwidth links (BBR is model-based and fills the pipe faster than loss-based cubic).

```bash
sudo tee /etc/sysctl.d/99-ethereum-node.conf << 'EOF'
# Max open files (many peers)
fs.file-max = 2097152

# TCP buffers: min, default, max (bytes). Core max >= tcp max per best practice.
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 131072 33554432
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 2097152
net.core.wmem_default = 2097152

# Connection backlogs
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# TCP behavior
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535

# BBR + fq (recommended for high bandwidth; do not disable tcp_sack/tcp_timestamps)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Path MTU discovery when black holes detected (recommended for 2.5G+ / jumbo)
net.ipv4.tcp_mtu_probing = 1
EOF
```

Apply:

```bash
sudo sysctl --system
```

Revert by removing the file and running `sudo sysctl --system` again, or by restoring from your backup.

### Verify and optional NIC tuning

Check that BBR is in use:

```bash
sysctl net.ipv4.tcp_congestion_control
# Should show: net.ipv4.tcp_congestion_control = bbr
```

**NIC offloads (recommended):** Keep hardware offloads enabled so the NIC handles checksums and segmentation. Check with (replace `eth0` with your interface, e.g. `enp0s31f6`):

```bash
ethtool -k eth0 | grep -E 'tx-checksumming|rx-checksumming|tcp-segmentation-offload|generic-segmentation-offload'
```

If any are `off`, you can enable with (example):

```bash
sudo ethtool -K eth0 tx on rx on gso on tso on
```

To make NIC settings persistent across reboots, use your distro’s method (e.g. netplan, or a systemd service that runs the `ethtool -K` commands at boot). Optional: if you hit high CPU during huge transfers, you can try turning **off** `generic-receive-offload` (gro) and `generic-segmentation-offload` (gso) to trade some CPU for different packet handling; for most users leaving them **on** is best.

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

## 9. Monitoring (Prometheus & Grafana)

**Prometheus** scrapes metrics from Reth (port 9001) and Lighthouse (port 8008). **Grafana** gives you dashboards and alerts on top of that data. Both run in the same Docker stack and reach the clients over `eth-network`.

### What you get

- **Metrics:** Sync status, block height, peer counts, disk I/O, RPC latency, and hundreds of other time-series. Stored in Prometheus and queryable (PromQL) or visualized in Grafana.
- **Logs:** Not stored by Prometheus. View them with Docker:
  - All services: `docker compose logs -f`
  - Reth only: `docker compose logs -f reth`
  - Lighthouse only: `docker compose logs -f lighthouse`
  Tail with `-f`; add `--tail 500` to limit lines.

### Start monitoring

Containers are defined in `docker-compose.yml`. Bring them up with the rest of the stack:

```bash
docker compose up -d
```

Then:

| URL | Service   | Use |
|-----|-----------|-----|
| http://127.0.0.1:9090 | Prometheus | Query metrics (PromQL), check targets under Status → Targets |
| http://127.0.0.1:3000 | Grafana    | Dashboards (login: `admin` / password: `admin`; change on first login) |

### Grafana data source

Add Prometheus as a data source in Grafana:

1. Configuration → Data sources → Add data source → Prometheus.
2. URL: `http://prometheus:9090` (use the service name; Grafana is on the same network).
3. Save & test.

You can then create dashboards or import community ones (e.g. search “Reth” or “Lighthouse” / “Ethereum” in Grafana Labs dashboard catalog).

### Config and data

- **Prometheus config:** `prometheus/prometheus.yml` — scrape jobs for `reth:9001` (path `/`) and `lighthouse:8008` (path `/metrics`). Reload without restart: `curl -X POST http://127.0.0.1:9090/-/reload` (if `--web.enable-lifecycle` is set).
- **Persistent data:** Stored in Docker volumes `prometheus-data` and `grafana-data`. Back them up if you care about long-term history and dashboards.

### Optional: alerts

To add alerting, add an `alerting` section and `alertmanagers` to `prometheus.yml`, or configure alert rules and contact points in Grafana (Alerting → Contact points, Notification policies). That way you can get notified (e.g. by email or Slack) when sync lags or a service is down.

---

## 10. Quick reference

### Host ports (all 127.0.0.1 unless you change compose)

| Port | Service        | Use              |
|------|----------------|------------------|
| 8545 | Reth           | HTTP RPC         |
| 8546 | Reth           | WebSocket RPC    |
| 8551 | Reth           | Engine API (Lighthouse) |
| 9001 | Reth           | Metrics          |
| 5052 | Lighthouse     | Beacon API       |
| 8008 | Lighthouse     | Metrics          |
| 9090 | Prometheus     | Prometheus UI    |
| 3000 | Grafana        | Dashboards       |

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

After that, the node will sync; peer count should rise (especially with port forwarding and reth.toml loaded). Use `docker compose logs -f reth` and `docker compose logs -f lighthouse` for logs; use Prometheus (http://127.0.0.1:9090) and Grafana (http://127.0.0.1:3000) for metrics and dashboards (see [§9 Monitoring](#9-monitoring-prometheus--grafana)).

---

## 11. Base L2 node (op-reth + op-node)

The stack includes **base-reth** (L2 execution, op-reth) and **rollup-client** (op-node). They use your local L1 (reth + lighthouse) for minimal L1→L2 latency, which is important for arbitrage and real-time strategies.

### What runs

| Component       | Role |
|-----------------|------|
| **base-reth**   | L2 execution client (op-reth). Chain `base`, sequencer `https://mainnet-sequencer.base.org`, Engine API on 8552, HTTP/WS RPC on 8547/8548, P2P on 30305, metrics 9002. |
| **rollup-client** | op-node: rollup consensus, drives base-reth via Engine API. Connects to L1 at `http://reth:8545` and `http://lighthouse:5052`, L2 engine at `http://base-reth:8552`. RPC/status on 7545, P2P on 9222 (discv5), metrics 7300. |

**Ports (host):** L2 RPC **8547** (HTTP), **8548** (WS). Sync status: **7545**. P2P: **30305** (base-reth), **9222** (op-node). Keep 9222 open for Base peer discovery.

### Restoring from Base pruned snapshot (recommended)

Using the [official Base pruned Reth snapshot](https://docs.base.org/base-chain/node-operators/snapshots) greatly speeds up initial sync.

**Option A – script (recommended):** From the project root (same dir as `docker-compose.yml`), run once:
```bash
chmod +x scripts/fetch-base-pruned-snapshot.sh
./scripts/fetch-base-pruned-snapshot.sh
```
This creates `base-reth-data`, downloads the latest pruned snapshot (same as the Base docs `wget` command), extracts it, and moves contents into `base-reth-data`. Then start with `docker compose up -d`.

**Option B – manual:**

1. **Create data dir:**  
   `mkdir -p base-reth-data` (must match the volume in `docker-compose.yml`).

2. **Download pruned snapshot (mainnet):**  
   ```bash
   wget -c https://mainnet-reth-pruned-snapshots.base.org/$(curl -sS https://mainnet-reth-pruned-snapshots.base.org/latest)
   ```
   Or for archive:  
   `wget -c https://mainnet-reth-archive-snapshots.base.org/$(curl -sS https://mainnet-reth-archive-snapshots.base.org/latest)`  

   Ensure enough free space for the archive and extraction (see [Base snapshots](https://docs.base.org/base-chain/node-operators/snapshots)).

3. **Extract:**  
   ```bash
   # .tar.zst
   tar -I zstd -xvf <snapshot-filename.tar.zst>
   # or .tar.gz
   tar -xzvf <snapshot-filename.tar.gz>
   ```

4. **Move into `base-reth-data`:**  
   If the archive extracts to a folder (e.g. `reth`), move its contents into `base-reth-data` so that `chaindata`, `nodes`, `segments`, etc. are directly inside `base-reth-data`:
   ```bash
   mv ./reth/* ./base-reth-data/
   rmdir ./reth 2>/dev/null || true
   ```

5. **Start the stack:**  
   `docker compose up -d`. base-reth will sync from the snapshot’s last block. Remove the downloaded archive after confirming sync.

**Note:** The snapshot type (pruned vs archive) is fixed by the snapshot; you cannot switch node type after initial sync.

### Low-latency / arbitrage tuning (already applied)

- **L1 on same host:** rollup-client uses `http://reth:8545` and `http://lighthouse:5052` (no external L1 RPC latency).
- **L1 Reth:** `debug` API enabled on HTTP and WS so op-node’s `--l1.rpckind=debug_geth` can use it for L1 derivation.
- **Engine:** `--engine.memory-block-buffer-target=0` and `--engine.persistence-threshold=0` to reduce stalls.
- **RPC cache:** `--rpc-cache.max-blocks=10000`, `--rpc-cache.max-receipts=10000`, `--rpc-cache.max-concurrent-db-requests=2048` for fast `eth_call` / state reads.
- **base-reth WS:** `miner` namespace on WebSocket so the algo can subscribe to pending blocks and use `eth_getBlockByNumber("pending", ...)` over WS.
- **op-node:** `--l1.http-poll-interval=1s`, `--l1.max-concurrency=200`, `--l2.engine-rpc-timeout=5s`, `--verifier.l1-confs=4` (see below for optional `0`).
- **Memory reservations:** `deploy.resources.reservations.memory` set for reth (4G), lighthouse (4G), base-reth (8G), rollup-client (2G). With plain `docker compose` (no Swarm), use `docker compose --compatibility up` if you want these to apply; otherwise they are documentation of suggested headroom.
- **Hardware:** NVMe SSD, 32–64 GB RAM, and `(2 × chain size) + snapshot size + 20%` free space (see [Base performance](https://docs.base.org/base-chain/node-operators/performance-tuning)).

### Ultra-low latency / arb: optional tweaks

- **Minimum L1 delay:** In `rollup-client` you can set `--verifier.l1-confs=0` instead of `4` so L2 follows L1 with no confirmation wait. Lowers latency and increases reorg risk; only use if your strategy can handle reorgs.
- **Algo side:** Prefer **WebSocket** to the L2 node (`ws://127.0.0.1:8548`) with `eth_subscribe` for `newHeads` and `newPendingTransactions` instead of polling HTTP; avoids poll interval and connection setup latency.
- **CPU pinning (host):** For lowest jitter, pin critical containers to dedicated cores (e.g. `docker update --cpuset-cpus=0-3 reth` and similar for `base-reth`, `rollup-client`). Re-apply after restarts or use a wrapper script; host-specific.
- **Host networking (advanced):** Running base-reth and rollup-client with `network_mode: host` removes bridge latency and can shave a few ms. You’d then use `127.0.0.1` ports directly and lose service names; only consider if you’ve measured bridge overhead.

### Flashblocks (sub-200ms) — enabled, optional for algo

The stack uses Base’s **Flashblocks**-capable image (`ghcr.io/base/node-reth`) with `RETH_FB_WEBSOCKET_URL` and `--websocket-url` set. The node remains **backward compatible**: standard JSON-RPC and 2s blocks are unchanged. When your algo is ready for sub-200ms, use the [Flashblocks API](https://docs.base.org/base-chain/flashblocks/api-reference) (e.g. `eth_subscribe` `newFlashblocks` / `newFlashblockTransactions`, or preconf endpoints). Same pruned snapshot and data dir; no re-sync needed.

### Check L2 sync

```bash
curl -s -X POST -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"optimism_syncStatus","id":1}' http://127.0.0.1:7545 | jq
```

Or compare L2 block to a reference:  
`curl -s -X POST -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://127.0.0.1:8547 | jq`

### JWT

base-reth and rollup-client use the same JWT as L1: `./jwt/jwt.hex` (mount `./jwt` in both services). No extra secret is required.
