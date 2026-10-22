//! Plug-in points for the future live arcis bot. PAPER ONLY in this module:
//!   * `Feed`     - where market data comes from. Only `ReplayFeed` (historical) is implemented.
//!                  A live public-data feed (Crypto.com / Binance klines, no keys) plugs in here.
//!   * `Executor` - where engine decisions go. Only `PaperExecutor` is implemented: it records
//!                  events; the engine's own cost model *is* the fill. A live executor would turn
//!                  intents into orders and reconcile real fills back into the ledger - that is
//!                  deliberately NOT implemented (no exchange clients, keys, orders or wallets).
const std = @import("std");
const engine = @import("engine.zig");
const data = @import("data.zig");

pub const Snapshot = struct {
    source: []const u8,
    /// closed hourly DGB/USD bars, oldest first
    hourly: []const engine.Bar,
    /// completed daily closes (DGB + BTC/LTC/SOL)
    daily: engine.Daily,
    /// latest BTC/LTC/SOL USD prices
    spot: [3]f64,
};

pub const FeedError = error{ NoData, FeedDown };

pub const Feed = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        /// Return the market view as of `now_ms` (only data closed by then).
        fetch: *const fn (ptr: *anyopaque, now_ms: i64) FeedError!Snapshot,
    };
    pub fn fetch(f: Feed, now_ms: i64) FeedError!Snapshot {
        return f.vtable.fetch(f.ptr, now_ms);
    }
};

/// Historical replay with the same visibility rules as feed.py: bars closed by `now`
/// (t + 1h <= now), last 99 hourly bars, completed days only, spot = last closed hourly close.
pub const ReplayFeed = struct {
    bars: *const data.BarSet,
    window: usize = 99,

    pub fn feed(self: *ReplayFeed) Feed {
        return .{ .ptr = self, .vtable = &.{ .fetch = fetchImpl } };
    }

    fn closedCount(comptime T: type, xs: []const T, now: i64, span: i64) usize {
        var lo: usize = 0;
        var hi: usize = xs.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (xs[mid].t + span <= now) lo = mid + 1 else hi = mid;
        }
        return lo;
    }

    fn fetchImpl(ptr: *anyopaque, now: i64) FeedError!Snapshot {
        const self: *ReplayFeed = @ptrCast(@alignCast(ptr));
        const b = self.bars;
        const k = closedCount(engine.Bar, b.hourly, now, engine.hour_ms);
        if (k == 0) return error.NoData;
        const lo = if (k > self.window) k - self.window else 0;
        var d: engine.Daily = undefined;
        d.dgb = b.daily_dgb[0..closedCount(engine.DailyClose, b.daily_dgb, now, engine.day_ms)];
        for (0..3) |i| d.maj[i] = b.daily_maj[i][0..closedCount(engine.DailyClose, b.daily_maj[i], now, engine.day_ms)];
        return .{ .source = "replay", .hourly = b.hourly[lo..k], .daily = d, .spot = b.spot_close[k - 1] };
    }
};

pub const Executor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        /// Receive one engine event (fill intent, siphon, park/unpark, alert).
        submit: *const fn (ptr: *anyopaque, ev: engine.Event) engine.SinkError!void,
    };
    /// Use the executor as the engine's event sink. `self` must outlive the sink.
    pub fn sink(self: *const Executor) engine.Sink {
        return .{ .ctx = @constCast(self), .emitFn = emitImpl };
    }
    fn emitImpl(ctx: ?*anyopaque, ev: engine.Event) engine.SinkError!void {
        const self: *const Executor = @ptrCast(@alignCast(ctx.?));
        return self.vtable.submit(self.ptr, ev);
    }
};

/// Paper executor: counts events and forwards them to an optional downstream sink (e.g. a
/// ListSink or a printer). Places nothing anywhere.
pub const PaperExecutor = struct {
    downstream: engine.Sink = engine.null_sink,
    fills: u64 = 0,
    siphons: u64 = 0,
    alerts: u64 = 0,

    pub fn executor(self: *PaperExecutor) Executor {
        return .{ .ptr = self, .vtable = &.{ .submit = submitImpl } };
    }
    fn submitImpl(ptr: *anyopaque, ev: engine.Event) engine.SinkError!void {
        const self: *PaperExecutor = @ptrCast(@alignCast(ptr));
        switch (ev.action) {
            .buy, .sell => self.fills += 1,
            .siphon => self.siphons += 1,
            .halt => self.alerts += 1,
            else => {},
        }
        return self.downstream.emit(ev);
    }
};
