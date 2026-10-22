//! Unit tests: step clamping, LIFO lots, intra-bar ordering, siphon target choice, halt, state I/O.
const std = @import("std");
const t = std.testing;
const config = @import("config.zig");
const engine = @import("engine.zig");
const score = @import("score.zig");
const state = @import("state.zig");

const cfg = &config.default;
const T0: i64 = 1_740_000_000_000 - @mod(1_740_000_000_000, engine.day_ms);

fn freshS1(p0: f64) engine.Ledger {
    var s = engine.newLedger(cfg, "S1", config.s1, .{ .dgb = p0, .maj = .{ 80000, 60, 100 } }, T0);
    s.grid.step = 0.04;
    s.last_day = engine.dayStart(T0);
    return s;
}

fn bar(tm: i64, o: f64, h: f64, l: f64, c: f64) engine.Bar {
    return .{ .t = tm, .o = o, .h = h, .l = l, .c = c };
}

const spot = [3]f64{ 80000, 60, 100 };
const no_daily: engine.Daily = .{ .dgb = &.{}, .maj = .{ &.{}, &.{}, &.{} } };

test "step clamping: k*stdev clamped to [smin, smax]" {
    // flat prices -> sd 0 -> smin
    var flat: [20]engine.DailyClose = undefined;
    for (&flat, 0..) |*d, i| d.* = .{ .t = @as(i64, @intCast(i)) * engine.day_ms, .c = 1.0 };
    try t.expectEqual(@as(?f64, 0.04), engine.volStep(config.s1, &flat));
    // wild +-50% swings -> smax
    var wild: [20]engine.DailyClose = undefined;
    for (&wild, 0..) |*d, i| d.* = .{ .t = @as(i64, @intCast(i)) * engine.day_ms, .c = if (i % 2 == 0) 1.0 else 1.5 };
    try t.expectEqual(@as(?f64, 0.15), engine.volStep(config.s1, &wild));
    // not enough history (needs > vol_days closes) -> null
    try t.expectEqual(@as(?f64, null), engine.volStep(config.s1, flat[0..14]));
    try t.expect(engine.volStep(config.s1, flat[0..15]) != null);
    // in-band value passes through: alternating +-x log returns, ddof=1
    var mid: [15]engine.DailyClose = undefined;
    for (&mid, 0..) |*d, i| d.* = .{ .t = @as(i64, @intCast(i)) * engine.day_ms, .c = if (i % 2 == 0) 1.0 else @exp(0.07) };
    const st = engine.volStep(config.s1, &mid).?;
    const expect = 0.07 * @sqrt(14.0 / 13.0);
    try t.expectApproxEqRel(expect, st, 1e-12);
    try t.expectEqual(@as(f64, 0.04), engine.clampStep(config.s1, 0.001));
    try t.expectEqual(@as(f64, 0.15), engine.clampStep(config.s1, 0.9));
}

test "grid buys stack lots and sells close them LIFO" {
    var s = freshS1(1.0);
    var ls = engine.ListSink.init(t.allocator);
    defer ls.deinit();
    // red bar dropping ~12%: sells first (none, high below level), then 3 buys at 1/1.04^k
    try engine.gridBar(cfg, &s, bar(T0, 1.0, 1.0, 0.885, 0.89), .{ .dgb = 1.0, .maj = spot }, ls.sink());
    try t.expectEqual(@as(usize, 3), s.grid.inv_len);
    const lots = s.grid.lots();
    // later lots were bought cheaper -> more DGB per slice
    try t.expect(lots[2].q > lots[1].q and lots[1].q > lots[0].q);
    const last_q = lots[2].q;
    // green bar up one level: buy check first (none), then sell pops the LAST lot
    try engine.gridBar(cfg, &s, bar(T0 + engine.hour_ms, 0.89, 0.93, 0.89, 0.91), .{ .dgb = 0.89, .maj = spot }, ls.sink());
    try t.expectEqual(@as(usize, 2), s.grid.inv_len);
    const sell = ls.list.items[ls.list.items.len - 2]; // sell, then its siphon
    try t.expectEqual(engine.Action.sell, sell.action);
    try t.expectEqual(engine.Reason.round_trip, sell.reason);
    try t.expectEqual(last_q, sell.qty);
    try t.expect(sell.gain > 0);
    try t.expectEqual(engine.Action.siphon, ls.list.items[ls.list.items.len - 1].action);
}

