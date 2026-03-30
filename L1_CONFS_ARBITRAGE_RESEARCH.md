# Research: `--verifier.l1-confs` and arbitrage (reorgs, reverts, comparing state)

## Does `--verifier.l1-confs=0` affect arbitrage?

**Yes.** It can directly cause your arbitrage transactions to revert when L2 reorganizes.

### What `verifier.l1-confs` does

From [op-node config](https://docs.optimism.io/node-operators/reference/op-node-config):

- **`--verifier.l1-confs=N`** = “Number of L1 blocks to **keep distance from the L1 head** before deriving L2 data from.”
- So:
  - **0** → derive L2 from the **current L1 head** (lowest latency, highest reorg risk).
  - **1** → derive only after there is **1 newer L1 block** on top of the block you derive from.
  - **2** → wait for **2** L1 blocks on top (your current setting in `docker-compose.yml`).
  - **4** → wait for 4 (often used for “safer” defaults).

So with `l1-confs=0`, your L2 chain is built on L1 blocks that might still be reorganized away. With `l1-confs=2`, you only advance the **safe** L2 head after an L1 block has 2 confirmations, so short reorgs are less likely to affect what the node treats as safe.

### Why that causes reverts

1. **L2 is derived from L1.** Each L2 block has an **L1 origin** (the L1 block it’s tied to). If that L1 block is reorganized off the canonical L1 chain, the op-node must **reset derivation** and the L2 chain **reorgs** too.
2. **Unsafe vs safe:** The op-node has:
   - **Unsafe head** = highest L2 block derived (what you see as `latest` / “head”).
   - **Safe head** = highest L2 block derived from L1 that has met the `l1-confs` rule (fewer reorgs).
3. With **`l1-confs=0`**, the “safe” head is advanced as soon as an L1 block is seen, so **safe ≈ unsafe**. Any L1 reorg immediately threatens both; your arb tx might be in an L2 block that gets reorged out → **tx reverts** (block no longer canonical).
4. With **`l1-confs=2`**, the safe head lags by 2 L1 blocks. Short L1 reorgs (1 block) don’t force the **safe** L2 chain to change; only the **unsafe** part might reorg. So if you build and submit arbs only after they’re on **safe** (or you wait for safe), you’re less likely to hit reverts from small reorgs.

So: **`--verifier.l1-confs=0` can definitely be affecting your arbitrage** by making reverts more likely when L1 (or sequencer equivocation) causes L2 reorgs.

---

## Comparing reserves, liquidity, pools, transactions: 0 vs 1 vs 2 confs

### Easy way: pull block when you see it, pull again later, compare

Yes — this is the straightforward approach:

1. **When you first see block N** (e.g. via `eth_subscribe` `newHeads` or polling `eth_blockNumber`):
   - Call `eth_getBlockByNumber(N, true)` and store: block hash, transactions (or tx hashes), stateRoot, and any state you care about (e.g. `eth_call` for pool reserves at block N).
2. **Later** (e.g. 30 seconds, or 5 L2 blocks, or 2 L1 blocks — pick a delay that’s “after” when reorgs usually settle):
   - Call `eth_getBlockByNumber(N, true)` again for the **same block number**.
3. **Compare:** If the block **hash** (or stateRoot, or transaction list) is different from what you stored → that block was **reorged**. You can then diff:
   - Old vs new block hash / stateRoot / transactions.
   - Old vs new reserves (or any state you snapshotted at step 1).

So: **same block number, different content later = reorg**. No need for multiple nodes or complex setup; one RPC, fetch twice, compare.

---

You only get **one** canonical L2 chain per node. Different `l1-confs` values don’t give you “multiple views” on the same node; they change **when** the safe head advances. So to compare state **across** different confirmation levels you have to either run multiple setups or record state and detect reorgs.

### Option 1: Multiple stacks (different `l1-confs`)

- Run **separate** stacks (different compose projects or hosts):
  - Stack A: `--verifier.l1-confs=0`
  - Stack B: `--verifier.l1-confs=1`
  - Stack C: `--verifier.l1-confs=2`
- At the **same wall-clock time**, query each L2 RPC:
  - `eth_blockNumber` / `eth_getBlockByNumber("latest")` → block number and hash.
  - Your pool/reserve reads (e.g. `eth_call` for pool state) at that block.
- Compare:
  - L2 block numbers and hashes (unsafe and safe if you query both).
  - Reserves, liquidity, and transactions for the same pool/block where possible.

**Pros:** Direct comparison of “what would I see with 0 vs 1 vs 2 confs” at the same moment.  
**Cons:** Heavy (multiple full L2 nodes + op-nodes); also need to align by time or by L1 block number, since each stack will be at a different L2 height.

### Option 2: Single node – log “safe” vs “latest” and reorg events

- Run **one** stack (e.g. with `l1-confs=2` as now).
- Periodically (e.g. every new L2 block or every 2s):
  - Query `eth_getBlockByNumber("safe", false)` and `eth_getBlockByNumber("latest", false)` (and optionally `finalized`).
  - Record: L2 block number, block hash, L1 origin (from block or `optimism_syncStatus`), and your key state (reserves for target pools) at **safe** and at **latest**.
- **Reorg detection:** If for the same L2 block number you see a **different block hash** than before, that’s a reorg. Log it and compare reserves before/after.

This doesn’t give you “state at l1-confs=0 vs 2” on the same run, but it shows:
- How far **latest** is ahead of **safe** (the “unsafe” tail).
- **When** reorgs happen and how often they change the state you care about.

### Option 3: Run with `l1-confs=0`, log state and detect reorgs

- Set `--verifier.l1-confs=0` (e.g. in a copy of compose).
- For every new L2 block, log:
  - L2 block number, block hash, L1 origin block number.
  - Reserves (and any pool/liquidity/tx data) at that block.
- **Reorg detection:** Same as above – if block number goes **backward** or the **same block number** gets a **new hash**, the previous block was reorged. Then you can:
  - Compare “state in the reorged block” vs “state in the new canonical block at that height” (if any).
  - Count how often reorgs happen and how much reserves/pools differ.

So you’re comparing **“state that got reorged away”** vs **“state that stayed”** – which is exactly the kind of divergence that causes arb reverts when you use `l1-confs=0`.

### Option 4: Use L1 “safe” / “finalized” only as reference (no second L2 chain)

- On **L1** (your reth node), `eth_getBlockByNumber("safe", ...)` and `eth_getBlockByNumber("finalized", ...)` give you L1’s view of confirmed vs head.
- That doesn’t give you a second L2 chain, but you can:
  - Map L2 blocks to L1 origin (from block attributes or sync status).
  - When you see an L2 block whose L1 origin is before L1 “safe”, that L2 block is “more confirmed” from L1’s perspective. So you can align “how many L1 confirmations did this L2 block’s origin have?” with your `l1-confs` setting and your reorg logs.

---

## Other ways to test the L1 verifier

Besides “pull block now, pull same block later, compare” (reorg detection), you can test that the verifier is applying `l1-confs` like this:

### 1. **optimism_syncStatus** (op-node RPC)

Shows the refs the verifier uses: L1 head, L2 unsafe (latest), L2 safe, L2 finalized. Safe lags behind unsafe when `l1-confs > 0`.

- **op-node RPC:** `docker-compose.yml` → `http://127.0.0.1:7545`; `docker-compose_curr.yml` → `http://127.0.0.1:8549`
- **Check:** `current_l1` vs `head_l1` (L1 confirmations), and `unsafe_l2.number` vs `safe_l2.number` (L2 block gap). With `l1-confs=2`, safe should be behind unsafe by a few to ~12 L2 blocks (≈ 2 L1 blocks × ~6 L2 blocks per L1 on Base).

```bash
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"optimism_syncStatus","id":1}' \
  http://127.0.0.1:7545 | jq
```

### 2. **Safe vs latest on L2** (base-reth RPC)

The execution layer gets safe/unsafe from op-node. Query the same block tags:

- **L2 RPC:** `http://127.0.0.1:8547`
- **Check:** Block number for `"safe"` vs `"latest"`. With `l1-confs=0` they’re equal or 1 block apart; with `l1-confs=2` you should see a small gap (e.g. 2–12 blocks).

```bash
echo "Latest (unsafe):"; curl -s -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' http://127.0.0.1:8547 | jq '.result.number, .result.hash'
echo "Safe:"; curl -s -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["safe",false],"id":1}' http://127.0.0.1:8547 | jq '.result.number, .result.hash'
```

### 3. **Prometheus metrics** (op-node)

If Prometheus scrapes op-node (e.g. `rollup-client:7300` or `localhost:7300` with host networking):

- **Safe vs unsafe L2 block:** `op_node_default_refs_number{layer="l2",type="unsafe"}` and `...type="safe"`. Difference = lag in L2 blocks.
- **Lag over time:** `op_node_default_refs_number{layer="l2",type="unsafe"} - op_node_default_refs_number{layer="l2",type="safe"}`.
- **Reorgs / resets:** `op_node_default_pipeline_resets_total`, `op_node_default_derivation_errors_total`, `op_node_default_l1_reorg_depth_count` (if present). Spikes = verifier reacting to L1 reorgs.

Use the repo’s `grafana-op-node-dashboard.json` (see SETUP.md §9) to graph safe vs unsafe and lag.

### 4. **A/B test: two stacks, different l1-confs**

Run two separate stacks (e.g. different compose files or hosts), one with `--verifier.l1-confs=0` and one with `--verifier.l1-confs=2`, both on the same L1. At the same time:

- Call `optimism_syncStatus` on each op-node (different ports).
- Compare `safe_l2.number`: the node with `l1-confs=2` should report a **lower** safe L2 block number than the one with `l1-confs=0`. That directly shows the verifier holding back safe until more L1 blocks confirm.

---

## Practical recommendation

1. **Confirm reorgs are the cause of reverts:**  
   Log L2 block number + hash + L1 origin (and optionally safe/latest) every block. When a revert happens, check if the block your tx was in later changed (reorg). If yes, that’s consistent with `l1-confs=0` (or low confs) increasing revert risk.

2. **Compare state across confs:**  
   - **Lightweight:** Option 2 (single node, safe vs latest + reorg detection).  
   - **Direct comparison:** Option 1 (multiple stacks with 0 / 1 / 2 confs) if you have the resources.

3. **Tuning:**  
   - For **lower revert risk**, keep or increase `--verifier.l1-confs` (e.g. 2 as in your current `docker-compose.yml`; or 4 as in SETUP.md).  
   - For **lowest latency** and you accept more reverts, use `0` (as in `docker-compose_curr.yml`).  
   - Docs suggest keeping `verifier.l1-confs` in the **~10–20 L1 blocks** range for performance; going much higher can hurt.

4. **RPC block tags:**  
   When calling your L2 node (base-reth), you can query:
   - `eth_getBlockByNumber("latest", false)` → current head (unsafe).
   - `eth_getBlockByNumber("safe", false)` → safe head (respects l1-confs).
   - `eth_getBlockByNumber("finalized", false)` → finalized head.  
   Use these in your comparison scripts (Option 2) to snapshot reserves/pools at different safety levels on the same node.

---

## References

- [OP Stack Verifier spec](https://specs.optimism.io/interop/verifier.html) – unsafe → safe → finalized; safe may be reorged.
- [OP Stack Derivation spec](https://specs.optimism.io/protocol/derivation.html) – L2 derived from L1; reorgs reset derivation.
- [Optimism reorg / double-spend](https://docs.optimism.io/op-stack/interop/reorg) – L1 reorg and equivocation; “L1 reorgs are basically invisible to L2” once data is reposted, but **until** then, derivation can change and L2 reorgs.
- [op-node config](https://docs.optimism.io/node-operators/reference/op-node-config) – `verifier.l1-confs` definition and recommendation (e.g. 10–20 blocks for performance).
- Your `docker-compose.yml` line 363–364: comment and `--verifier.l1-confs=2`.
