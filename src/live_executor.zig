//! Live executor skeleton. Does NOT place orders.
//!
//! - Refuses unless the enablement gate is open for today.
//! - Applies the non-negotiable protections from the roadmap.
//! - Writes every decision to an append-only audit log under the hearth.
//! - On any protection trip: sets ledger.halted and returns without acting.
//!
//! PAPER ONLY until a real exchange client is deliberately wired behind the gate.
const std = @import("std");
const dgb = @import("arcis_dgb");
const gate = @import("live_gate");

pub const Limits = struct {
    daily_loss_cap_usd: f64 = 50,
    max_order_notional_usd: f64 = 100,
    max_open_lots: u32 = 12,
    max_consecutive_errors: u32 = 3,
    slippage_bps: f64 = 50,
};

pub const Audit = struct {
    ts: i64,
    ledger: []const u8,
    action: []const u8,
    detail: []const u8,
};

pub const LiveExecutor = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    hearth: std.Io.Dir,
    limits: Limits = .{},
    consecutive_errors: u32 = 0,
    day_start_usd: f64 = 0,
    day_id: i64 = 0,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, hearth: std.Io.Dir) LiveExecutor {
        return .{ .gpa = gpa, .io = io, .hearth = hearth };
    }

    /// Returns true if the order would have been allowed. Never places a real order.
    pub fn consider(self: *LiveExecutor, name: []const u8, led: *dgb.Ledger, ev: dgb.Event, now_ms: i64) !bool {
        // kill switch
        if (self.hearth.statFile(self.io, "KILL", .{})) |_| {
            led.halted = true;
            try self.audit(now_ms, name, "KILL", "manual kill switch");
            return false;
        } else |_| {}

        // gate
        const g = gate.Gate.check(self.io, self.hearth);
        if (!g.enabled) {
            try self.audit(now_ms, name, "GATE", g.reason);
            return false;
        }

        // daily loss
        const day = @divFloor(now_ms, dgb.engine.day_ms);
        if (day != self.day_id) {
            self.day_id = day;
            self.day_start_usd = dgb.score.usdTotal(&dgb.config.default, led, .{ .dgb = ev.price, .maj = led.start_px.maj });
        }
        const now_usd = dgb.score.usdTotal(&dgb.config.default, led, .{ .dgb = ev.price, .maj = led.start_px.maj });
        if (self.day_start_usd - now_usd > self.limits.daily_loss_cap_usd) {
            led.halted = true;
            try self.audit(now_ms, name, "DAILY_LOSS", "cap hit");
            return false;
        }

        // position size
        if (ev.usd > self.limits.max_order_notional_usd) {
            try self.audit(now_ms, name, "SIZE_CAP", "order too large");
            return false;
        }
        if (led.grid.inv_len >= self.limits.max_open_lots and ev.action == .buy) {
            try self.audit(now_ms, name, "LOTS_CAP", "too many open lots");
            return false;
        }

        // consecutive errors
        if (self.consecutive_errors >= self.limits.max_consecutive_errors) {
            led.halted = true;
            try self.audit(now_ms, name, "ERROR_HALT", "too many consecutive errors");
            return false;
        }

        // would place order here — deliberately not implemented
        try self.audit(now_ms, name, "WOULD_ORDER", "skeleton: no exchange client");
        return true;
    }

    pub fn noteError(self: *LiveExecutor) void {
        self.consecutive_errors += 1;
    }

    pub fn noteSuccess(self: *LiveExecutor) void {
        self.consecutive_errors = 0;
    }

    fn audit(self: *LiveExecutor, ts: i64, ledger: []const u8, action: []const u8, detail: []const u8) !void {
        try self.hearth.createDirPath(self.io, "audit");
        var buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{d} {s} {s} {s}\n", .{ ts, ledger, action, detail });
        var name: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "audit/{d}.log", .{ts});
        try self.hearth.writeFile(self.io, .{ .sub_path = path, .data = line });
        try self.hearth.writeFile(self.io, .{ .sub_path = "audit/latest.log", .data = line });
    }
};
