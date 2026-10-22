# Arcis Bot — DGB Desk Roadmap

Technical path from the current paper engine (`src/arcis-dgb/`) to a running paper bot, then to a tightly controlled live auto-trade mode.

**Standing rules**
- Single binary, local hearth, governed terms.
- Paper until an explicit, reversible hand-off.
- No unrestricted tools or silent live orders.
- All capital decisions stay auditable.

## Current state

- Parent engine: [5mil/arcis](https://github.com/5mil/arcis)
- Bot scaffolding: this repo
- Paper engine: `src/arcis-dgb/` (S1 volatility grid + S5 regime switch)
  - PAPER ONLY (comptime `paper = true`)
  - Bit-exact parity with the Python desk (3,072 trade events)
  - Public API: `initLedger` / `tick` / `stepBar`, `score.report`, JSON state load/save
  - Plug-in points: `iface.Feed`, `iface.Executor` (only Replay + Paper implemented)

## Phase 0 — Hearth + daemon (foundation)

Goal: durable Arcis session that survives restarts.

1. Side-by-side clones of `arcis` + `arcis-bot`.
2. Build parent engine (`zig build`).
3. Create hearth directory; point daemon at it.
4. Run via systemd unit (`deploy/systemd/arcis-bot.service`) or equivalent.
5. Confirm load/flush of NameStore, ConceptStore, agent memory.

Exit: bot process restarts cleanly and retains identity + memory.

## Phase 1 — Paper desk running on a schedule

Goal: 2-hourly paper ticks that update ledgers and emit observations. No keys, no orders.

### 1.1 Thin desk wrapper
`src/dgb_desk.zig` (or equivalent):
- Owns S1 and S5 ledgers + state files under the hearth.
- Single entry: `tickOnce(now_ms)` → load → fetch → `engine.tick` → save → return events + score.
- Uses the existing `arcis_dgb` module (path or sibling import).

### 1.2 Keyless Feed
Implement `iface.Feed`:
- Crypto.com klines preferred, Binance fallback.
- Closed bars only (`t + 1h <= now`), last ~99 hourly, completed dailies.
- Spot = last closed hourly close.
- Same visibility rules as `ReplayFeed`.

### 1.3 Routine
Workflow (or direct scheduler call) every 2 hours:
- Calls the desk wrapper.
- Writes a short observation (DGB score, USD total, mode, open lots, vault, any halt/park/unpark).
- On repeated feed failure: set `feed_fail.flag` and alert (no ledger mutation).

### 1.4 Observation
Minimal surface (CLI flag, dashboard pane, or log):
- Current score vs start and vs the three benchmarks.
- Mode (grid / parked / halted).
- Last N events.
- Peak / max drawdown.

Exit: paper bot ticks unattended, state survives restarts, observations are readable.

## Phase 2 — Live auto-trade (opt-in, protected)

Goal: real orders, but only after an explicit enablement, with hard stops and reconciliation.

**This phase is not active by default.** Crossing into it requires a deliberate config change + human confirmation.

### 2.1 Enablement gate
- Separate `live_enabled` flag (default false), stored in hearth, changeable only by an authenticated local action.
- When false, the executor remains `PaperExecutor`.
- When true, a live executor is swapped in; paper cost model remains the reference until fills are reconciled.

### 2.2 Live Executor
Implements `iface.Executor.submit(Event)`:
- Places the corresponding order (limit for grid, market for park/unpark).
- Waits for fill or timeout.
- Reconciles actual fill (qty, price, fee) back into the `Ledger`.
- On mismatch beyond tolerance: halt the ledger and alert (do not continue).

No wallet moves. SOL withdrawals stay manual.

### 2.3 Stops and protections (non-negotiable)

| Protection | Rule | Action |
|---|---|---|
| Drawdown halt | Existing: book USD ≤ (1 − halt_drawdown_from_start) × start | Freeze grid + parks; no auto-sell; alert |
| Daily loss cap | Configurable max USD loss per UTC day | Halt for the rest of the day |
| Position size cap | Max notional per order and max open lots | Reject excess; log |
| Consecutive error halt | N failed orders or feed failures in a window | Halt + require manual reset |
| Slippage / fill mismatch | Actual fill worse than paper model by > X bps or > Y % qty | Halt ledger; alert |
| Manual kill switch | Local file or authenticated endpoint | Immediate halt of all live ledgers |
| Audit log | Every live order + reconciliation written to hearth | Immutable append-only |

All of the above emit an observation and set the ledger `halted` flag so the existing engine freezes.

### 2.4 Reconciliation loop
- After every live fill, re-read balances (or order status) and compare to ledger.
- Persistent discrepancy → halt and require human review.
- Paper score remains the internal benchmark even in live mode.

### 2.5 Roll-out sequence
1. Paper bot stable for ≥ 2 weeks.
2. Live executor behind the enablement gate, tested with tiny size on one ledger.
3. Stops verified (forced halt, kill switch, mismatch halt).
4. Increase size only after clean reconciliation history.
5. Second ledger only after the first has proven stable.

Exit: live orders occur only when explicitly enabled, every order is reconciled, and any protection trips freeze the desk without further action.

## Suggested implementation order

1. Phase 0 (hearth + daemon)
2. Phase 1.1–1.4 (wrapper, Feed, routine, observation)
3. Paper soak
4. Phase 2 design review + enablement gate
5. Live executor + protections
6. Tiny-size live trial → scale

## Non-goals (for now)

- Fully autonomous capital allocation beyond the existing S1/S5 rules.
- Cross-exchange arbitrage or margin.
- Automatic SOL (or any) wallet withdrawals.
- Silent fallback to live when paper is selected.

All live behavior remains an explicit, reversible overlay on the paper engine that is already parity-tested.
