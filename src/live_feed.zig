//! Keyless public Feed for the DGB paper desk.
//! Crypto.com klines preferred, Binance fallback.
//! Closed bars only. PAPER ONLY — no keys, no orders.
//!
//! TODO: wire the actual HTTP fetch (the skeleton below shows the contract).
const std = @import("std");
const dgb = @import("arcis_dgb");

pub const LiveFeed = struct {
    gpa: std.mem.Allocator,
    // caller-owned buffers that outlive the Snapshot
    hourly: []dgb.Bar = &.{},
    daily_dgb: []dgb.engine.DailyClose = &.{},
    daily_maj: [3][]dgb.engine.DailyClose = .{ &.{}, &.{}, &.{} },
    spot: [3]f64 = .{ 0, 0, 0 },
    source: []const u8 = "none",

    pub fn feed(self: *LiveFeed) dgb.Feed {
        return .{ .ptr = self, .vtable = &.{ .fetch = fetchImpl } };
    }

    fn fetchImpl(ptr: *anyopaque, now_ms: i64) dgb.iface.FeedError!dgb.iface.Snapshot {
        const self: *LiveFeed = @ptrCast(@alignCast(ptr));
        // TODO: fetch closed 1h klines for DGBUSDT + BTCUSDT/LTCUSDT/SOLUSDT
        // from Crypto.com, fall back to Binance.
        // Filter to t + 1h <= now_ms, keep last 99 hourly,
        // derive completed daily closes, set spot = last closed close.
        // On failure return error.FeedDown or error.NoData.
        _ = now_ms;
        if (self.hourly.len == 0) return error.NoData;
        return .{
            .source = self.source,
            .hourly = self.hourly,
            .daily = .{ .dgb = self.daily_dgb, .maj = self.daily_maj },
            .spot = self.spot,
        };
    }
};
