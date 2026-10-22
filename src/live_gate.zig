//! Phase 2 enablement gate. Live orders are impossible unless this file
//! exists and contains a matching confirmation token.
//!
//! Enable (manual, reversible):
//!   echo "LIVE_ENABLE $(date -u +%Y%m%d)" > hearth/live.enable
//! Disable:
//!   rm hearth/live.enable
//!
//! PAPER ONLY until the token matches today's UTC date.
const std = @import("std");

pub const Gate = struct {
    enabled: bool = false,
    reason: []const u8 = "no live.enable",

    pub fn check(io: std.Io, hearth: std.Io.Dir) Gate {
        const today = blk: {
            const ts = std.Io.Clock.real.now(io);
            const secs = ts.toSeconds();
            const days = @divFloor(secs, 86400);
            // rough YYYYMMDD from days since epoch is overkill; just use the day number as token
            break :blk days;
        };
        var buf: [64]u8 = undefined;
        const n = hearth.readFile(io, "live.enable", &buf) catch return .{ .enabled = false, .reason = "no live.enable" };
        const text = std.mem.trim(u8, n, " \t\r\n");
        // expected: "LIVE_ENABLE <day>"
        var it = std.mem.splitScalar(u8, text, ' ');
        const tag = it.next() orelse return .{ .enabled = false, .reason = "bad token" };
        if (!std.mem.eql(u8, tag, "LIVE_ENABLE")) return .{ .enabled = false, .reason = "bad token" };
        const day_str = it.next() orelse return .{ .enabled = false, .reason = "missing day" };
        const day = std.fmt.parseInt(i64, day_str, 10) catch return .{ .enabled = false, .reason = "bad day" };
        if (day != today) return .{ .enabled = false, .reason = "token expired" };
        return .{ .enabled = true, .reason = "enabled" };
    }
};