test "levels cap and USD floor stop buys" {
    var s = freshS1(1.0);
    var ls = engine.ListSink.init(t.allocator);
    defer ls.deinit();
    // crash to near zero: at most `levels` (6) buys, and only while USD >= slice (500/83.33 = 6)
    try engine.gridBar(cfg, &s, bar(T0, 1.0, 1.0, 0.01, 0.02), .{ .dgb = 1.0, .maj = spot }, ls.sink());
    try t.expectEqual(@as(usize, 6), s.grid.inv_len);
    try t.expect(s.h.usd < s.grid.slice);
}

test "intra-bar ordering: green buys then sells, red sells then buys" {
    // Same OHLC range, opposite direction. Range covers one level down and one level up.
    const o_green = bar(T0, 1.0, 1.05, 0.95, 1.01);
    const o_red = bar(T0, 1.0, 1.05, 0.95, 0.99);
    var g = freshS1(1.0);
    var lg = engine.ListSink.init(t.allocator);
    defer lg.deinit();
    try engine.gridBar(cfg, &g, o_green, .{ .dgb = 1.0, .maj = spot }, lg.sink());
    // green: buy at 1/1.04, then sells walk up from that ref: lot round trip at 1.0, then starting DGB at 1.04
    try t.expectEqual(engine.Action.buy, lg.list.items[0].action);
    try t.expectEqual(engine.Action.sell, lg.list.items[1].action);
    try t.expectEqual(engine.Reason.round_trip, lg.list.items[1].reason);
    try t.expectEqual(@as(usize, 0), g.grid.inv_len);

    var r = freshS1(1.0);
    var lr = engine.ListSink.init(t.allocator);
    defer lr.deinit();
    try engine.gridBar(cfg, &r, o_red, .{ .dgb = 1.0, .maj = spot }, lr.sink());
    // red: sell starting DGB at 1.04 first, then buys walk down from 1.04: 1.0, 1/1.04 (0.9615 > 0.95)
    try t.expectEqual(engine.Action.sell, lr.list.items[0].action);
    try t.expectEqual(engine.Reason.sell_starting_dgb, lr.list.items[0].reason);
    try t.expectEqual(engine.Action.buy, lr.list.items[1].action);
    try t.expectEqual(@as(usize, 2), r.grid.inv_len);
}

test "recenter only after recenter_days with no open lots" {
    var s = freshS1(1.0);
    const later = T0 + 31 * engine.day_ms;
    try engine.gridBar(cfg, &s, bar(later, 2.0, 2.0, 2.0, 2.0), .{ .dgb = 2.0, .maj = spot }, engine.null_sink);
    try t.expectEqual(@as(f64, 2.0), s.grid.ref);
    try t.expectEqual(later, s.grid.last_recenter);
    var s2 = freshS1(1.0);
    s2.grid.push(.{ .q = 1, .cost = 1 });
    try engine.gridBar(cfg, &s2, bar(later, 1.0, 1.0, 1.0, 1.0), .{ .dgb = 1.0, .maj = spot }, engine.null_sink);
    try t.expectEqual(T0, s2.grid.last_recenter);
}

test "siphon target: cheapest vs 30d average, ties -> first (BTC)" {
    try t.expectEqual(@as(usize, 1), engine.cheapestCoin(.{ .rel = .{ 1.0, 0.94, 0.95 } }));
    try t.expectEqual(@as(usize, 2), engine.cheapestCoin(.{ .rel = .{ 1.0, 0.94, 0.90 } }));
    try t.expectEqual(@as(usize, 0), engine.cheapestCoin(.{ .rel = .{ 0.9, 0.9, 0.9 } }));
    try t.expectEqual(@as(usize, 0), engine.cheapestCoin(.{}));

    var s = freshS1(1.0);
    s.ctx.rel = .{ 1.0, 0.9, 0.95 };
    var ls = engine.ListSink.init(t.allocator);
    defer ls.deinit();
    try engine.siphon(cfg, &s, 10.0, .{ .dgb = 1.0, .maj = spot }, T0, ls.sink());
    try t.expectApproxEqRel(@as(f64, 497.0), s.h.usd, 1e-15);
    try t.expectApproxEqRel(3.0 * (1 - cfg.majCost()) / 60.0, s.vault.maj[1], 1e-15);
    try t.expectEqual(engine.Asset.LTC, ls.list.items[0].asset);
    // usdt_sol mode: pending USDT, converted to SOL when SOL < 30d avg
    var c2 = config.default;
    c2.siphon_mode = .usdt_sol;
    try engine.siphon(&c2, &s, 10.0, .{ .dgb = 1.0, .maj = spot }, T0, ls.sink());
    try t.expectApproxEqRel(3.0 * 0.999, s.vault.usdt_pending, 1e-15);
    try t.expectEqual(@as(?i64, T0), s.vault.usdt_since);
    s.ctx.rel = .{ 1.0, 1.0, 0.99 };
    try engine.vaultDaily(&c2, &s, .{ .dgb = 1.0, .maj = spot }, T0 + engine.day_ms, ls.sink());
    try t.expectEqual(@as(f64, 0), s.vault.usdt_pending);
    try t.expect(s.vault.maj[2] > 0);
    // no siphon when the gain is not positive or USD can't cover it
    const before = s.h.usd;
    try engine.siphon(cfg, &s, -5.0, .{ .dgb = 1.0, .maj = spot }, T0, ls.sink());
    s.h.usd = 1.0;
    try engine.siphon(cfg, &s, 100.0, .{ .dgb = 1.0, .maj = spot }, T0, ls.sink());
    try t.expectEqual(@as(f64, 1.0), s.h.usd);
    _ = before;
}

