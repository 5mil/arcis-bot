//! Parity: the Zig engine must reproduce the Python paper desk event-by-event.
//! Fixtures: testdata/bars.json (inputs) and testdata/parity.json (Python events + final ledgers),
//! produced by tools/gen_parity.py, which drives the unmodified /workspace/dgb/paper tick.py/engine.py.
const std = @import("std");
const lib = @import("arcis_dgb");
const opts = @import("build_options");
const engine = lib.engine;
const t = std.testing;

const EVENT_RTOL = 1e-9;
const FINAL_RTOL = 1e-6;

const PyEvent = struct { t: i64, action: []const u8, asset: []const u8, qty: f64, price: f64, usd: f64 };
const Scenario = struct {
    name: []const u8,
    ledger: []const u8,
    siphon_mode: []const u8,
    halt: f64,
    start_ms: i64,
    end_ms: i64,
    tick_hours: i64,
    events: []const PyEvent,
    halts: []const i64,
    final: std.json.Value,
    equity_last: struct { t: i64, usd: f64, dgb_eq: f64 },
};
const Fixture = struct { scenarios: []const Scenario };

fn relDiff(a: f64, b: f64) f64 {
    const d = @abs(a - b);
    if (d == 0) return 0;
    const m = @max(@abs(a), @abs(b));
    if (m < 1e-300) return d;
    return d / m;
}

const Worst = struct {
    v: f64 = 0,
    fn upd(w: *Worst, a: f64, b: f64) f64 {
        const r = relDiff(a, b);
        w.v = @max(w.v, r);
        return r;
    }
};

fn checkFinal(name: []const u8, z: *const lib.Ledger, p: *const lib.Ledger, worst: *Worst) !void {
    const pairs = [_][2]f64{
        .{ z.h.dgb, p.h.dgb },                           .{ z.h.usd, p.h.usd },
        .{ z.h.maj[0], p.h.maj[0] },                     .{ z.h.maj[1], p.h.maj[1] },
        .{ z.h.maj[2], p.h.maj[2] },                     .{ z.vault.maj[0], p.vault.maj[0] },
        .{ z.vault.maj[1], p.vault.maj[1] },             .{ z.vault.maj[2], p.vault.maj[2] },
        .{ z.vault.usdt_pending, p.vault.usdt_pending }, .{ z.vault.sol_wallet, p.vault.sol_wallet },
        .{ z.vault.sol_fees, p.vault.sol_fees },         .{ z.grid.ref, p.grid.ref },
        .{ z.grid.slice, p.grid.slice },                 .{ z.peak_usd, p.peak_usd },
        .{ z.max_dd, p.max_dd },                         .{ z.siphoned_usd, p.siphoned_usd },
        .{ z.start_dgb, p.start_dgb },                   .{ z.left_dgb orelse 0, p.left_dgb orelse 0 },
        .{ z.grid.step orelse 0, p.grid.step orelse 0 }, .{ z.ctx.r orelse 0, p.ctx.r orelse 0 },
        .{ z.ctx.rma orelse 0, p.ctx.rma orelse 0 },
    };
    for (pairs, 0..) |pr, i| {
        if (worst.upd(pr[0], pr[1]) > FINAL_RTOL) {
            std.debug.print("{s}: final field #{d} zig={d} py={d}\n", .{ name, i, pr[0], pr[1] });
            return error.FinalMismatch;
        }
    }
    try t.expectEqual(p.fills, z.fills);
    try t.expectEqual(p.mode, z.mode);
    try t.expectEqual(p.halted, z.halted);
    try t.expectEqual(p.grid.active, z.grid.active);
    try t.expectEqual(p.grid.inv_len, z.grid.inv_len);
    for (z.grid.lots(), p.grid.lots()) |a, b| {
        if (worst.upd(a.q, b.q) > FINAL_RTOL or worst.upd(a.cost, b.cost) > FINAL_RTOL) return error.FinalMismatch;
    }
    try t.expectEqual(p.last_bar, z.last_bar);
    try t.expectEqual(p.last_day, z.last_day);
    try t.expectEqual(p.grid.last_recenter, z.grid.last_recenter);
    try t.expectEqual(p.vault.sol_withdrawals, z.vault.sol_withdrawals);
    try t.expectEqual(p.vault.usdt_since, z.vault.usdt_since);
    try t.expectEqualStrings(p.created_utc.slice(), z.created_utc.slice());
}

