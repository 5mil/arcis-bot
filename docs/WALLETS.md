# Wallet destinations

Rule: **5% of every fully realized gain** returns to the funding wallet (to refuel trading). The remaining **95%** goes to the reward wallet.

## Reward (fixed)

`DLbr1DaJs8bAU7BJfW92rLheVZHzDmR5KJ`

## Funding (build-time, live mode)

Supply the funding DGB address when building for live:

```
zig build -Dfunding=DYourFundingAddress
```

- Paper builds omit it (empty default). The address is unused until the live gate is open.
- Private key stays in a local file (never in git, never in chat) and is only read when `live.enable` matches today.

`zig build wallet-smoke` shows the split. With `-Dfunding=...` it also prints the funding address.
