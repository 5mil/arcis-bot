//! DGB paper engine core: ledger state + strategy rules. PAPER ONLY.
//! 1:1 port of /workspace/dgb/paper/engine.py (+ the per-bar loop of tick.py).
//!
//! Design: pure functions over a `Ledger` value. No I/O, no printing, no heap allocation in the
//! core (open lots live in a fixed array). Everything observable (fills, siphons, vault moves,
//! park/unpark, halt alerts) is emitted as an `Event` through a caller-supplied `Sink`.
const std = @import("std");
const cfgmod = @import("config.zig");
const score = @import("score.zig");

pub const Config = cfgmod.Config;
pub const Params = cfgmod.Params;
pub const max_levels = cfgmod.max_levels;

pub const hour_ms: i64 = 3_600_000;
pub const day_ms: i64 = 86_400_000;

// ---------------------------------------------------------------- market data

/// One hourly OHLC bar; `t` = open time, ms since epoch (UTC).
pub const Bar = struct { t: i64, o: f64, h: f64, l: f64, c: f64 };
/// One completed daily close; `t` = UTC day start, ms.
pub const DailyClose = struct { t: i64, c: f64 };

/// Daily closes for DGB and the BTC/LTC/SOL basket, each sorted ascending by `t`.
/// Only entries with `t < day` are ever read for a decision on `day` (no look-ahead).
pub const Daily = struct {
    dgb: []const DailyClose,
    maj: [3][]const DailyClose, // BTC, LTC, SOL
};

/// Prices used for a decision. `maj` = BTC, LTC, SOL (USD).
pub const Prices = struct {
    dgb: f64,
    maj: [3]f64,
    pub fn btc(p: Prices) f64 {
        return p.maj[0];
    }
    pub fn sol(p: Prices) f64 {
        return p.maj[2];
    }
};

// ---------------------------------------------------------------- ledger state

