//! Keyless public Feed for the DGB paper desk.
//! Crypto.com preferred (DGB_USD + *_USDT), data-api.binance.vision fallback.
//! Closed bars only (t + 1h <= now). PAPER ONLY — no keys, no orders.
const std = @import("std");
const dgb = @import("arcis_dgb");

const hour_ms = dgb.engine.hour_ms;
const day_ms = dgb.engine.day_ms;

pub const LiveFeed = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    hourly: []dgb.Bar = &.{},
    daily_dgb: []dgb.engine.DailyClose = &.{},
    daily_maj: [3][]dgb.engine.DailyClose = .{ &.{}, &.{}, &.{} },
    spot: [3]f64 = .{ 0, 0, 0 },
    source: []const u8 = "none",
    window: usize = 99,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) LiveFeed {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(self: *LiveFeed) void {
        self.gpa.free(self.hourly);
        self.gpa.free(self.daily_dgb);
        for (self.daily_maj) |d| self.gpa.free(d);
        self.* = undefined;
    }

    pub fn feed(self: *LiveFeed) dgb.Feed {
        return .{ .ptr = self, .vtable = &.{ .fetch = fetchImpl } };
    }

    fn fetchImpl(ptr: *anyopaque, now_ms: i64) dgb.iface.FeedError!dgb.iface.Snapshot {
        const self: *LiveFeed = @ptrCast(@alignCast(ptr));
        self.fetchInto(now_ms) catch return error.FeedDown;
        if (self.hourly.len == 0) return error.NoData;
        return .{
            .source = self.source,
            .hourly = self.hourly,
            .daily = .{ .dgb = self.daily_dgb, .maj = self.daily_maj },
            .spot = self.spot,
        };
    }

    fn fetchInto(self: *LiveFeed, now_ms: i64) !void {
        // free previous
        self.gpa.free(self.hourly);
        self.gpa.free(self.daily_dgb);
        for (self.daily_maj) |d| self.gpa.free(d);
        self.hourly = &.{};
        self.daily_dgb = &.{};
        self.daily_maj = .{ &.{}, &.{}, &.{} };

        var client: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
        defer client.deinit();

        // try Crypto.com first
        if (self.fetchCrypto(&client, now_ms)) |_| {
            self.source = "cryptocom";
            return;
        } else |_| {}

        // fallback
        try self.fetchBinance(&client, now_ms);
        self.source = "binance";
    }

    fn fetchCrypto(self: *LiveFeed, client: *std.http.Client, now_ms: i64) !void {
        const dgb_raw = try get(self.gpa, client, "https://api.crypto.com/exchange/v1/public/get-candlestick?instrument_name=DGB_USD&timeframe=1h&count=120");
        defer self.gpa.free(dgb_raw);
        const btc_raw = try get(self.gpa, client, "https://api.crypto.com/exchange/v1/public/get-candlestick?instrument_name=BTC_USDT&timeframe=1h&count=120");
        defer self.gpa.free(btc_raw);
        const ltc_raw = try get(self.gpa, client, "https://api.crypto.com/exchange/v1/public/get-candlestick?instrument_name=LTC_USDT&timeframe=1h&count=120");
        defer self.gpa.free(ltc_raw);
        const sol_raw = try get(self.gpa, client, "https://api.crypto.com/exchange/v1/public/get-candlestick?instrument_name=SOL_USDT&timeframe=1h&count=120");
        defer self.gpa.free(sol_raw);

        const dgb_bars = try parseCrypto(self.gpa, dgb_raw, now_ms);
        defer self.gpa.free(dgb_bars);
        const btc_bars = try parseCrypto(self.gpa, btc_raw, now_ms);
        defer self.gpa.free(btc_bars);
        const ltc_bars = try parseCrypto(self.gpa, ltc_raw, now_ms);
        defer self.gpa.free(ltc_bars);
        const sol_bars = try parseCrypto(self.gpa, sol_raw, now_ms);
        defer self.gpa.free(sol_bars);

        try self.alignAndStore(dgb_bars, btc_bars, ltc_bars, sol_bars);
    }

    fn fetchBinance(self: *LiveFeed, client: *std.http.Client, now_ms: i64) !void {
        const base = "https://data-api.binance.vision/api/v3/klines?interval=1h&limit=120&symbol=";
        const dgb_raw = try get(self.gpa, client, base ++ "DGBUSDT");
        defer self.gpa.free(dgb_raw);
        const btc_raw = try get(self.gpa, client, base ++ "BTCUSDT");
        defer self.gpa.free(btc_raw);
        const ltc_raw = try get(self.gpa, client, base ++ "LTCUSDT");
        defer self.gpa.free(ltc_raw);
        const sol_raw = try get(self.gpa, client, base ++ "SOLUSDT");
        defer self.gpa.free(sol_raw);

        const dgb_bars = try parseBinance(self.gpa, dgb_raw, now_ms);
        defer self.gpa.free(dgb_bars);
        const btc_bars = try parseBinance(self.gpa, btc_raw, now_ms);
        defer self.gpa.free(btc_bars);
        const ltc_bars = try parseBinance(self.gpa, ltc_raw, now_ms);
        defer self.gpa.free(ltc_bars);
        const sol_bars = try parseBinance(self.gpa, sol_raw, now_ms);
        defer self.gpa.free(sol_bars);

        try self.alignAndStore(dgb_bars, btc_bars, ltc_bars, sol_bars);
    }

    fn alignAndStore(self: *LiveFeed, dgb_b: []const dgb.Bar, btc_b: []const dgb.Bar, ltc_b: []const dgb.Bar, sol_b: []const dgb.Bar) !void {
        // align on common timestamps (oldest first, already sorted)
        var n: usize = 0;
        var tmp: [120]dgb.Bar = undefined;
        var spots: [120][3]f64 = undefined;
        var i: usize = 0;
        var j: usize = 0;
        var k: usize = 0;
        var m: usize = 0;
        while (i < dgb_b.len and j < btc_b.len and k < ltc_b.len and m < sol_b.len) {
            const t = dgb_b[i].t;
            if (btc_b[j].t < t) { j += 1; continue; }
            if (ltc_b[k].t < t) { k += 1; continue; }
            if (sol_b[m].t < t) { m += 1; continue; }
            if (btc_b[j].t == t and ltc_b[k].t == t and sol_b[m].t == t) {
                if (n < tmp.len) {
                    tmp[n] = dgb_b[i];
                    spots[n] = .{ btc_b[j].c, ltc_b[k].c, sol_b[m].c };
                    n += 1;
                }
                i += 1; j += 1; k += 1; m += 1;
            } else {
                i += 1;
            }
        }
        if (n == 0) return error.NoData;
        // keep last window
        const start = if (n > self.window) n - self.window else 0;
        const hourly = try self.gpa.alloc(dgb.Bar, n - start);
        @memcpy(hourly, tmp[start..n]);
        self.hourly = hourly;
        self.spot = spots[n - 1];

        // derive daily closes (last hourly close of each UTC day)
        self.daily_dgb = try dailyFrom(self.gpa, hourly, null);
        var maj_h: [3][]dgb.Bar = undefined;
        // rebuild maj bars just for daily (same timestamps)
        var btc_h = try self.gpa.alloc(dgb.Bar, hourly.len);
        var ltc_h = try self.gpa.alloc(dgb.Bar, hourly.len);
        var sol_h = try self.gpa.alloc(dgb.Bar, hourly.len);
        for (hourly, 0..) |b, idx| {
            const s = spots[start + idx];
            btc_h[idx] = .{ .t = b.t, .o = s[0], .h = s[0], .l = s[0], .c = s[0] };
            ltc_h[idx] = .{ .t = b.t, .o = s[1], .h = s[1], .l = s[1], .c = s[1] };
            sol_h[idx] = .{ .t = b.t, .o = s[2], .h = s[2], .l = s[2], .c = s[2] };
        }
        maj_h = .{ btc_h, ltc_h, sol_h };
        defer self.gpa.free(btc_h);
        defer self.gpa.free(ltc_h);
        defer self.gpa.free(sol_h);
        for (0..3) |c| self.daily_maj[c] = try dailyFrom(self.gpa, maj_h[c], null);
    }
};