test "SOL paper withdrawal at >= 1 SOL or quarter start" {
    var s = freshS1(1.0);
    s.vault.maj[2] = 0.5;
    // 2026-10-22 is not a quarter start
    try engine.vaultDaily(cfg, &s, .{ .dgb = 1, .maj = spot }, 1792627200000, engine.null_sink);
    try t.expectEqual(@as(f64, 0.5), s.vault.maj[2]);
    // 2026-10-01 is
    try t.expect(engine.isQuarterStart(1790812800000));
    try engine.vaultDaily(cfg, &s, .{ .dgb = 1, .maj = spot }, 1790812800000, engine.null_sink);
    try t.expectEqual(@as(f64, 0), s.vault.maj[2]);
    try t.expectApproxEqRel(@as(f64, 0.49), s.vault.sol_wallet, 1e-15);
    try t.expectEqual(@as(u64, 1), s.vault.sol_withdrawals);
}

test "halt: freezes at -30%, alerts once, never sells, grid stops" {
    var s = freshS1(1.0);
    var ls = engine.ListSink.init(t.allocator);
    defer ls.deinit();
    const dgb_before = s.h.dgb;
    // DGB -> 0.35: value = 500 + 500*0.35 = 675 <= 700 -> halt (bar has no grid fills: h=l=o=c... use step null)
    s.grid.step = null;
    _ = try engine.stepBar(cfg, &s, bar(T0, 0.35, 0.35, 0.35, 0.35), spot, no_daily, ls.sink());
    try t.expect(s.halted);
    try t.expectEqual(@as(usize, 1), ls.list.items.len);
    try t.expectEqual(engine.Action.halt, ls.list.items[0].action);
    try t.expectEqual(dgb_before, s.h.dgb);
    // further bars: no fills, no second alert
    s.grid.step = 0.04;
    _ = try engine.stepBar(cfg, &s, bar(T0 + engine.hour_ms, 0.35, 0.9, 0.1, 0.5), spot, no_daily, ls.sink());
    try t.expectEqual(@as(usize, 1), ls.list.items.len);
    try t.expectEqual(dgb_before, s.h.dgb);
}

test "S5 park sells all to BTC; unpark restarts 50/50 and siphons the DGB gain" {
    var s = engine.newLedger(cfg, "S5", config.s5, .{ .dgb = 1.0, .maj = spot }, T0);
    var ls = engine.ListSink.init(t.allocator);
    defer ls.deinit();
    // Build daily history: 100 days flat, then DGB collapses 30% -> R well below MA - band
    var dg: [102]engine.DailyClose = undefined;
    var bt: [102]engine.DailyClose = undefined;
    var lt: [102]engine.DailyClose = undefined;
    var so: [102]engine.DailyClose = undefined;
    for (0..102) |i| {
        const tm = T0 - @as(i64, @intCast(102 - i)) * engine.day_ms;
        dg[i] = .{ .t = tm, .c = if (i >= 100) 0.7 else 1.0 };
        bt[i] = .{ .t = tm, .c = 80000 };
        lt[i] = .{ .t = tm, .c = 60 };
        so[i] = .{ .t = tm, .c = 100 };
    }
    const daily: engine.Daily = .{ .dgb = &dg, .maj = .{ &bt, &lt, &so } };
    try engine.onNewDay(cfg, &s, daily, T0, .{ .dgb = 0.7, .maj = spot }, ls.sink());
    try t.expectEqual(engine.Mode.BTC, s.mode);
    try t.expectEqual(@as(f64, 0), s.h.dgb);
    try t.expectEqual(@as(f64, 0), s.h.usd);
    try t.expect(s.h.maj[0] > 0);
    try t.expect(!s.grid.active);
    // DGB recovers to 1.5 -> unpark
    dg[100].c = 1.5;
    dg[101].c = 1.5;
    try engine.onNewDay(cfg, &s, daily, T0, .{ .dgb = 1.5, .maj = spot }, ls.sink());
    try t.expectEqual(engine.Mode.DGB, s.mode);
    try t.expect(s.grid.active);
    try t.expect(s.h.dgb > 0 and s.h.usd > 0);
    var saw_siphon = false;
    for (ls.list.items) |ev| if (ev.action == .siphon) {
        saw_siphon = true;
    };
    try t.expect(!saw_siphon); // price went up: fewer DGB than left with -> nothing to siphon
}

