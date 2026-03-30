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
12. [Production hardening (HA, latency, metrics)](#12-production-hardening-ha-latency-metrics)

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

Prometheus is **provisioned** as the default data source; the op-node dashboard is provisioned and set as default home. No manual add needed.

You can then create dashboards or import community ones (e.g. search “Reth” or “Lighthouse” / “Ethereum” in Grafana Labs dashboard catalog).

### Safe vs latest, reorgs (op-node / Base)

Prometheus scrapes **all four** node jobs (reth, lighthouse, base-reth, rollup-client) every 10s; the provisioned op-node dashboard shows **L2 safe vs unsafe block numbers**, **lag in blocks**, **latency behind real time**, and **reorg-related events** (pipeline resets, derivation errors). To inspect metrics by hand (all from the `rollup-client` job):
   - **Safe vs latest block number:** `op_node_default_refs_number{layer="l2",type="unsafe"}` (latest) and `op_node_default_refs_number{layer="l2",type="safe"}` (safe). Difference = lag in L2 blocks (~2s per block).
   - **Lag in blocks:** `op_node_default_refs_number{layer="l2",type="unsafe"} - op_node_default_refs_number{layer="l2",type="safe"}`.
   - **Latency behind real time:** `op_node_default_refs_latency{layer="l2",type="unsafe"}` and `...type="safe"` (negative = seconds behind now).
   - **Reorgs / pipeline issues:** `op_node_default_pipeline_resets_total`, `op_node_default_derivation_errors_total`. If `op_node_default_refs_number` goes **backwards**, the node is reorging.

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
| 8545 | Reth           | HTTP RPC (L1)    |
| 8546 | Reth           | WebSocket RPC (L1) |
| 8551 | Reth           | Engine API (Lighthouse) |
| 9001 | Reth           | Metrics          |
| 5052 | Lighthouse     | Beacon API       |
| 8008 | Lighthouse     | Metrics          |
| 8547 | base-reth      | HTTP RPC (L2)    |
| 8548 | base-reth      | WebSocket RPC (L2; use for HFT subscriptions) |
| 8552 | base-reth      | Engine API (op-node) |
| 9002 | base-reth      | Metrics          |
| 7545 | rollup-client  | op-node RPC (sync status) |
| 7300 | rollup-client  | Metrics          |
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

**Node type:** This setup is a **pruned** (full, non-archive) stack: L1 Reth runs with `--minimal` (pruned state); L2 base-reth is restored from the **official Base pruned snapshot**, so you get a pruned L2 node. No archive mode—optimal for arbitrage and HFT (lower disk and faster responses).

The stack includes **base-reth** (L2 execution, op-reth) and **rollup-client** (op-node). They use your local L1 (reth + lighthouse) for minimal L1→L2 latency.

### What runs

| Component       | Role |
|-----------------|------|
| **base-reth**   | L2 execution client (op-reth). Chain `base`, sequencer `https://mainnet-sequencer.base.org`, Engine API on 8552, HTTP/WS RPC on 8547/8548, P2P on 30305, metrics 9002. |
| **rollup-client** | op-node: rollup consensus, drives base-reth via Engine API. Connects to L1 at `http://reth:8545` and `http://lighthouse:5052`, L2 engine at `http://base-reth:8552`. RPC/status on 7545, P2P on 9222 (discv5), metrics 7300. |

**Ports (host):** L2 RPC **8547** (HTTP), **8548** (WS). Sync status: **7545**. P2P: **30305** TCP/UDP (base-reth discv4 + peering), **9201** UDP (base-reth discv5 discovery), **9222** (op-node). Keep 30305, 9201, and 9222 open on the host/firewall for Base peer discovery.

### Restoring from Base pruned snapshot (recommended)

Using the [official Base pruned Reth snapshot](https://docs.base.org/base-chain/node-operators/snapshots) greatly speeds up initial sync.

**Option A – extract script (you already have the snapshot file):** From the project root:
```bash
chmod +x scripts/extract-base-pruned-snapshot.sh
./scripts/extract-base-pruned-snapshot.sh /path/to/your/snapshot.tar.zst
```
This creates `base-reth-data`, extracts the archive, and moves contents so `chaindata`, `nodes`, `segments` are directly inside `base-reth-data`. Then start L2 and monitoring (see “Quick start after L1 sync” below).

**Option B – manual:**

1. **Create data dir:**  
   `mkdir -p base-reth-data`

2. **Download pruned snapshot (mainnet), if needed:**  
   ```bash
   wget -c https://mainnet-reth-pruned-snapshots.base.org/$(curl -sS https://mainnet-reth-pruned-snapshots.base.org/latest)
   ```
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

**Windows:** For `.tar.zst` use Git Bash or WSL and the extract script; for `.tar.gz`, PowerShell: `tar -xzvf snapshot.tar.gz`, then move contents into `base-reth-data`.

**Note:** The snapshot type (pruned vs archive) is fixed by the snapshot; you cannot switch node type after initial sync.

### Quick start after L1 sync (reth + lighthouse synced, pruned snapshot ready)

1. **Extract** the pruned snapshot into `base-reth-data` (script or manual steps above).
2. **Start everything** (L2 + full monitoring): `docker compose up -d`  
   Or only L2: `docker compose up -d base-reth rollup-client`
3. **Verify:**  
   `curl -s -X POST -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","method":"optimism_syncStatus","id":1}' http://127.0.0.1:7545 | jq`

### Validation: ultra-low latency / arb

The compose is tuned for **real-time blocks and arbitrage**: local L1 (no external RPC latency), aggressive L1 polling (500ms), L1 + L2 RPC caches, engine buffers at 0, Base node-reth with Flashblocks, WS with `miner` for pending blocks, and optional `--verifier.l1-confs=0` for minimum L1→L2 delay. For sub-100ms RPC and minimal jitter, run the stack on NVMe with 32–64 GB RAM and have the algo use **WebSocket** (`ws://127.0.0.1:8548`) with `eth_subscribe` rather than HTTP polling.

### Low-latency / arbitrage tuning (already applied)

- **L1 on same host:** rollup-client uses `http://reth:8545` and `http://lighthouse:5052` (no external L1 RPC latency).
- **L1 Reth:** `debug` API enabled on HTTP and WS so op-node’s `--l1.rpckind=debug_geth` can use it for L1 derivation; **RPC cache** (max-blocks, max-receipts, max-concurrent-db-requests) for fast L1 responses to op-node.
- **Engine (base-reth):** `--engine.memory-block-buffer-target=0` and `--engine.persistence-threshold=0` to reduce stalls.
- **RPC cache (L1 + L2):** `--rpc-cache.max-blocks=10000`, `--rpc-cache.max-receipts=10000`, `--rpc-cache.max-concurrent-db-requests=2048` for fast `eth_call` / state reads and L1 derivation.
- **base-reth WS:** `miner` namespace on WebSocket so the algo can subscribe to pending blocks and use `eth_getBlockByNumber("pending", ...)` over WS.
- **op-node:** `--l1.http-poll-interval=500ms` (default 12s), `--l1.max-concurrency=200`, `--l2.engine-rpc-timeout=5s`, `--verifier.l1-confs=2` (see below for optional `0` for minimum latency).
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

---

## 12. Production hardening (HA, latency, metrics)

This section summarizes what the stack does to stay up, recover automatically, run with minimal latency for arbitrage, and collect full metrics. All of this is already applied in `docker-compose.yml`, Prometheus, and Grafana provisioning.

### High availability and recovery

- **Restart policy:** Every service uses `restart: unless-stopped`. If a container exits (crash, OOM, bug), Docker restarts it. Stopping with `docker compose stop` is respected.
- **Start order and health:**  
  - **L1:** Reth must be **healthy** (HTTP 8545 responding) before Lighthouse starts (`depends_on: reth: condition: service_healthy`).  
  - **L2:** base-reth waits for both reth and lighthouse healthy; rollup-client (op-node) waits for base-reth healthy. So the stack comes up in order and doesn’t hit “connection refused” during boot.
- **Healthcheck start period:** Each service has a `start_period` so slow initial sync or snapshot restore doesn’t mark it unhealthy:
  - reth: 120s  
  - lighthouse: 90s  
  - base-reth: 180s (snapshot restore can be long)  
  - rollup-client: 60s  
  During this period, failed checks don’t count toward “unhealthy”; after that, the usual `interval` / `timeout` / `retries` apply.
- **Memory limits:** Reservations + limits are set so one container can’t starve the host: reth 8G, lighthouse 8G, base-reth 16G, rollup-client 4G. Adjust for your RAM; with 32–64 GB these leave headroom for OS and other tools.

### Ultra-low latency (arbitrage / real-time)

- **Local L1:** op-node uses `http://reth:8545` and `http://lighthouse:5052` on the same host — no external RPC latency.
- **L1 polling:** `--l1.http-poll-interval=500ms` (op-node default is 12s). With `--l1.max-concurrency=200` and `--l1.rpc-max-batch-size=50`, L1 data is fetched aggressively.
- **L2 engine:** `--l2.engine-rpc-timeout=5s`; base-reth has `--engine.memory-block-buffer-target=0` and `--engine.persistence-threshold=0` to avoid extra stalls.
- **RPC caches:** L1 Reth and L2 base-reth both use large RPC caches (max-blocks, max-receipts, max-concurrent-db-requests) for fast `eth_call` and L1 derivation.
- **L1 confirmations:** `--verifier.l1-confs=2` balances latency vs reorg risk. For minimum latency (and higher reorg/revert risk) you can set `0`; see [L1_CONFS_ARBITRAGE_RESEARCH.md](L1_CONFS_ARBITRAGE_RESEARCH.md).
- **Algo side:** Use **WebSocket** to L2 (`ws://127.0.0.1:8548`) with `eth_subscribe` for `newHeads` and `newPendingTransactions` instead of HTTP polling.

### Metrics and observability

- **Prometheus:**  
  - Scrape **every 10s** (global `scrape_interval`) for reth, lighthouse, base-reth, rollup-client — near real-time for dashboards.  
  - **Retention:** 15 days and 32 GB cap (`--storage.tsdb.retention.time=15d`, `--storage.tsdb.retention.size=32GB`).  
  - **Alert rules:** `prometheus/alerts.yml` defines alerts for: instance down, op-node derivation errors, pipeline resets, L2 sync stalled, safe-head lag, and (if exposed) Reth peer count. Alerts show in Prometheus → Alerts. For notifications (email, Slack), add [Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/) and configure `alerting` in `prometheus.yml`, or use Grafana Alerting with contact points.
- **Grafana:**  
  - **Provisioned datasource:** Prometheus is auto-configured at `http://prometheus:9090` (see `grafana/provisioning/datasources/datasources.yaml`). No manual “Add data source” needed.  
  - **Provisioned dashboard:** The op-node “Safe vs Latest & Reorgs” dashboard is loaded from `grafana/provisioning/dashboards/json/op-node-dashboard.json`. It appears under Dashboards on first login; default home is set to this dashboard.  
  - Use it to watch L2 safe vs unsafe block numbers, lag, latency behind real time, pipeline resets, derivation errors, and P2P peer count.

### Image pins

- **Reth (L1):** `ghcr.io/paradigmxyz/reth:v1.11.1`  
- **op-node:** `us-docker.pkg.dev/oplabs-tools-artifacts/images/op-node:v1.16.2`  
- **base-reth:** `ghcr.io/base/node-reth:v0.12.9` (pinned for reproducibility; update when you want a newer Base node)  
- **Lighthouse:** `sigp/lighthouse:latest` (consider pinning to a version tag for production)  
- **Prometheus / Grafana:** Version tags in compose.

### Optional next steps

- **Alertmanager:** Add a container and `alerting.alertmanagers` in `prometheus.yml` to send alerts to Slack, PagerDuty, or email.  
- **Grafana Alerting:** Configure contact points and notification policies in Grafana so panels can trigger alerts.  
- **Host tuning:** Apply [§5 Network](#5-network-optimizations-linux), [§6 CPU](#6-cpu-optimizations), and [§7 OS](#7-os-optimizations) on the host (sysctl, CPU governor, file limits) for maximum throughput and stability.  
- **CPU pinning:** For lowest jitter, pin critical containers to dedicated cores (`docker update --cpuset-cpus=...`); re-apply after restarts or use a wrapper script.
