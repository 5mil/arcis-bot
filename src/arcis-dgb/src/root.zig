//! arcis-dgb: DGB paper-trading engine (S1 volatility grid, S5 regime switch) for the arcis bot.
//! PAPER ONLY. See README.md for the public API and integration notes.
const std = @import("std");

pub const config = @import("config.zig");
pub const engine = @import("engine.zig");
pub const score = @import("score.zig");
pub const state = @import("state.zig");
pub const data = @import("data.zig");
pub const iface = @import("iface.zig");
pub const desk = @import("desk.zig");

// Convenience re-exports
pub const Config = config.Config;
pub const Params = config.Params;
pub const Ledger = engine.Ledger;
pub const Event = engine.Event;
pub const Sink = engine.Sink;
pub const ListSink = engine.ListSink;
pub const Bar = engine.Bar;
pub const Daily = engine.Daily;
pub const Prices = engine.Prices;
pub const Feed = iface.Feed;
pub const Executor = iface.Executor;

test {
    std.testing.refAllDecls(@This());
    _ = @import("unit_tests.zig");
}
