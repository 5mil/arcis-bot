# Zig extensions

Place thin modules here that import from a sibling checkout of the parent Arcis engine.

Example layout when both repos are cloned side-by-side:

```
~/src/
  arcis/          # parent engine
  arcis-bot/      # this repo
    src/
      bot_session.zig   # wraps ArcisSession with hearth persistence
      bot_agent.zig     # persistent Agent that resumes from memory
```

These files are intentionally minimal so the single-binary rule is preserved. The real subsystems stay inside the parent engine.
