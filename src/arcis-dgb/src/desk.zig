//! Tick scheduler: the Zig equivalent of the routine that runs tick.py every N hours.
const std = @import("std");
const engine = @import("engine.zig");
const iface = @import("iface.zig");

pub const RunOptions = struct {
    start_ms: i64,
    end_ms: i64,
    tick_hours: i64 = 2,
};

pub const RunStats = struct { ticks: u64 = 0, feed_failures: u64 = 0, bars: u64 = 0 };

/// One routine run at `now_ms`: create the ledger on first sight (tick.py init branch),
/// otherwise replay newly closed bars. Feed failure leaves the ledger untouched.
pub fn tickOnce(cfg: *const engine.Config, feed: iface.Feed, name: []const u8, params: engine.Params, ledger: *?engine.Ledger, now_ms: i64, sink: engine.Sink, stats: *RunStats) engine.SinkError!void {
    stats.ticks += 1;
    const snap = feed.fetch(now_ms) catch {
        stats.feed_failures += 1;
        return;
    };
    if (snap.hourly.len == 0) {
        stats.feed_failures += 1;
        return;
    }
    if (ledger.*) |*s| {
        stats.bars += try engine.tick(cfg, s, snap.hourly, snap.spot, snap.daily, snap.source, sink);
    } else {
        ledger.* = try engine.initLedger(cfg, name, params, snap.hourly[snap.hourly.len - 1], snap.spot, snap.daily, snap.source, sink);
    }
}

/// Run ticks every `tick_hours` from start to end inclusive.
pub fn run(cfg: *const engine.Config, feed: iface.Feed, name: []const u8, params: engine.Params, ledger: *?engine.Ledger, opts: RunOptions, sink: engine.Sink) engine.SinkError!RunStats {
    var stats: RunStats = .{};
    var now = opts.start_ms;
    while (now <= opts.end_ms) : (now += opts.tick_hours * engine.hour_ms) {
        try tickOnce(cfg, feed, name, params, ledger, now, sink, &stats);
    }
    return stats;
}