test "parity with Python paper desk (tick.py + engine.py)" {
    const gpa = t.allocator;
    const io = t.io;
    var dir = try std.Io.Dir.cwd().openDir(io, opts.testdata, .{});
    defer dir.close(io);

    const bars_bytes = try dir.readFileAlloc(io, "bars.json", gpa, .limited(256 << 20));
    defer gpa.free(bars_bytes);
    var bars = try lib.data.parse(gpa, bars_bytes);
    defer bars.deinit(gpa);

    const fx_bytes = try dir.readFileAlloc(io, "parity.json", gpa, .limited(256 << 20));
    defer gpa.free(fx_bytes);
    const fx = try std.json.parseFromSlice(Fixture, gpa, fx_bytes, .{ .ignore_unknown_fields = true });
    defer fx.deinit();

    var total_events: usize = 0;
    var total_fills: usize = 0;
    var ev_worst: Worst = .{};
    var fin_worst: Worst = .{};
    for (fx.value.scenarios) |sc| {
        var cfg = lib.config.default;
        cfg.halt_drawdown_from_start = sc.halt;
        cfg.siphon_mode = std.meta.stringToEnum(lib.config.SiphonMode, sc.siphon_mode).?;
        const params = if (std.mem.eql(u8, sc.ledger, "S1")) lib.config.s1 else lib.config.s5;

        var rf: lib.iface.ReplayFeed = .{ .bars = &bars };
        var ls = engine.ListSink.init(gpa);
        defer ls.deinit();
        var ledger: ?lib.Ledger = null;
        _ = try lib.desk.run(&cfg, rf.feed(), sc.ledger, params, &ledger, .{ .start_ms = sc.start_ms, .end_ms = sc.end_ms, .tick_hours = sc.tick_hours }, ls.sink());

        // event-by-event: trade rows (Python trades.csv) in order
        var n: usize = 0;
        var halts: std.ArrayList(i64) = .empty;
        defer halts.deinit(gpa);
        var sc_worst: Worst = .{};
        for (ls.list.items) |ev| {
            if (ev.action == .halt) try halts.append(gpa, ev.t_ms);
            if (!ev.action.isTrade()) continue;
            if (n >= sc.events.len) {
                std.debug.print("{s}: zig has extra event #{d} {s} t={d}\n", .{ sc.name, n, ev.action.pyName(), ev.t_ms });
                return error.EventCountMismatch;
            }
            const pe = sc.events[n];
            const same_kind = pe.t == ev.t_ms and std.mem.eql(u8, pe.action, ev.action.pyName()) and std.mem.eql(u8, pe.asset, @tagName(ev.asset));
            const bad = !same_kind or
                sc_worst.upd(ev.qty, pe.qty) > EVENT_RTOL or
                sc_worst.upd(ev.price, pe.price) > EVENT_RTOL or
                sc_worst.upd(ev.usd, pe.usd) > EVENT_RTOL;
            if (bad) {
                std.debug.print("{s}: event #{d} mismatch\n  zig t={d} {s} {s} qty={d} px={d} usd={d}\n  py  t={d} {s} {s} qty={d} px={d} usd={d}\n", .{ sc.name, n, ev.t_ms, ev.action.pyName(), @tagName(ev.asset), ev.qty, ev.price, ev.usd, pe.t, pe.action, pe.asset, pe.qty, pe.price, pe.usd });
                return error.EventMismatch;
            }
            if (ev.action == .buy or ev.action == .sell) total_fills += 1;
            n += 1;
        }
        if (n != sc.events.len) {
            std.debug.print("{s}: zig {d} events, python {d}\n", .{ sc.name, n, sc.events.len });
            return error.EventCountMismatch;
        }
        try t.expectEqualSlices(i64, sc.halts, halts.items);
        total_events += n;
        ev_worst.v = @max(ev_worst.v, sc_worst.v);

        // final ledger vs the Python state file (also exercises the state.zig loader)
        const py_final = try lib.state.fromValue(sc.final);
        var fw: Worst = .{};
        try checkFinal(sc.name, &(ledger.?), &py_final, &fw);
        fin_worst.v = @max(fin_worst.v, fw.v);

        // last equity point (tick.py equity.csv row): USD total and DGB score at the last bar close
        const z = &(ledger.?);
        var li: usize = 0;
        while (bars.hourly[li].t != z.last_bar.?) li += 1;
        const pxc: lib.Prices = .{ .dgb = bars.hourly[li].c, .maj = bars.spot_close[li] };
        try t.expectEqual(sc.equity_last.t, z.last_bar.? + engine.hour_ms);
        if (fw.upd(lib.score.usdTotal(&cfg, z, pxc), sc.equity_last.usd) > FINAL_RTOL) return error.EquityMismatch;
        if (fw.upd(lib.score.dgbScore(&cfg, z, pxc), sc.equity_last.dgb_eq) > FINAL_RTOL) return error.EquityMismatch;

        // state round trip of the Zig ledger: save -> load -> identical
        const js = try lib.state.saveAlloc(gpa, z);
        defer gpa.free(js);
        const back = try lib.state.loadSlice(gpa, js);
        try t.expect(std.meta.eql(back.h, z.h));
        try t.expect(std.meta.eql(back.vault, z.vault));
        try t.expect(std.meta.eql(back.ctx, z.ctx));

        std.debug.print("parity {s:<26} events {d:>4} (py {d:>4})  halts {d}  max rel diff: events {e:.2}, final {e:.2}\n", .{ sc.name, n, sc.events.len, halts.items.len, sc_worst.v, fw.v });
    }
    std.debug.print("parity OK: {d} scenarios, {d} trade events ({d} fills), worst rel diff events {e:.2}, final {e:.2}\n", .{ fx.value.scenarios.len, total_events, total_fills, ev_worst.v, fin_worst.v });
}
