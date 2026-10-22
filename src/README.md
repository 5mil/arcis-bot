# Zig extensions

Place thin modules here that import from a sibling checkout of the parent Arcis engine, or self-contained modules that the bot can depend on.

## arcis-dgb

`src/arcis-dgb/` is the DGB paper-trading engine (Zig 0.17+). PAPER ONLY.

It is a self-contained Zig package (`arcis_dgb` module). To use it from the parent Arcis engine or a bot binary:

```zig
// in the consumer build.zig
const dgb_dep = b.dependency("arcis_dgb", .{});
const dgb_mod = dgb_dep.module("arcis_dgb");
// then add to imports
```

Or, since it lives in this tree, a path dependency or direct `@import` works when the repos are side-by-side.

See `src/arcis-dgb/README.md` for the public API, strategies (S1 volatility grid, S5 regime switch), and parity notes.

Example layout when both repos are cloned side-by-side:

```
~/src/
  arcis/          # parent engine
  arcis-bot/      # this repo
    src/
      arcis-dgb/  # DGB paper desk (this module)
      bot_session.zig   # wraps ArcisSession with hearth persistence
      bot_agent.zig     # persistent Agent that resumes from memory
```

These files are intentionally minimal so the single-binary rule is preserved. The real subsystems stay inside the parent engine.
