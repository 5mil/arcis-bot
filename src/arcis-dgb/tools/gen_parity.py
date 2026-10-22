#!/usr/bin/env python3
"""Parity fixture generator for the Zig port.

Drives the REAL Python paper desk (/workspace/dgb/paper: tick.main -> engine.py) over historical
Binance hourly data, exactly as the 2-hourly routine would, but:
  * the price feed (feed.fetch_all) is replaced by a historical replay at simulated time NOW,
  * engine.STATE points to a throwaway temp dir (the live state/ folder is never touched),
  * config values are overridden IN MEMORY only per scenario (config.py on disk is never edited),
  * engine.round is shadowed by identity so trade rows carry unrounded values (parity at 1e-9).

Writes testdata/bars.json (inputs) and testdata/parity.json (expected events + final ledgers).
"""
import os, sys, json, tempfile, bisect, io, contextlib, datetime as dt, shutil, time

sys.dont_write_bytecode = True
PAPER = "/workspace/dgb/paper"
DATA = "/workspace/dgb"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "testdata")
sys.path.insert(0, PAPER)
import config as C, engine as E, feed as F, tick as T  # noqa: E402

H = 3600000
DAY = 86400000
COINS = ("DGB", "BTC", "LTC", "SOL")

def load(sym):
    return [(int(r[0]), float(r[1]), float(r[2]), float(r[3]), float(r[4])) for r in json.load(open(f"{DATA}/{sym}USDT_1h_long.json"))]

raw = {c: load(c) for c in COINS}
ts = [r[0] for r in raw["DGB"]]
assert all([r[0] for r in raw[c]] == ts for c in COINS)
dgb = raw["DGB"]
maj_close = {c: [r[4] for r in raw[c]] for c in ("BTC", "LTC", "SOL")}
# daily close = close of the last hourly bar of each UTC day
daily = {}
for c in COINS:
    d = {}
    for r in raw[c]:
        d[r[0] - r[0] % DAY] = r[4]
    daily[c] = sorted(d.items())
daily_t = [t for t, _ in daily["DGB"]]
assert all([t for t, _ in daily[c]] == daily_t for c in COINS)

NOW = [0]
def fake_fetch_all(sources):
    now = NOW[0]
    k = bisect.bisect_right(ts, now - H)          # bars with t + 1h <= now (closed)
    lo = max(0, k - 99)
    bars = [dict(t=t, o=o, h=h, l=l, c=c) for (t, o, h, l, c) in dgb[lo:k]]
    kd = bisect.bisect_right(daily_t, now - DAY)  # completed days
    dd = {c: [dict(t=t, o=v, h=v, l=v, c=v) for t, v in daily[c][max(0, kd - 119):kd]] for c in COINS}
    spot = {c: maj_close[c][k - 1] for c in ("BTC", "LTC", "SOL")}
    spot["DGB"] = dgb[k - 1][4]
    return {"src": "replay", "dgb_1h": bars, "daily": dd, "spot": spot}

ORIG_LEDGERS = dict(C.LEDGERS)
ORIG = dict(mode=C.SIPHON_MODE, halt=C.HALT_DRAWDOWN_FROM_START)

def iso_ms(s):
    return int(dt.datetime.fromisoformat(s).timestamp() * 1000)

def run(name, ledger, mode, halt, start, end, tick_h=2):
    tmp = tempfile.mkdtemp(prefix="dgbparity_")
    rows, eq = [], []
    E.STATE = tmp
    E.round = lambda x, n=None: x                 # module-level shadow; engine.py untouched
    E.log_trade = lambda nm, row: rows.append(row)
    E.log_equity = lambda nm, t, u, d: eq.append((t, u, d))
    F.fetch_all = fake_fetch_all
    C.SIPHON_MODE = mode
    C.HALT_DRAWDOWN_FROM_START = halt
    C.LEDGERS = {ledger: ORIG_LEDGERS[ledger]}
    alerts = []
    t0 = time.time()
    now = start
    while now <= end:
        NOW[0] = now
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            T.main()
        alerts += [l for l in buf.getvalue().splitlines() if "HALTED" in l]
        now += tick_h * H
    final = E.load(ledger)
    shutil.rmtree(tmp)
    ev = [dict(t=iso_ms(r[0]), action=r[2], asset=r[3], qty=float(r[4]), price=float(r[5]), usd=float(r[6])) for r in rows]
    halts = []
    if alerts:
        thr = final["start_usd"] * (1 - halt)
        first = next(t for t, u, d in eq if u <= thr)
        halts.append(first - H)
    print(f"{name}: {len(ev)} events, halts={halts}, final DGB={final['h']['DGB']:.2f} USD={final['h']['USD']:.2f} "
          f"BTC={final['h']['BTC']:.6f} ({time.time()-t0:.0f}s)", file=sys.stderr)
    return dict(name=name, ledger=ledger, siphon_mode=mode, halt=halt, start_ms=start, end_ms=end, tick_hours=tick_h,
                events=ev, halts=halts, final=final, equity_last=dict(t=eq[-1][0], usd=eq[-1][1], dgb_eq=eq[-1][2]))

def ms(s):
    return int(dt.datetime.fromisoformat(s).replace(tzinfo=dt.timezone.utc).timestamp() * 1000)

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    end = ts[-1] + H
    end -= end % (2 * H)
    oos, full = ms("2025-04-01T00:00:00"), ms("2023-01-01T00:00:00")
    sc = []
    for L in ("S1", "S5"):
        sc.append(run(f"{L}_oos_cheapest", L, "cheapest", ORIG["halt"], oos, end))
        sc.append(run(f"{L}_oos_cheapest_nohalt", L, "cheapest", 1.0, oos, end))
        sc.append(run(f"{L}_oos_usdt_sol_nohalt", L, "usdt_sol", 1.0, oos, end))
        sc.append(run(f"{L}_full_cheapest_nohalt", L, "cheapest", 1.0, full, end))
    bars = dict(note="Binance USDT 1h; hourly rows [t,o,h,l,c,btc_c,ltc_c,sol_c]; daily [t,c] = close of last hourly bar of the UTC day",
                hourly=[[t, o, h, l, c, maj_close["BTC"][i], maj_close["LTC"][i], maj_close["SOL"][i]] for i, (t, o, h, l, c) in enumerate(dgb)],
                daily={c: [[t, v] for t, v in daily[c]] for c in COINS})
    json.dump(bars, open(os.path.join(OUT, "bars.json"), "w"))
    json.dump(dict(generated_utc=dt.datetime.now(dt.timezone.utc).isoformat(), python=sys.version.split()[0],
                   source="/workspace/dgb/paper tick.main + engine.py (unmodified)", scenarios=sc),
              open(os.path.join(OUT, "parity.json"), "w"))
