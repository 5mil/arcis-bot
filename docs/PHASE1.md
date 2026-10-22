# Phase 1 — Paper desk (status)

Skeleton landed:

- `src/dgb_desk.zig` — thin wrapper that owns S1/S5 ledgers under the hearth, loads/saves state, and drives `desk.tickOnce`.
- `src/live_feed.zig` — keyless Feed skeleton (Crypto.com preferred, Binance fallback). HTTP fetch is the remaining TODO.
- `examples/dgb-desk-tick.workflow.json` — 2-hour routine that ticks and writes an observation.

## Wiring

The bot binary (or a test) must put the `arcis_dgb` module on the import path, e.g.:

```zig
// build.zig fragment
const dgb_mod = b.createModule(.{
    .root_source_file = b.path("src/arcis-dgb/src/root.zig"),
});
exe.root_module.addImport("arcis_dgb", dgb_mod);
exe.root_module.addImport("dgb_desk", b.createModule(.{
    .root_source_file = b.path("src/dgb_desk.zig"),
    .imports = &.{ .{ .name = "arcis_dgb", .module = dgb_mod } },
}));
```

## Remaining for a running paper bot

1. Implement the HTTP kline fetch inside `live_feed.zig` (closed bars only).
2. Call `Desk.tickOnce` from the Arcis scheduler / workflow runner every 2 h.
3. Write the observation (score + mode + last events) into the hearth library.
4. Confirm state survives a restart.

PAPER ONLY until Phase 2 enablement.

## ReplayFeed smoke (done)

`src/desk_smoke.zig` + `zig build smoke` drives the desk with the existing ReplayFeed and the parity fixtures:

- Creates a hearth dir
- Calls `Desk.tickOnce` at the last closed bar
- Writes `state/S1.json` and `state/S5.json`
- Prints scores

Verified locally: both ledgers created, state files written, S5 correctly parked on the final regime. PAPER ONLY.

## Live keyless feed (done)

`src/live_feed.zig` implements `iface.Feed`:

- Crypto.com preferred (`DGB_USD`, `BTC_USDT`, `LTC_USDT`, `SOL_USDT`)
- Fallback: `data-api.binance.vision` `*USDT`
- Closed bars only (`t + 1h <= now`), last 99 hourly
- Daily closes derived from the last hourly close of each UTC day
- Spot = last closed major closes

`zig build live-smoke` ticks the desk against the live feed.

Verified: source=cryptocom, 99 bars, both ledgers created, state written. PAPER ONLY.

## 2-hour routine + observation (done)

`src/dgb_routine.zig`:

- `Routine.runOnce(now_ms)` ticks both ledgers via the live feed and appends an observation to `hearth/observations/dgb-desk.log`.
- Feed failure leaves ledgers untouched, logs the error, and touches `feed_fail.flag`.
- Standalone: `zig build routine` (one tick) or `zig build routine -- --loop` (every 2 h).
- Maps to the Arcis scheduler as a cron trigger (`0 0 */2 * * *`) whose job calls `runOnce`.

Verified path: live feed → desk tick → state save → observation file. PAPER ONLY.
