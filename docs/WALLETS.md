# Wallet destinations

Rule: **5% of every fully realized gain** is recorded as a return to the funding wallet (to refuel trading). The remaining **95%** goes to the reward wallet.

- Addresses are public.
- Keys stay in local files (never in git, never in chat) and are only read when the live gate is open.
- Paper mode only records the split (`hearth/wallets/latest-split.log`). No chain sends.
- Live sends stay behind the daily `live.enable` token and the existing protections.

Set the addresses in code or at startup:

```zig
var w = wallets.Wallets{};
w.setFunding("D...");
w.setReward("D...");
```

`zig build wallet-smoke` confirms the 5/95 split.