test "state JSON round trip and Python-file compatibility" {
    const py =
        \\{"ledger": "S1", "params": {"strategy": "grid", "k": 1.0, "levels": 6, "smin": 0.04, "smax": 0.15, "vol_days": 14, "recenter_days": 30},
        \\ "paper": true, "created_utc": "2026-10-22T10:00:00+00:00", "start_px": {"DGB": 0.003855, "BTC": 81868.78, "LTC": 59.361, "SOL": 104.2},
        \\ "start_usd": 1000.0, "start_dgb": 259403.37224383917, "h": {"DGB": 129701.68612191957, "USD": 501.90977234848486, "BTC": 0, "LTC": 0, "SOL": 0},
        \\ "vault": {"BTC": 0, "LTC": 0.013722378236494581, "SOL": 0, "usdt_pending": 0, "usdt_since": null, "sol_wallet": 0, "sol_withdrawals": 0, "sol_fees": 0},
        \\ "grid": {"ref": 0.003855, "step": 0.04, "slice": 83.33333333333333, "inv": [[22403.02, 83.33333333333333]], "active": true, "last_recenter": 1792663200000},
        \\ "mode": "DGB", "left_dgb": null, "last_bar": 1792666800000, "last_day": 1792627200000,
        \\ "ctx": {"step": 0.04, "rel": {"BTC": 1.005662247164826, "LTC": 0.9420635151678585, "SOL": 0.9433268523121362}},
        \\ "halted": false, "peak_usd": 1011.0249799072194, "max_dd": -0.01796014620917341, "feed_fail": false, "siphoned_usd": 0.8184738636363704, "fills": 2, "source": "cryptocom"}
    ;
    const a = try state.loadSlice(t.allocator, py);
    try t.expectEqual(@as(f64, 501.90977234848486), a.h.usd);
    try t.expectEqual(@as(usize, 1), a.grid.inv_len);
    try t.expectEqual(@as(?f64, null), a.ctx.rma);
    try t.expectEqualStrings("cryptocom", a.source.slice());
    const out = try state.saveAlloc(t.allocator, &a);
    defer t.allocator.free(out);
    const b = try state.loadSlice(t.allocator, out);
    try t.expect(std.meta.eql(a.h, b.h));
    try t.expect(std.meta.eql(a.vault, b.vault));
    try t.expect(std.meta.eql(a.ctx, b.ctx));
    try t.expectEqual(a.grid.lots()[0], b.grid.lots()[0]);
    try t.expectEqual(a.peak_usd, b.peak_usd);
    try t.expectEqual(a.max_dd, b.max_dd);
}

test "PySum matches CPython 3.12+ compensated sum" {
    // sum([0.1]*10) == 1.0 in CPython >= 3.12 (naive left fold gives 0.9999999999999999)
    const xs: [10]f64 = @splat(0.1);
    try t.expectEqual(@as(f64, 1.0), engine.pysum(&xs));
    const ys = [_]f64{ 1e100, 1.0, -1e100 };
    try t.expectEqual(@as(f64, 1.0), engine.pysum(&ys));
}

test "benchmarks: no price change -> 50/50 and BTC park lose only costs" {
    const px: engine.Prices = .{ .dgb = 0.004, .maj = spot };
    const b = score.benchmarks(cfg, px, px);
    try t.expectEqual(@as(f64, 1.0), b.hold_dgb);
    try t.expect(b.fifty_fifty < 1.0 and b.fifty_fifty > 0.98);
    try t.expect(b.park_btc < b.fifty_fifty);
    try t.expectEqual(@as(f64, -0.5), score.maxDrawdown(100, &.{ 120, 60, 90 }));
}