pub fn FixedStr(comptime N: usize) type {
    return struct {
        buf: [N]u8 = undefined,
        len: usize = 0,
        const Self = @This();
        pub fn init(s: []const u8) Self {
            var r: Self = .{};
            r.set(s);
            return r;
        }
        pub fn set(self: *Self, s: []const u8) void {
            const n = @min(s.len, N);
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = n;
        }
        pub fn slice(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

pub const Mode = enum { DGB, BTC };

/// One open grid buy: DGB quantity and the USD it cost (fees included).
pub const Lot = struct { q: f64, cost: f64 };

pub const Holdings = struct {
    dgb: f64,
    usd: f64,
    maj: [3]f64 = .{ 0, 0, 0 }, // BTC, LTC, SOL held in the trading book (S5 park uses BTC)
};

/// Siphon vault: never traded back into the book.
pub const Vault = struct {
    maj: [3]f64 = .{ 0, 0, 0 }, // BTC, LTC, SOL on the exchange
    usdt_pending: f64 = 0,
    usdt_since: ?i64 = null,
    sol_wallet: f64 = 0, // paper "external SOL wallet" line
    sol_withdrawals: u64 = 0,
    sol_fees: f64 = 0,
};

pub const Grid = struct {
    ref: f64,
    step: ?f64,
    slice: f64,
    inv: [max_levels]Lot = undefined, // LIFO stack of open lots
    inv_len: usize = 0,
    active: bool = true,
    last_recenter: i64,

    pub fn lots(g: *const Grid) []const Lot {
        return g.inv[0..g.inv_len];
    }
    pub fn push(g: *Grid, lot: Lot) void {
        std.debug.assert(g.inv_len < max_levels);
        g.inv[g.inv_len] = lot;
        g.inv_len += 1;
    }
    pub fn pop(g: *Grid) ?Lot {
        if (g.inv_len == 0) return null;
        g.inv_len -= 1;
        return g.inv[g.inv_len];
    }
    pub fn clear(g: *Grid) void {
        g.inv_len = 0;
    }
};

/// Daily context computed from COMPLETED days strictly before the current day.
pub const Ctx = struct {
    step: ?f64 = null,
    rel: ?[3]f64 = null, // price / 30-day average for BTC, LTC, SOL
    r: ?f64 = null, // ln DGB - mean(ln BTC, ln LTC, ln SOL)
    rma: ?f64 = null, // MA(n) of r
    pub fn relOf(c: Ctx, i: usize) f64 {
        return if (c.rel) |r| r[i] else 1.0;
    }
};

pub const Ledger = struct {
    name: FixedStr(16),
    params: Params,
    paper: bool = true,
    created_utc: FixedStr(40),
    start_px: Prices,
    start_usd: f64,
    start_dgb: f64,
    h: Holdings,
    vault: Vault = .{},
    grid: Grid,
    mode: Mode = .DGB,
    left_dgb: ?f64 = null,
    last_bar: ?i64 = null,
    last_day: ?i64 = null,
    ctx: Ctx = .{},
    halted: bool = false,
    peak_usd: f64,
    max_dd: f64 = 0,
    feed_fail: bool = false,
    siphoned_usd: f64 = 0,
    fills: u64 = 0,
    source: FixedStr(32) = .{},
};

// ---------------------------------------------------------------- events

pub const Action = enum {
    buy,
    sell,
    siphon,
    vault_convert,
    sol_withdraw,
    park,
    unpark,
    halt,

    /// True for actions that correspond to a row in Python's <ledger>.trades.csv.
    pub fn isTrade(a: Action) bool {
        return switch (a) {
            .buy, .sell, .siphon, .vault_convert, .sol_withdraw => true,
            else => false,
        };
    }
    /// The Python trades.csv `action` string.
    pub fn pyName(a: Action) []const u8 {
        return switch (a) {
            .buy => "BUY",
            .sell => "SELL",
            .siphon => "SIPHON",
            .vault_convert => "VAULT_CONVERT",
            .sol_withdraw => "SOL_WITHDRAW_PAPER",
            .park => "PARK",
            .unpark => "UNPARK",
            .halt => "HALT",
        };
    }
};

pub const Asset = enum { DGB, BTC, LTC, SOL, USDT, USD };

pub const Reason = enum {
    grid_level, // grid buy at ref/(1+step)
    round_trip, // grid sell closing the most recent open lot (LIFO)
    sell_starting_dgb, // grid sell with no open lot (sells starting inventory)
    park_sell_dgb,
    park_buy_btc,
    unpark_sell_btc,
    unpark_buy_dgb,
    siphon_cheapest,
    siphon_usdt,
    usdt_to_sol,
    paper_sol_withdraw,
    regime_park,
    regime_unpark,
    drawdown_halt,
};

/// Everything the engine reports. `qty/price/usd` follow the Python trades.csv columns.
/// park: qty = BTC bought, aux = R - Rma.  unpark: price = DGB price.  halt: usd = book value,
/// aux = value/start - 1.  siphon(cheapest): aux = rel of the chosen coin.
pub const Event = struct {
    ledger: []const u8,
    t_ms: i64,
    action: Action,
    asset: Asset,
    qty: f64 = 0,
    price: f64 = 0,
    usd: f64 = 0,
    reason: Reason,
    gain: f64 = 0, // realized USD gain (grid round trip)
    step: f64 = 0, // grid step at the time of a grid fill
    open_lots: u32 = 0, // open grid lots after the fill
    levels: u32 = 0,
    aux: f64 = 0,
};

pub const SinkError = error{ OutOfMemory, SinkFailed };

/// Caller-supplied event sink (type-erased). See `ListSink` and `null_sink`.
pub const Sink = struct {
    ctx: ?*anyopaque,
    emitFn: *const fn (ctx: ?*anyopaque, ev: Event) SinkError!void,
    pub fn emit(s: Sink, ev: Event) SinkError!void {
        return s.emitFn(s.ctx, ev);
    }
};

fn nullEmit(_: ?*anyopaque, _: Event) SinkError!void {}
pub const null_sink: Sink = .{ .ctx = null, .emitFn = nullEmit };

/// Collects events into an ArrayList.
pub const ListSink = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(Event) = .empty,
    pub fn init(gpa: std.mem.Allocator) ListSink {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *ListSink) void {
        self.list.deinit(self.gpa);
    }
    pub fn sink(self: *ListSink) Sink {
        return .{ .ctx = self, .emitFn = emitImpl };
    }
    fn emitImpl(ctx: ?*anyopaque, ev: Event) SinkError!void {
        const self: *ListSink = @ptrCast(@alignCast(ctx.?));
        try self.list.append(self.gpa, ev);
    }
};

// ---------------------------------------------------------------- numerics

/// CPython >= 3.12 `sum()` over floats (Neumaier compensated summation), reproduced so that
/// averages match the Python engine bit-for-bit where libm agrees.
pub const PySum = struct {
    f: f64 = 0.0,
    c: f64 = 0.0,
    pub fn add(s: *PySum, x: f64) void {
        const t = s.f + x;
        if (@abs(s.f) >= @abs(x)) s.c += (s.f - t) + x else s.c += (x - t) + s.f;
        s.f = t;
    }
    pub fn result(s: PySum) f64 {
        if (s.c != 0 and std.math.isFinite(s.c)) return s.f + s.c;
        return s.f;
    }
};

pub fn pysum(xs: []const f64) f64 {
    var s: PySum = .{};
    for (xs) |x| s.add(x);
    return s.result();
}

/// Python `t - t % 86400000` (floor to UTC day).
pub fn dayStart(t: i64) i64 {
    return t - @mod(t, day_ms);
}

/// Number of leading entries with t < day (input sorted ascending).
fn countBefore(xs: []const DailyClose, day: i64) usize {
    var lo: usize = 0;
    var hi: usize = xs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (xs[mid].t < day) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// Volatility step: clamp(k * stdev(ln returns over the last vol_days, ddof=1), smin, smax).
/// Returns null when there are not more than vol_days closes.
pub fn volStep(p: Params, closes: []const DailyClose) ?f64 {
    const n: usize = p.vol_days;
    if (n < 2 or n > cfgmod.max_window or closes.len <= n) return null;
    var r: [cfgmod.max_window]f64 = undefined;
    const len = closes.len;
    for (0..n) |j| {
        const i = len - n + j;
        r[j] = @log(closes[i].c / closes[i - 1].c);
    }
    const nf: f64 = @floatFromInt(n);
    const m = pysum(r[0..n]) / nf;
    var sq: PySum = .{};
    for (r[0..n]) |x| sq.add((x - m) * (x - m));
    const sd = @sqrt(sq.result() / (nf - 1.0));
    return clampStep(p, p.k * sd);
}

pub fn clampStep(p: Params, raw: f64) f64 {
    return @min(@max(raw, p.smin), p.smax);
}

/// Python engine.daily_ctx.
pub fn dailyCtx(cfg: *const Config, daily: Daily, day: i64, p: Params) Ctx {
    var ctx: Ctx = .{};
    const nd = countBefore(daily.dgb, day);
    const d = daily.dgb[0..nd];
    var nmaj: [3]usize = undefined;
    for (0..3) |i| nmaj[i] = countBefore(daily.maj[i], day);

    ctx.step = volStep(p, d);

    var rel: [3]f64 = .{ 1.0, 1.0, 1.0 };
    const td: usize = cfg.siphon_trend_days;
    for (0..3) |i| {
        const cl = daily.maj[i][0..nmaj[i]];
        if (td > 0 and cl.len >= td) {
            var s: PySum = .{};
            for (cl[cl.len - td ..]) |x| s.add(x.c);
            rel[i] = cl[cl.len - 1].c / (s.result() / @as(f64, @floatFromInt(td)));
        }
    }
    ctx.rel = rel;

    if (p.strategy == .regime) {
        var L: usize = nd;
        for (nmaj) |x| L = @min(L, x);
        const nn: usize = p.n;
        if (nn > 0 and nn <= cfgmod.max_window and L >= nn) {
            var R: [cfgmod.max_window]f64 = undefined;
            for (0..nn) |j| {
                const i = L - nn + j;
                var bask: PySum = .{};
                for (0..3) |c| bask.add(@log(daily.maj[c][nmaj[c] - L + i].c));
                R[j] = @log(daily.dgb[nd - L + i].c) - bask.result() / 3.0;
            }
            ctx.r = R[nn - 1];
            ctx.rma = pysum(R[0..nn]) / @as(f64, @floatFromInt(nn));
        }
    }
    return ctx;
}

// ---------------------------------------------------------------- ledger creation

/// Python engine.new_ledger: $start_usd worth of DGB at px.dgb, split start_dgb_fraction DGB / rest USD.
pub fn newLedger(cfg: *const Config, name: []const u8, p: Params, px: Prices, t_ms: i64) Ledger {
    const p0 = px.dgb;
    var created: FixedStr(40) = .{};
    var buf: [40]u8 = undefined;
    created.set(isoUtc(&buf, t_ms));
    return .{
        .name = FixedStr(16).init(name),
        .params = p,
        .created_utc = created,
        .start_px = px,
        .start_usd = cfg.start_usd,
        .start_dgb = cfg.start_usd / p0,
        .h = .{ .dgb = cfg.start_usd * cfg.start_dgb_fraction / p0, .usd = cfg.start_usd * (1 - cfg.start_dgb_fraction) },
        .grid = .{ .ref = p0, .step = null, .slice = cfg.start_usd / @as(f64, @floatFromInt(2 * p.levels)), .last_recenter = t_ms },
        .peak_usd = cfg.start_usd,
    };
}

/// ISO-8601 UTC timestamp like Python's datetime.isoformat(): "2026-10-22T10:00:00+00:00".
pub fn isoUtc(buf: []u8, t_ms: i64) []const u8 {
    const secs: u64 = @intCast(@divFloor(t_ms, 1000));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}+00:00", .{
        yd.year, md.month.numeric(), @as(u32, md.day_index) + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch buf[0..0];
}

/// True on Jan 1 / Apr 1 / Jul 1 / Oct 1 (UTC).
pub fn isQuarterStart(t_ms: i64) bool {
    const secs: u64 = @intCast(@divFloor(t_ms, 1000));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const md = es.getEpochDay().calculateYearDay().calculateMonthDay();
    const m = md.month.numeric();
    return md.day_index == 0 and (m == 1 or m == 4 or m == 7 or m == 10);
}

// ---------------------------------------------------------------- siphon

/// Index (0=BTC,1=LTC,2=SOL) of the siphon target in "cheapest" mode: lowest price/30d-avg,
/// first one wins ties (Python min()).
pub fn cheapestCoin(ctx: Ctx) usize {
    var best: usize = 0;
    for (1..3) |i| {
        if (ctx.relOf(i) < ctx.relOf(best)) best = i;
    }
    return best;
}

/// Python engine.siphon: move siphon_share of a realized gain out of the book into the vault.
pub fn siphon(cfg: *const Config, s: *Ledger, gain_usd: f64, px: Prices, ts: i64, sink: Sink) SinkError!void {
    const amt = gain_usd * cfg.siphon_share;
    if (amt <= 0 or s.h.usd < amt) return;
    s.h.usd -= amt;
    s.siphoned_usd += amt;
    const v = &s.vault;
    switch (cfg.siphon_mode) {
        .usdt_sol => {
            const q = amt * (1 - cfg.usd_to_usdt_cost);
            v.usdt_pending += q;
            if (v.usdt_since == null or v.usdt_since.? == 0) v.usdt_since = ts;
            try sink.emit(.{ .ledger = s.name.slice(), .t_ms = ts, .action = .siphon, .asset = .USDT, .qty = q, .price = 1, .usd = amt, .reason = .siphon_usdt });
        },
        .cheapest => {
            const c = cheapestCoin(s.ctx);
            const q = amt * (1 - cfg.majCost()) / px.maj[c];
            v.maj[c] += q;
            try sink.emit(.{ .ledger = s.name.slice(), .t_ms = ts, .action = .siphon, .asset = majAsset(c), .qty = q, .price = px.maj[c], .usd = amt, .reason = .siphon_cheapest, .aux = s.ctx.relOf(c) });
        },
    }
}

pub fn majAsset(i: usize) Asset {
    return switch (i) {
        0 => .BTC,
        1 => .LTC,
        else => .SOL,
    };
}

/// Python engine.vault_daily: USDT->SOL conversion (usdt_sol mode) and paper SOL withdrawals.
pub fn vaultDaily(cfg: *const Config, s: *Ledger, px: Prices, day: i64, sink: Sink) SinkError!void {
    const v = &s.vault;
    if (cfg.siphon_mode == .usdt_sol and v.usdt_pending > 0) {
        const since = if (v.usdt_since) |x| (if (x != 0) x else day) else day;
        const waited = @as(f64, @floatFromInt(day - since)) / 86400000.0;
        if (s.ctx.relOf(2) < 1.0 or waited >= cfg.usdt_sol_max_wait_days) {
            const q = v.usdt_pending * (1 - cfg.majCost()) / px.sol();
            v.maj[2] += q;
            try sink.emit(.{ .ledger = s.name.slice(), .t_ms = day, .action = .vault_convert, .asset = .SOL, .qty = q, .price = px.sol(), .usd = v.usdt_pending, .reason = .usdt_to_sol });
            v.usdt_pending = 0;
            v.usdt_since = null;
        }
    }
    const fee = cfg.sol_withdraw_fee_sol;
    if (v.maj[2] > fee * 2 and (v.maj[2] >= cfg.sol_withdraw_min or isQuarterStart(day))) {
        const q = v.maj[2] - fee;
        v.sol_wallet += q;
        v.sol_fees += fee;
        v.sol_withdrawals += 1;
        v.maj[2] = 0;
        try sink.emit(.{ .ledger = s.name.slice(), .t_ms = day, .action = .sol_withdraw, .asset = .SOL, .qty = q, .price = px.sol(), .usd = q * px.sol(), .reason = .paper_sol_withdraw });
    }
}

// ---------------------------------------------------------------- strategy steps

/// Python engine.on_new_day: refresh daily context + step, vault housekeeping, S5 park/unpark.
pub fn onNewDay(cfg: *const Config, s: *Ledger, daily: Daily, day: i64, px: Prices, sink: Sink) SinkError!void {
    const p = s.params;
    s.ctx = dailyCtx(cfg, daily, day, p);
    const ctx = s.ctx;
    const g = &s.grid;
    if (ctx.step) |st| g.step = st;
    try vaultDaily(cfg, s, px, day, sink);
    if (s.halted or p.strategy != .regime or ctx.rma == null) return;
    const R = ctx.r.?;
    const Rma = ctx.rma.?;
    const bad = R < Rma - p.band;
    const good = R > Rma + p.band;
    const h = &s.h;
    const name = s.name.slice();
    const maj_cost = cfg.majCost();
    if (bad and s.mode == .DGB) {
        s.left_dgb = h.dgb + h.usd / px.dgb;
        if (h.dgb > 0) {
            const usd = h.dgb * px.dgb;
            const c = cfg.dgbCost(usd);
            try sink.emit(.{ .ledger = name, .t_ms = day, .action = .sell, .asset = .DGB, .qty = h.dgb, .price = px.dgb, .usd = usd * (1 - c), .reason = .park_sell_dgb });
            h.usd += usd * (1 - c);
            h.dgb = 0;
        }
        const q = h.usd * (1 - maj_cost) / px.btc();
        try sink.emit(.{ .ledger = name, .t_ms = day, .action = .buy, .asset = .BTC, .qty = q, .price = px.btc(), .usd = h.usd, .reason = .park_buy_btc });
        h.maj[0] += q;
        h.usd = 0;
        s.mode = .BTC;
        g.active = false;
        g.clear();
        s.fills += 2;
        try sink.emit(.{ .ledger = name, .t_ms = day, .action = .park, .asset = .BTC, .qty = q, .price = px.btc(), .reason = .regime_park, .aux = R - Rma });
    } else if (good and s.mode == .BTC) {
        const usd = h.maj[0] * px.btc() * (1 - maj_cost);
        try sink.emit(.{ .ledger = name, .t_ms = day, .action = .sell, .asset = .BTC, .qty = h.maj[0], .price = px.btc(), .usd = usd, .reason = .unpark_sell_btc });
        h.maj[0] = 0;
        h.usd += usd;
        const exp = h.usd * (1 - cfg.dgbCost(h.usd)) / px.dgb;
        if (s.left_dgb) |left| {
            if (left != 0 and exp > left) try siphon(cfg, s, (exp - left) * px.dgb, px, day, sink);
        }
        const half = h.usd / 2;
        const c = cfg.dgbCost(half);
        const q = half * (1 - c) / px.dgb;
        h.usd -= half;
        h.dgb += q;
        s.mode = .DGB;
        g.active = true;
        g.ref = px.dgb;
        g.slice = score.usdTotal(cfg, s, px) / @as(f64, @floatFromInt(2 * p.levels));
        g.clear();
        s.fills += 2;
        try sink.emit(.{ .ledger = name, .t_ms = day, .action = .buy, .asset = .DGB, .qty = q, .price = px.dgb, .usd = half, .reason = .unpark_buy_dgb });
        try sink.emit(.{ .ledger = name, .t_ms = day, .action = .unpark, .asset = .DGB, .price = px.dgb, .reason = .regime_unpark, .aux = R - Rma });
    }
}

/// Python engine.grid_bar: process one hourly bar against the grid.
/// Intra-bar order: green bar (c >= o) buys then sells; red bar sells then buys.
pub fn gridBar(cfg: *const Config, s: *Ledger, b: Bar, px: Prices, sink: Sink) SinkError!void {
    const g = &s.grid;
    const p = s.params;
    if (s.halted or !g.active or g.step == null) return;
    if ((b.t - g.last_recenter) >= @as(i64, p.recenter_days) * day_ms and g.inv_len == 0) {
        g.ref = b.o;
        g.last_recenter = b.t;
    }
    const step = g.step.?;
    const sl = g.slice;
    if (b.c >= b.o) {
        try gridBuys(cfg, s, b, step, sl, sink);
        try gridSells(cfg, s, b, px, step, sl, sink);
    } else {
        try gridSells(cfg, s, b, px, step, sl, sink);
        try gridBuys(cfg, s, b, step, sl, sink);
    }
}

fn gridBuys(cfg: *const Config, s: *Ledger, b: Bar, step: f64, sl: f64, sink: Sink) SinkError!void {
    const g = &s.grid;
    const h = &s.h;
    const levels: usize = s.params.levels;
    while (b.l < g.ref / (1 + step) and h.usd >= sl and g.inv_len < levels and g.inv_len < max_levels) {
        const lv = g.ref / (1 + step);
        const fill = lv * (1 + cfg.dgb_adverse);
        const q = sl * (1 - cfg.dgb_maker_fee) / fill;
        h.usd -= sl;
        h.dgb += q;
        g.push(.{ .q = q, .cost = sl });
        g.ref = lv;
        s.fills += 1;
        try sink.emit(.{ .ledger = s.name.slice(), .t_ms = b.t, .action = .buy, .asset = .DGB, .qty = q, .price = fill, .usd = sl, .reason = .grid_level, .step = step, .open_lots = @intCast(g.inv_len), .levels = s.params.levels });
    }
}

fn gridSells(cfg: *const Config, s: *Ledger, b: Bar, px: Prices, step: f64, sl: f64, sink: Sink) SinkError!void {
    const g = &s.grid;
    const h = &s.h;
    while (b.h > g.ref * (1 + step) and h.dgb > 1e-9) {
        const lv = g.ref * (1 + step);
        const fill = lv * (1 - cfg.dgb_adverse);
        var q: f64 = undefined;
        var proceeds: f64 = undefined;
        var gain: f64 = 0;
        var reason: Reason = undefined;
        if (g.pop()) |lot| {
            q = @min(lot.q, h.dgb);
            proceeds = q * fill * (1 - cfg.dgb_maker_fee);
            h.dgb -= q;
            h.usd += proceeds;
            gain = proceeds - lot.cost;
            reason = .round_trip;
        } else {
            q = @min(h.dgb, sl / lv);
            proceeds = q * fill * (1 - cfg.dgb_maker_fee);
            h.dgb -= q;
            h.usd += proceeds;
            reason = .sell_starting_dgb;
        }
        g.ref = lv;
        s.fills += 1;
        try sink.emit(.{ .ledger = s.name.slice(), .t_ms = b.t, .action = .sell, .asset = .DGB, .qty = q, .price = fill, .usd = proceeds, .reason = reason, .gain = gain, .step = step, .open_lots = @intCast(g.inv_len), .levels = s.params.levels });
        if (gain > 0) try siphon(cfg, s, gain, px, b.t, sink);
    }
}

// ---------------------------------------------------------------- tick-level driver

pub const EquityPoint = struct { t_ms: i64, usd: f64, dgb_equiv: f64 };

/// One closed hourly bar for one ledger (the body of tick.py's replay loop).
/// `spot` = BTC/LTC/SOL USD prices used for parks and siphons (tick.py uses latest spot).
pub fn stepBar(cfg: *const Config, s: *Ledger, b: Bar, spot: [3]f64, daily: Daily, sink: Sink) SinkError!EquityPoint {
    const day = dayStart(b.t);
    const px: Prices = .{ .dgb = b.o, .maj = spot };
    if (s.last_day == null or s.last_day.? != day) {
        try onNewDay(cfg, s, daily, day, px, sink);
        s.last_day = day;
    }
    try gridBar(cfg, s, b, px, sink);
    var pxc = px;
    pxc.dgb = b.c;
    const u = score.usdTotal(cfg, s, pxc);
    s.peak_usd = @max(s.peak_usd, u);
    s.max_dd = @min(s.max_dd, u / s.peak_usd - 1);
    try checkHalt(cfg, s, u, b.t, sink);
    s.last_bar = b.t;
    return .{ .t_ms = b.t + hour_ms, .usd = u, .dgb_equiv = score.dgbScore(cfg, s, pxc) };
}

/// Halt rule: when book value <= (1 - halt_drawdown_from_start) x start, freeze the ledger and
/// alert. Never sells anything.
pub fn checkHalt(cfg: *const Config, s: *Ledger, usd_value: f64, t: i64, sink: Sink) SinkError!void {
    if (!s.halted and usd_value <= s.start_usd * (1 - cfg.halt_drawdown_from_start)) {
        s.halted = true;
        try sink.emit(.{ .ledger = s.name.slice(), .t_ms = t, .action = .halt, .asset = .USD, .usd = usd_value, .reason = .drawdown_halt, .aux = usd_value / s.start_usd - 1 });
    }
}

/// tick.py first-run branch: create a ledger from the last closed bar of a snapshot.
pub fn initLedger(cfg: *const Config, name: []const u8, p: Params, last: Bar, spot: [3]f64, daily: Daily, source: []const u8, sink: Sink) SinkError!Ledger {
    const px: Prices = .{ .dgb = last.c, .maj = spot };
    var s = newLedger(cfg, name, p, px, last.t + hour_ms);
    s.last_bar = last.t;
    s.source.set(source);
    s.last_day = dayStart(last.t);
    s.ctx = dailyCtx(cfg, daily, s.last_day.?, p);
    s.grid.step = s.ctx.step;
    if (p.strategy == .regime) try onNewDay(cfg, &s, daily, s.last_day.?, px, sink);
    s.grid.ref = last.c;
    return s;
}

/// tick.py replay branch: process closed bars newer than `last_bar`, at most
/// `cfg.max_replay_hours` of them (the most recent ones). Returns the number processed.
pub fn tick(cfg: *const Config, s: *Ledger, bars: []const Bar, spot: [3]f64, daily: Daily, source: []const u8, sink: Sink) SinkError!usize {
    var first: usize = bars.len;
    var i: usize = bars.len;
    while (i > 0) : (i -= 1) {
        if (s.last_bar != null and bars[i - 1].t <= s.last_bar.?) break;
        first = i - 1;
    }
    var new = bars[first..];
    if (new.len > cfg.max_replay_hours) new = new[new.len - cfg.max_replay_hours ..];
    for (new) |b| _ = try stepBar(cfg, s, b, spot, daily, sink);
    s.source.set(source);
    return new.len;
}
