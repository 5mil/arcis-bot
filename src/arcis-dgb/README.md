# arcis-dgb: DGB paper-trading engine (Zig)

A Zig port of the Python DGB paper desk (`/workspace/dgb/paper`: `config.py`, `engine.py`, `tick.py`, `report.py`), packaged as a self-contained module you can drop into the **arcis** bot.

**PAPER ONLY.** There are no exchange clients, API keys, order placement or wallet code. `config.paper` is a comptime `true`, and the build fails if you change it.

* Zig: **0.17.0** (installed at `/workspace/tools/zig-x86_64-linux-0.17.0`)
* Strategies:
  * **S1**: volatility-scaled grid.
  * **S5**: regime switch. It runs the grid while DGB is strong against the BTC/LTC/SOL basket and parks everything in BTC when DGB is weak.
* Parity with the Python desk is **bit-exact** on 3,072 trade events across 8 historical scenarios (see below).

## Layout

| File | Purpose |
|---|---|
| `src/config.zig` | Every parameter, value for value with `config.py`: S1/S5 `Params`, siphon (`cheapest` / `usdt_sol`), SOL withdrawal, costs, halt, replay limit. `Config` is a struct whose defaults equal `config.py`, and `config.default` is the comptime instance. Engine functions take `*const Config`, so tests can override a field without editing anything. |
| `src/engine.zig` | The core. It holds `Ledger` state (USD, DGB, LIFO open lots in a fixed array, ref, step, book majors, vault BTC/LTC/SOL/USDT plus a SOL wallet line, mode DGB/BTC, halted flag) and the strategy rules: `dailyCtx` (vol step, siphon rel, regime R/MA), `onNewDay` (step update, vault housekeeping, S5 park/unpark), `gridBar` (intra-bar ordering), `siphon`, `vaultDaily`, `checkHalt`, `stepBar`, `initLedger` and `tick` (the `tick.py` loop). It does no I/O and no heap allocation. All output goes out as `Event`s through a `Sink`. |
| `src/score.zig` | `vaultUsd`, `usdTotal`, `bookDgbEquiv`, `dgbScore` (the DGB-equivalent score), `benchmarks` (hold DGB, 50/50, park in BTC, with the same formulas as `report.py`), `report`, `maxDrawdown`. |
| `src/state.zig` | JSON load and save in the exact schema of the Python `state/S1.json` / `S5.json` files (`indent=1` layout, shortest round-trip floats, atomic tmp+rename save). |
| `src/iface.zig` | **Plug-in points for the live bot.** `Feed` (only `ReplayFeed` is implemented) and `Executor` (only `PaperExecutor` is implemented). |
| `src/desk.zig` | The tick scheduler, which plays the role of the 2-hourly routine: `tickOnce`, `run`. |
| `src/data.zig` | The bar-file loader (`BarSet`). |
| `src/main.zig` | The CLI: `replay` and `show-state`. |
| `src/unit_tests.zig` | Unit tests. |
| `tests/parity.zig` | The parity test against the Python fixtures. |
| `tools/gen_parity.py` | Regenerates `testdata/bars.json` and `testdata/parity.json` from the real Python desk. |
| `tools/check_resume.py` | Cross-language resume check: Python runs to a midpoint, then Zig resumes from Python's state file. |

## Strategy rules (as ported)

* **Daily context.** It uses only completed days strictly before the current day.
  * **Step:** `clamp(k * stdev(ln daily returns, last vol_days, ddof=1), smin, smax)`.
  * **rel:** for each of BTC/LTC/SOL, close divided by its 30-day average. It is 1.0 when there is less history than that.
  * **Regime:** `R = ln DGB - mean(ln BTC, ln LTC, ln SOL)` and `Rma = MA_n(R)`.
* **Grid, on every hourly bar** (only when not halted, active, and the step is known):
  * **Recenter:** after `recenter_days`, if no lots are open, set `ref = open`.
  * **Buy:** while `low < ref/(1+step)`, and USD ≥ slice, and fewer than `levels` lots are open:
    * fill at `level*(1+adverse)`;
    * qty = `slice*(1-maker)/fill`;
    * push the lot;
    * set `ref = level`.
  * **Sell:** while `high > ref*(1+step)` and DGB > 1e-9:
    * fill at `level*(1-adverse)`;
    * pop the **last** lot (LIFO). If there are no lots, sell `min(DGB, slice/level)` of the starting DGB;
    * set `ref = level`;
    * if the round trip gained, siphon.
  * **Ordering:** on a **green bar** (`c >= o`), buys run before sells. On a **red bar**, sells run before buys.
