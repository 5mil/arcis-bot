//! arcis-dgb CLI: replay a bar file through the paper engine and print events + final score.
//!   arcis-dgb replay <bars.json> [--ledger S1|S5] [--start <ms|YYYY-MM-DD>] [--end <ms|YYYY-MM-DD>]
//!             [--tick-hours 2] [--mode cheapest|usdt_sol] [--halt 0.30] [--state-in f] [--state-out f] [--quiet]
//!   arcis-dgb show-state <S1.json>      (load a Python state file and print its score at its start prices)
//! PAPER ONLY: reads files, prints text. No network, no orders.
const std = @import("std");
const Io = std.Io;
const lib = @import("arcis_dgb");
const engine = lib.engine;

fn usage(w: *Io.Writer) !void {
    try w.writeAll(
        \\usage:
        \\  arcis-dgb replay <bars.json> [--ledger S1|S5] [--start <ms|YYYY-MM-DD>] [--end <ms|YYYY-MM-DD>]
        \\                   [--tick-hours N] [--mode cheapest|usdt_sol] [--halt F] [--state-in F] [--state-out F] [--quiet]
        \\  arcis-dgb show-state <ledger.json>
        \\
    );
}

fn parseTime(s: []const u8) !i64 {
    if (s.len == 10 and s[4] == '-' and s[7] == '-') {
        const y = try std.fmt.parseInt(i64, s[0..4], 10);
        const m = try std.fmt.parseInt(i64, s[5..7], 10);
        const d = try std.fmt.parseInt(i64, s[8..10], 10);
        // days from civil (Howard Hinnant)
        const yy = if (m <= 2) y - 1 else y;
        const era = @divFloor(yy, 400);
        const yoe = yy - era * 400;
        const mp = @mod(m + 9, 12);
        const doy = @divFloor(153 * mp + 2, 5) + d - 1;
        const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
        const days = era * 146097 + doe - 719468;
        return days * engine.day_ms;
    }
    return std.fmt.parseInt(i64, s, 10);
}

const Printer = struct {
    w: *Io.Writer,
    quiet: bool,
    n: u64 = 0,
    fn sink(self: *Printer) engine.Sink {
        return .{ .ctx = self, .emitFn = emit };
    }
    fn emit(ctx: ?*anyopaque, ev: engine.Event) engine.SinkError!void {
        const self: *Printer = @ptrCast(@alignCast(ctx.?));
        self.n += 1;
        if (self.quiet and ev.action != .halt and ev.action != .park and ev.action != .unpark) return;
        printEvent(self.w, ev) catch return error.SinkFailed;
    }
};

pub fn printEvent(w: *Io.Writer, ev: engine.Event) !void {
    var tb: [40]u8 = undefined;
    const ts = engine.isoUtc(&tb, ev.t_ms);
    try w.print("{s} {s} ", .{ ts[0..16], ev.ledger });
    switch (ev.action) {
        .buy, .sell => try w.print("paper {s} {d:.2} {s} @ ${d:.7} (${d:.2}, {s}", .{ ev.action.pyName(), ev.qty, @tagName(ev.asset), ev.price, ev.usd, @tagName(ev.reason) }),
        .siphon => try w.print("siphon ${d:.2} -> {d:.8} {s}", .{ ev.usd, ev.qty, @tagName(ev.asset) }),
        .vault_convert => try w.print("vault USDT ${d:.2} -> {d:.6} SOL", .{ ev.usd, ev.qty }),
        .sol_withdraw => try w.print("paper SOL withdrawal {d:.4} SOL to wallet line (${d:.2})", .{ ev.qty, ev.usd }),
        .park => try w.print("PARK: DGB {d:.1}% vs 90d basket avg; holding {d:.6} BTC", .{ ev.aux * 100, ev.qty }),
        .unpark => try w.print("UNPARK: back to 50/50 grid at ${d:.6}", .{ev.price}),
        .halt => try w.print("ALERT HALTED: value ${d:.0} ({d:.0}% from start); frozen, no auto-sell", .{ ev.usd, ev.aux * 100 }),
    }
    switch (ev.action) {
        .buy, .sell => {
            if (ev.reason == .round_trip) try w.print(", gain {d:.2}", .{ev.gain});
            if (ev.reason == .grid_level or ev.reason == .round_trip or ev.reason == .sell_starting_dgb)
                try w.print(", step {d:.2}%, {d}/{d} open", .{ ev.step * 100, ev.open_lots, ev.levels });
            try w.writeAll(")\n");
        },
        else => try w.writeAll("\n"),
    }
}

/// Signed percent, e.g. "+12.3%" / "-4.0%".
const Pct = struct {
    x: f64,
    pub fn format(self: Pct, w: *Io.Writer) Io.Writer.Error!void {
        const v = self.x * 100;
        try w.print("{s}{d:.1}%", .{ if (v >= 0) "+" else "-", @abs(v) });
    }
};
fn pct(x: f64) Pct {
    return .{ .x = x };
}

