//! Thin paper desk for the arcis bot.
//! Owns S1 and S5 ledgers under a hearth directory, loads/saves state,
//! and drives one tick via the arcis-dgb engine.
//!
//! PAPER ONLY. No exchange clients, keys, orders or wallets.
//!
//! Usage (from a bot binary that has arcis_dgb on its module path):
//!   const desk = @import("dgb_desk");
//!   var d = try desk.Desk.init(gpa, io, hearth_dir);
//!   defer d.deinit();
//!   try d.tickOnce(now_ms, feed, sink);
const std = @import("std");
const dgb = @import("arcis_dgb");

pub const LedgerName = enum { S1, S5 };

pub const Desk = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    hearth: std.Io.Dir,
    cfg: dgb.Config = dgb.config.default,
    ledgers: [2]?dgb.Ledger = .{ null, null },

    pub fn init(gpa: std.mem.Allocator, io: std.Io, hearth: std.Io.Dir) !Desk {
        var self = Desk{ .gpa = gpa, .io = io, .hearth = hearth };
        try self.load();
        return self;
    }

    pub fn deinit(self: *Desk) void {
        // Ledgers are value types; nothing to free beyond what the caller owns.
        _ = self;
    }

    fn statePath(name: LedgerName) []const u8 {
        return switch (name) {
            .S1 => "state/S1.json",
            .S5 => "state/S5.json",
        };
    }

    fn params(name: LedgerName) dgb.Params {
        return switch (name) {
            .S1 => dgb.config.s1,
            .S5 => dgb.config.s5,
        };
    }

    fn load(self: *Desk) !void {
        inline for ([_]LedgerName{ .S1, .S5 }) |n| {
            const path = statePath(n);
            self.ledgers[@intFromEnum(n)] = dgb.state.loadFile(self.gpa, self.io, self.hearth, path) catch null;
        }
    }

    fn save(self: *Desk, name: LedgerName, led: *const dgb.Ledger) !void {
        try dgb.state.saveFile(self.gpa, self.io, self.hearth, statePath(name), led);
    }

    /// One routine tick for both ledgers.
    /// Feed failure leaves the corresponding ledger untouched.
    pub fn tickOnce(self: *Desk, now_ms: i64, feed: dgb.Feed, sink: dgb.Sink) !void {
        inline for ([_]LedgerName{ .S1, .S5 }) |n| {
            var stats: dgb.desk.RunStats = .{};
            const name_str = @tagName(n);
            try dgb.desk.tickOnce(&self.cfg, feed, name_str, params(n), &self.ledgers[@intFromEnum(n)], now_ms, sink, &stats);
            if (self.ledgers[@intFromEnum(n)]) |*led| {
                try self.save(n, led);
            }
        }
    }

    /// Score report for a ledger (null if not yet created).
    pub fn report(self: *const Desk, name: LedgerName, px: dgb.Prices) ?dgb.score.Report {
        const led = self.ledgers[@intFromEnum(name)] orelse return null;
        return dgb.score.report(&self.cfg, &led, px);
    }
};