* **Siphon.** 30% of each positive realized gain leaves the book.
  * **`cheapest` mode:** goes into whichever of BTC/LTC/SOL has the lowest rel (ties go to BTC), at the majors' taker cost.
  * **`usdt_sol` mode:** goes into pending USDT (0.1% cost). It converts to SOL when SOL's rel is below 1 or after 30 days.
  * **SOL withdrawal:** vault SOL moves to the SOL wallet line on paper (0.01 SOL estimated fee) once it reaches 1 SOL, or at a quarter start if it holds more than 0.02 SOL.
* **S5 park/unpark** (checked at day open):
  * **Park:** when `R < Rma - band` and the mode is DGB. Sell all DGB at market cost, buy BTC, drop the grid lots.
  * **Unpark:** when `R > Rma + band` and the mode is BTC. Sell BTC, siphon any DGB gained against what was left at park time, rebuy 50/50, and restart the grid at the current price with `slice = total/(2*levels)`.
* **Cost model:**
  * DGB market cost = `0.5% + 0.65% + 1% * min(usd/1500, 3)`.
  * Grid fills = 0.25% maker fee plus 0.1% adverse fill.
  * Majors = 0.5% + 0.01%.
* **Halt.** When the USD value at bar close is ≤ 70% of the start value, set `halted`, emit one `halt` event, and freeze the grid and parks. **It never auto-sells.** Daily vault housekeeping keeps running, as it does in Python.
* **Replay.** Each tick processes at most 72 newly closed hourly bars, keeping the most recent ones.

## Public API (what arcis calls)

```zig
const dgb = @import("arcis_dgb");          // build.zig: b.dependency("arcis_dgb", ...).module("arcis_dgb")

const cfg = &dgb.config.default;           // or a modified copy of dgb.Config
var events = dgb.ListSink.init(gpa);       // or any dgb.Sink{ .ctx, .emitFn }

// create (tick.py first run) or load an existing ledger
var led = try dgb.engine.initLedger(cfg, "S1", dgb.config.s1, last_closed_bar, spot_btc_ltc_sol, daily, "cryptocom", events.sink());
// or: var led = try dgb.state.loadFile(gpa, io, dir, "state/S1.json");

// every routine run: replay newly closed hourly bars (≤ 72)
_ = try dgb.engine.tick(cfg, &led, closed_hourly_bars, spot_btc_ltc_sol, daily, "cryptocom", events.sink());
// or, bar by bar: const eq = try dgb.engine.stepBar(cfg, &led, bar, spot, daily, sink);

const r = dgb.score.report(cfg, &led, prices);   // DGB score, USD total, benchmarks, edges, max DD
try dgb.state.saveFile(gpa, io, dir, "state/S1.json", &led);
```

* **Event fields:** `{ ledger, t_ms, action (buy|sell|siphon|vault_convert|sol_withdraw|park|unpark|halt), asset, qty, price, usd, reason, gain, step, open_lots, levels, aux }`.
* **Mapping to `trades.csv`:** `action.isTrade()` marks the events that correspond to rows in the Python `trades.csv`.
* **Higher level:** `dgb.desk.run(cfg, feed, name, params, &maybe_ledger, .{start_ms, end_ms, tick_hours}, sink)` drives ticks from any `dgb.Feed`.

### Where the live bot plugs in later (NOT implemented)

* **`iface.Feed`:** one `fetch(now_ms) -> Snapshot{hourly, daily, spot, source}`.
  * A live implementation would wrap the same public, keyless klines `feed.py` uses: Crypto.com first, Binance as fallback, closed bars only.
  * `ReplayFeed` follows the same visibility rules: bars with `t+1h <= now`, the last 99 hourly bars, completed days only, and spot = the last closed close.
* **`iface.Executor`:** one `submit(Event)`, used as the engine's `Sink` through `executor.sink()`.
  * `PaperExecutor` counts events and forwards them. The engine's cost model *is* the fill.
  * A future live executor would have to place orders **and reconcile real fills back into the `Ledger`**. That is out of scope here on purpose. Under the standing rules, live orders are placed by the user, and any move to the SOL wallet is done by the user.

## Build, run, test

```sh
export PATH=/workspace/tools/zig-x86_64-linux-0.17.0:$PATH
zig build                       # -> zig-out/bin/arcis-dgb
zig build test --summary all    # unit + parity (test-unit / test-parity run one side)
./zig-out/bin/arcis-dgb replay testdata/bars.json --ledger S1 --start 2025-04-01 [--mode usdt_sol] [--halt 0.30] [--quiet]
./zig-out/bin/arcis-dgb replay testdata/bars.json --ledger S1 --state-in S1.json --state-out out.json   # resume a Python ledger
./zig-out/bin/arcis-dgb show-state /path/to/S1.json
python3 tools/gen_parity.py     # regenerate fixtures from the Python desk (read-only use of /workspace/dgb/paper)
python3 tools/check_resume.py   # needs zig-out/bin/arcis-dgb
```