fn printReport(w: *Io.Writer, cfg: *const lib.Config, s: *const lib.Ledger, px: lib.Prices) !void {
    const r = lib.score.report(cfg, s, px);
    const mode = if (s.halted) "HALTED" else if (s.mode == .BTC) "parked in BTC" else "grid active";
    try w.print("\n== {s} ({s}, {s}) ==\n", .{ s.name.slice(), @tagName(s.params.strategy), mode });
    try w.print("DGB score {d:.0} vs start {d:.0} ({f}); USD total ${d:.2} ({f}); max drawdown {f}\n", .{ r.dgb_score, r.start_dgb, pct(r.vs_start), r.usd_total, pct(r.usd_vs_start), pct(r.max_dd) });
    try w.print("Book: {d:.2} DGB + ${d:.2} + {d:.8} BTC; vault ${d:.2} (BTC {d:.8}, LTC {d:.6}, SOL {d:.6}, USDT pending {d:.2}, SOL wallet line {d:.4}); siphoned ${d:.2}; fills {d}\n", .{ s.h.dgb, s.h.usd, s.h.maj[0], r.vault_usd, s.vault.maj[0], s.vault.maj[1], s.vault.maj[2], s.vault.usdt_pending, s.vault.sol_wallet, s.siphoned_usd, s.fills });
    try w.print("Benchmarks (DGB count vs start): hold DGB {f}, 50/50 {f}, park in BTC {f}  |  ledger {f}\n", .{ pct(r.bench.hold_dgb - 1), pct(r.bench.fifty_fifty - 1), pct(r.bench.park_btc - 1), pct(r.vs_start) });
    try w.print("DGB ${d:.6} (start ${d:.6}), BTC ${d:.0} (start ${d:.0})\n", .{ px.dgb, s.start_px.dgb, px.btc(), s.start_px.btc() });
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [8192]u8 = undefined;
    var fw: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const w = &fw.interface;
    defer w.flush() catch {};

    if (args.len < 3) return usage(w);
    const cmd = args[1];
    var cfg: lib.Config = lib.config.default;

    if (std.mem.eql(u8, cmd, "show-state")) {
        const led = try lib.state.loadFile(arena, io, Io.Dir.cwd(), args[2]);
        try printReport(w, &cfg, &led, led.start_px);
        return;
    }
    if (!std.mem.eql(u8, cmd, "replay")) return usage(w);

    var name: []const u8 = "S1";
    var start: ?i64 = null;
    var end: ?i64 = null;
    var tick_h: i64 = 2;
    var quiet = false;
    var state_in: ?[]const u8 = null;
    var state_out: ?[]const u8 = null;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const v = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, a, "--quiet")) {
            quiet = true;
            continue;
        }
        i += 1;
        if (std.mem.eql(u8, a, "--ledger")) name = v else if (std.mem.eql(u8, a, "--start")) start = try parseTime(v) else if (std.mem.eql(u8, a, "--end")) end = try parseTime(v) else if (std.mem.eql(u8, a, "--tick-hours")) tick_h = try std.fmt.parseInt(i64, v, 10) else if (std.mem.eql(u8, a, "--halt")) cfg.halt_drawdown_from_start = try std.fmt.parseFloat(f64, v) else if (std.mem.eql(u8, a, "--mode")) cfg.siphon_mode = std.meta.stringToEnum(lib.config.SiphonMode, v) orelse return error.BadMode else if (std.mem.eql(u8, a, "--state-in")) state_in = v else if (std.mem.eql(u8, a, "--state-out")) state_out = v else return usage(w);
    }
    var params: lib.Params = undefined;
    var found = false;
    for (lib.config.ledgers) |d| if (std.mem.eql(u8, d.name, name)) {
        params = d.params;
        found = true;
    };
    if (!found) return error.UnknownLedger;

    var bars = try lib.data.loadFile(arena, io, args[2]);
    if (bars.hourly.len == 0) return error.NoBars;
    var ledger: ?lib.Ledger = null;
    if (state_in) |p| ledger = try lib.state.loadFile(arena, io, Io.Dir.cwd(), p);

    const last_close = bars.hourly[bars.hourly.len - 1].t + engine.hour_ms;
    const s0 = start orelse if (ledger) |l| (l.last_bar.? + 2 * engine.hour_ms) else bars.hourly[0].t + 120 * engine.day_ms;
    var e0 = end orelse last_close;
    e0 = @min(e0, last_close);

    var rf: lib.iface.ReplayFeed = .{ .bars = &bars };
    var printer: Printer = .{ .w = w, .quiet = quiet };
    var paper: lib.iface.PaperExecutor = .{ .downstream = printer.sink() };
    const ex = paper.executor();
    const stats = try lib.desk.run(&cfg, rf.feed(), name, params, &ledger, .{ .start_ms = s0, .end_ms = e0, .tick_hours = tick_h }, ex.sink());

    const led = &(ledger orelse return error.NoLedger);
    const snap = try rf.feed().fetch(e0);
    const px: lib.Prices = .{ .dgb = snap.hourly[snap.hourly.len - 1].c, .maj = snap.spot };
    try w.print("\nticks {d}, bars {d}, events {d} (fills {d}, siphons {d}, alerts {d}), mode {s}\n", .{ stats.ticks, stats.bars, printer.n, paper.fills, paper.siphons, paper.alerts, @tagName(cfg.siphon_mode) });
    try printReport(w, &cfg, led, px);
    if (state_out) |p| try lib.state.saveFile(arena, io, Io.Dir.cwd(), p, led);
}
