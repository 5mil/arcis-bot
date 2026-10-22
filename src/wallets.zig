//! Wallet destinations for realized gains.
//!
//! Rule: 5% of every fully realized gain is recorded as a return to the
//! funding wallet (to refuel trading). The remaining 95% is recorded as
//! going to the reward wallet.
//!
//! Funding address is supplied at build time for live mode:
//!   zig build -Dfunding=D... 
//! It is ignored in pure paper builds (empty default).
//! Keys stay in local files and are only read when the live gate is open.
const std = @import("std");
const build_options = @import("build_options");

pub const Split = struct {
    /// Fraction of realized gain returned to the funding wallet.
    refuel: f64 = 0.05,
    pub fn reward(self: Split) f64 {
        return 1.0 - self.refuel;
    }
};

pub const Wallets = struct {
    /// Funding / start wallet (also receives the 5% refuel).
    /// Comes from -Dfunding when building for live mode.
    funding: []const u8 = build_options.funding,
    /// Reward destination (receives 95%).
    reward: []const u8 = "DLbr1DaJs8bAU7BJfW92rLheVZHzDmR5KJ",
    split: Split = .{},

    pub fn setFunding(self: *Wallets, addr: []const u8) void {
        self.funding = addr;
    }
    pub fn setReward(self: *Wallets, addr: []const u8) void {
        self.reward = addr;
    }

    /// True when a funding address was supplied at build time.
    pub fn hasFunding(self: Wallets) bool {
        return self.funding.len > 0;
    }

    /// Split a realized USD gain. Returns (refuel_usd, reward_usd).
    pub fn splitGain(self: Wallets, gain_usd: f64) struct { refuel: f64, reward: f64 } {
        if (gain_usd <= 0) return .{ .refuel = 0, .reward = 0 };
        const r = gain_usd * self.split.refuel;
        return .{ .refuel = r, .reward = gain_usd - r };
    }
};

/// Append a split record to the hearth (paper observation only).
pub fn recordSplit(io: std.Io, hearth: std.Io.Dir, now_ms: i64, ledger: []const u8, gain_usd: f64, w: Wallets) !void {
    const s = w.splitGain(gain_usd);
    try hearth.createDirPath(io, "wallets");
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "{d} {s} gain={d:.4} refuel={d:.4} -> {s} reward={d:.4} -> {s}\n", .{
        now_ms, ledger, gain_usd, s.refuel, w.funding, s.reward, w.reward,
    });
    try hearth.writeFile(io, .{ .sub_path = "wallets/latest-split.log", .data = line });
}
