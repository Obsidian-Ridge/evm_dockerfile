# Base arbitrage: low-latency setup

Notes for ultra-low latency and real-time blocks when arbitrating on Base. Summary of what’s in place, what was added, and what to consider next.

---

## What you’re already doing right

- **op-node L1 polling:** `--l1.http-poll-interval=500ms` (default is 12s). This is the main lever for “see new L1 blocks fast” so derivation isn’t delayed.
- **L1 confirmations:** `--verifier.l1-confs=0` minimizes delay before accepting L2 blocks (higher reorg risk; appropriate for arbitrage).
- **L1 concurrency:** `--l1.max-concurrency=200`, `--l1.rpc-max-batch-size=50` keep L1 RPC from being the bottleneck.
- **L2 engine:** `--l2.engine-rpc-timeout=5s`, local `base-reth:8552` so op-node → base-reth is low latency.
- **base-reth memory/IO:** `--engine.memory-block-buffer-target=0`, `--engine.persistence-threshold=0` reduce stalls; RPC cache (10k blocks/receipts) speeds `eth_call` for arb.
- **Flashblocks:** `RETH_FB_WEBSOCKET_URL` and `--websocket-url=wss://mainnet.flashblocks.base.org/ws` are set. The node is Flashblocks-aware; sub-200ms *preconfirmations* are consumed by your arb app (e.g. via that WS or a provider like bloXroute/GetBlock), not only by the node.
- **Rollup config:** `--rollup.sequencer-http`, `--rollup.disable-tx-pool-gossip` are correct for a replica.

---

## What was added (base-reth peers)

- **Base mainnet bootnodes** (official enodes, port 30301) so base-reth discovers peers quickly instead of relying only on discv4/discv5.
- **`--peers-file /data/peers.txt`** so discovered peers are persisted across restarts (faster reconnect, more stable peer count).

Together with **opening 30305 TCP/UDP** and **9201 UDP** (discv5) for base-reth, and 9222 for op-node, on the host/firewall, this should improve base-reth peer count and block propagation. (Reth uses a separate port for discv5; without 9201 exposed, discovery stays near zero and connected peers remain low.)

---

## Block path (where latency comes from)

1. **L1:** New block on Ethereum → your reth + Lighthouse see it.
2. **op-node:** Polls L1 every 500ms, derives L2 payload, sends to base-reth via Engine API (NewPayload / ForkchoiceUpdated).
3. **base-reth:** Executes payload. If it already has the block (from op-node), it doesn’t need P2P. If it needs block bodies (e.g. after a restart or reorg), it fetches from **P2P peers** — hence more peers + bootnodes help.
4. **Your arb app:** Reads from base-reth RPC (8547/8548). For sub-200ms preconfirmations, use Flashblocks in the app (WS or provider).

So: **more base-reth peers** mainly help when the node has to catch up or refetch; for a fully synced replica, op-node → engine is the critical path, and you’ve already tuned that.

---

## Optimal peer counts (ultra-low latency / real-time blocks)

**Reth defaults** (from Reth core dev / chain operators): **30 inbound, 100 outbound**. More peers = more redundancy and faster block/header availability; too many = connection churn, CPU, and backoff noise without clear latency gain.

| Node        | Role for latency | Suggested range (out / in) | Your compose | Notes |
|------------|-------------------|----------------------------|--------------|--------|
| **reth (L1)** | Feed L1 data to op-node so derivation isn’t delayed. More peers = see new L1 blocks from more sources. | **100–200** out, **100–200** in | 200 / 200 | Already optimal. 200 is a common operator upper bound; going to 300+ rarely helps and can add churn. |
| **base-reth (L2)** | Realtime blocks come from **op-node → Engine API**, not P2P. P2P is for catch-up, reorgs, restarts. | **50–150** out, **50–150** in | 150 / 150 | 50–100 is enough for catch-up; 100–150 gives headroom. Your 150/150 is fine; no need to push 200+ for a replica. |

**Takeaway:** For real-time blocks, the critical path is **op-node (500ms L1 poll) → L1 reth → derivation → base-reth Engine API**. Peer count mainly improves redundancy and catch-up. Your current settings (L1: 200/200, L2: 150/150) are already in the recommended range; no change required unless you want to lower base-reth to ~100/100 to reduce connection overhead.

---

## Optional next steps

- **Hardware (Base docs):** For production-grade latency, Base recommends locally attached NVMe (no EBS), 32–64 GB RAM, strong single-core CPU (e.g. AWS `i7i.12xlarge`-style). Your `base-reth-data` should live on fast local SSD.
- **op-node P2P:** You already have 9222 open and `--p2p.peers.hi=100`. op-node P2P is for rollup payload gossip; more peers can improve how fast you see new L2 payloads from the network (in addition to derivation).
- **Flashblocks in the arb app:** If you want to react in the sub-200ms window, integrate a Flashblocks stream (e.g. `wss://mainnet.flashblocks.base.org/ws` or a provider’s parsed stream) in your trading/arb logic; the node config alone doesn’t give you preconfirmations in the app.
- **Monitoring:** Use the Grafana dashboards (Stack Health, Base-Reth L2, op-node) to watch safe lag, derivation errors, and peer count; alert on derivation errors or safe lag growing.

---

## References

- [Base node performance tuning](https://docs.base.org/base-chain/node-operators/performance-tuning)
- [Base Flashblocks (node providers)](https://docs.base.org/base-chain/flashblocks/node-providers)
- [Reth peering (Rez / 0xZorz)](https://medium.com/@0xZorz/reth-peering-for-chain-operators-9aeecfd4d7ae)
- Base mainnet bootnodes: `base/node` [.env.mainnet](https://github.com/base/node/blob/main/.env.mainnet) (optional GETH/RETH bootnodes section)