**Bar file format:**
* `hourly`: rows of `[t_ms, o, h, l, c, btc_close, ltc_close, sol_close]` (DGB/USDT 1h, Binance).
* `daily`: `{DGB|BTC|LTC|SOL: [[day_ms, close], ...]}`, where each daily close is the close of the last hourly bar of that UTC day.

## Parity results (Python 3.13.5 desk vs Zig 0.17.0, 2026-10-22)

`gen_parity.py` drives the **unmodified** `tick.main()` every 2 hours over historical data.
* The feed is replaced by the historical replay.
* `engine.STATE` points to a temp dir.
* Config overrides are made in memory only.
* `engine.round` is shadowed so trade rows carry unrounded values.

| Scenario | Window | Siphon | Halt | Trade events (Zig = Py) | Halts | Max rel diff (events / final) |
|---|---|---|---|---|---|---|
| S1_oos_cheapest | 2025-04-01 → 2026-10-22 | cheapest | 30% | 190 | 0 | 0 / 0 |
| S1_oos_cheapest_nohalt | same | cheapest | off | 190 | 0 | 0 / 0 |
| S1_oos_usdt_sol_nohalt | same | usdt_sol | off | 207 | 0 | 0 / 0 |
| S1_full_cheapest_nohalt | 2023-01-01 → 2026-10-22 | cheapest | off | 444 | 0 | 0 / 0 |
| S5_oos_cheapest | 2025-04-01 → 2026-10-22 | cheapest | 30% | 286 | 1 (bar 2026-05-27 20:00 UTC) | 0 / 0 |
| S5_oos_cheapest_nohalt | same | cheapest | off | 473 | 0 | 0 / 0 |
| S5_oos_usdt_sol_nohalt | same | usdt_sol | off | 511 | 0 | 0 / 0 |
| S5_full_cheapest_nohalt | 2023-01-01 → 2026-10-22 | cheapest | off | 771 | 0 | 0 / 0 |

* **Totals:** 3,072 trade events (2,106 fills) plus 1 halt.
* **Every event matched bit for bit:** same timestamps, actions and assets, and identical qty, price and USD values, against a tolerance of 1e-9.
* **The final ledger was identical** (holdings, vault, grid, lots, peak, max drawdown, fills, mode, flags), against a tolerance of 1e-6, and so was the last equity point.
* **Sensitivity check:** changing `dgb_adverse` by 1e-7 relative makes the test fail.
* **Resume check:** Zig resumed from a Python-written state file at the midpoint and matched the uninterrupted Python run exactly.
* **Live state files:** the live `S1.json`/`S5.json` load and save back equal under Python `==`.

How it is bit-exact:
* `PySum` reproduces CPython ≥3.12's compensated `sum()`.
* Derived constants are computed in f64 at runtime, the same way Python computes them.
* `x ** 2` becomes a single rounded square.

**CLI scores on the out-of-sample window with the live config** (DGB count against the start count):
* S1: +131.1%.
* S5: +76.4%. It halted in May 2026 while parked.
* Benchmarks: park in BTC +120.2%, 50/50 +62.6%.

## Intentional deviations / notes

* **Daily input order.** The daily input must be sorted ascending; `feed.py` always sorts. Python filters an unsorted list, while Zig uses binary search.
* **History window.** Python receives about 119 daily bars per tick, and Zig/`ReplayFeed` may pass the full history. The results are identical, because only the aligned tail (n=90, vol 15, rel 30) is read.
* **Majors price in the historical replay.** It is the latest closed hourly close at tick time, which is what `tick.py` does live. In the backtest lab it was the hourly open.
* **Float formats in JSON.** Zig writes `1.5e-5` where Python writes `1.5e-05`. Both parse to the same value, and integral floats keep `.0`.
* **Feed failures.** These are counted by `desk.run` and leave the ledger untouched. The `feed_fail.flag` file and the alert print are the routine wrapper's job, not the engine's.
* **Event extras.** Python only prints messages for some actions. Zig emits events for every action (for example, `usdt_sol` siphons), and for parity, trade events are compared with `trades.csv` rows.
* **Lot cap.** Open lots are capped at `config.max_levels = 32` (S5 uses 10). Loading a state with more lots returns `InvalidState`.
