//! Historical bar set (replay input) and its JSON loader.
//! File format (written by tools/gen_parity.py, or by any exporter):
//!   { "hourly": [[t_ms, o, h, l, c, btc_close, ltc_close, sol_close], ...],   // DGB/USD 1h, ascending
//!     "daily":  { "DGB": [[day_ms, close], ...], "BTC": [...], "LTC": [...], "SOL": [...] } }
const std = @import("std");
const engine = @import("engine.zig");
const Bar = engine.Bar;
const DailyClose = engine.DailyClose;

pub const BarSet = struct {
    hourly: []Bar,
    /// BTC/LTC/SOL hourly close aligned with `hourly` (used as "latest spot" at a tick).
    spot_close: [][3]f64,
    daily_dgb: []DailyClose,
    daily_maj: [3][]DailyClose,

    pub fn daily(self: *const BarSet) engine.Daily {
        return .{ .dgb = self.daily_dgb, .maj = .{ self.daily_maj[0], self.daily_maj[1], self.daily_maj[2] } };
    }

    pub fn deinit(self: *BarSet, gpa: std.mem.Allocator) void {
        gpa.free(self.hourly);
        gpa.free(self.spot_close);
        gpa.free(self.daily_dgb);
        for (self.daily_maj) |d| gpa.free(d);
    }
};

const RawFile = struct {
    hourly: []const [8]f64,
    daily: struct { DGB: []const [2]f64, BTC: []const [2]f64, LTC: []const [2]f64, SOL: []const [2]f64 },
};

fn toDaily(gpa: std.mem.Allocator, raw: []const [2]f64) ![]DailyClose {
    const out = try gpa.alloc(DailyClose, raw.len);
    for (raw, 0..) |r, i| out[i] = .{ .t = @intFromFloat(r[0]), .c = r[1] };
    return out;
}

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !BarSet {
    const parsed = try std.json.parseFromSlice(RawFile, gpa, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const r = parsed.value;
    const hourly = try gpa.alloc(Bar, r.hourly.len);
    errdefer gpa.free(hourly);
    const spot = try gpa.alloc([3]f64, r.hourly.len);
    errdefer gpa.free(spot);
    for (r.hourly, 0..) |x, i| {
        hourly[i] = .{ .t = @intFromFloat(x[0]), .o = x[1], .h = x[2], .l = x[3], .c = x[4] };
        spot[i] = .{ x[5], x[6], x[7] };
    }
    return .{
        .hourly = hourly,
        .spot_close = spot,
        .daily_dgb = try toDaily(gpa, r.daily.DGB),
        .daily_maj = .{ try toDaily(gpa, r.daily.BTC), try toDaily(gpa, r.daily.LTC), try toDaily(gpa, r.daily.SOL) },
    };
}

pub fn loadFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !BarSet {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(512 << 20));
    defer gpa.free(bytes);
    return parse(gpa, bytes);
}