fn dailyFrom(gpa: std.mem.Allocator, bars: []const dgb.Bar, _: ?void) ![]dgb.engine.DailyClose {
    if (bars.len == 0) return &.{};
    var list: std.ArrayList(dgb.engine.DailyClose) = .empty;
    errdefer list.deinit(gpa);
    var cur_day: i64 = bars[0].t - @mod(bars[0].t, day_ms);
    var last_c = bars[0].c;
    for (bars) |b| {
        const day = b.t - @mod(b.t, day_ms);
        if (day != cur_day) {
            try list.append(gpa, .{ .t = cur_day, .c = last_c });
            cur_day = day;
        }
        last_c = b.c;
    }
    try list.append(gpa, .{ .t = cur_day, .c = last_c });
    return list.toOwnedSlice(gpa);
}

fn get(gpa: std.mem.Allocator, client: *std.http.Client, url: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    });
    if (res.status != .ok) return error.HttpError;
    return aw.toOwnedSlice();
}

fn parseBinance(gpa: std.mem.Allocator, raw: []const u8, now_ms: i64) ![]dgb.Bar {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{});
    defer parsed.deinit();
    const arr = parsed.value.array;
    var list: std.ArrayList(dgb.Bar) = .empty;
    errdefer list.deinit(gpa);
    for (arr.items) |item| {
        const a = item.array;
        if (a.items.len < 5) continue;
        const t = try numI(a.items[0]);
        if (t + hour_ms > now_ms) continue; // not yet closed
        try list.append(gpa, .{
            .t = t,
            .o = try numF(a.items[1]),
            .h = try numF(a.items[2]),
            .l = try numF(a.items[3]),
            .c = try numF(a.items[4]),
        });
    }
    return list.toOwnedSlice(gpa);
}

fn parseCrypto(gpa: std.mem.Allocator, raw: []const u8, now_ms: i64) ![]dgb.Bar {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{});
    defer parsed.deinit();
    const data = parsed.value.object.get("result").?.object.get("data").?.array;
    var list: std.ArrayList(dgb.Bar) = .empty;
    errdefer list.deinit(gpa);
    for (data.items) |item| {
        const o = item.object;
        const t = try numI(o.get("t").?);
        if (t + hour_ms > now_ms) continue;
        try list.append(gpa, .{
            .t = t,
            .o = try numF(o.get("o").?),
            .h = try numF(o.get("h").?),
            .l = try numF(o.get("l").?),
            .c = try numF(o.get("c").?),
        });
    }
    // Crypto.com returns newest first; reverse to oldest first
    std.mem.reverse(dgb.Bar, list.items);
    return list.toOwnedSlice(gpa);
}

fn numF(v: std.json.Value) !f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s),
        .string => |s| std.fmt.parseFloat(f64, s),
        else => error.BadNumber,
    };
}
fn numI(v: std.json.Value) !i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10),
        .string => |s| std.fmt.parseInt(i64, s, 10),
        else => error.BadNumber,
    };
}
