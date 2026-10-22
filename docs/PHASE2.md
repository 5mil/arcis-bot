# Phase 2 — Live enablement (skeleton)

Live orders are impossible unless an explicit, daily token is present.

## Gate

`src/live_gate.zig` — `Gate.check` returns enabled only when `hearth/live.enable` contains:

```
LIVE_ENABLE <utc_day_number>
```

Token must match today's UTC day. Remove the file to disable.

## Executor skeleton

`src/live_executor.zig` — `LiveExecutor.consider`:

- Kill switch: presence of `hearth/KILL` → halt + audit
- Gate must be open
- Daily loss cap
- Max order notional and max open lots
- Consecutive error halt
- Every decision written to `hearth/audit/`

**Does not place orders.** Returns false (and audits `GATE`) while the gate is closed.

## Verified

`zig build gate-smoke`:

```
gate enabled=false reason=no live.enable
consider returned false
audit: 0 S1 GATE no live.enable
```

PAPER ONLY until a real exchange client is deliberately wired behind an open gate.
