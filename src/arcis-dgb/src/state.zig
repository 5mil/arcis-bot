//! JSON load/save compatible with the Python desk's state/<ledger>.json (S1.json / S5.json).
//! Zig can resume a ledger the Python desk wrote and vice versa. Floats are written in shortest
//! round-trip form, so a load -> save -> load cycle (in either language) is bit-exact.
//! Unknown extra keys are ignored on load.
const std = @import("std");
const engine = @import("engine.zig");
const config = @import("config.zig");
const Ledger = engine.Ledger;
const Value = std.json.Value;
const Writer = std.Io.Writer;

pub const LoadError = error{ InvalidState, OutOfMemory } || std.json.ParseError(std.json.Scanner);

/// Parse a Python-format ledger JSON document.
pub fn loadSlice(gpa: std.mem.Allocator, bytes: []const u8) LoadError!Ledger {
    const parsed = try std.json.parseFromSlice(Value, gpa, bytes, .{});
    defer parsed.deinit();
    return fromValue(parsed.value);
}

fn obj(v: Value, key: []const u8) !Value {
    if (v != .object) return error.InvalidState;
    return v.object.get(key) orelse error.InvalidState;
}
fn optField(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .null) null else x;
}
fn num(v: Value) !f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch error.InvalidState,
        else => error.InvalidState,
    };
}
fn int(v: Value) !i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => error.InvalidState,
    };
}
fn str(v: Value) ![]const u8 {
    return if (v == .string) v.string else error.InvalidState;
}
fn boolean(v: Value) !bool {
    return if (v == .bool) v.bool else error.InvalidState;
}
fn optNum(v: Value, key: []const u8) !?f64 {
    return if (optField(v, key)) |x| try num(x) else null;
}
fn optInt(v: Value, key: []const u8) !?i64 {
    return if (optField(v, key)) |x| try int(x) else null;
}
fn coins(v: Value) ![3]f64 {
    return .{ try num(try obj(v, "BTC")), try num(try obj(v, "LTC")), try num(try obj(v, "SOL")) };
}

pub fn paramsFromValue(p: Value) !config.Params {
    const strat = try str(try obj(p, "strategy"));
    return .{
        .strategy = if (std.mem.eql(u8, strat, "regime")) .regime else if (std.mem.eql(u8, strat, "grid")) .grid else return error.InvalidState,
        .k = try num(try obj(p, "k")),
        .levels = @intCast(try int(try obj(p, "levels"))),
        .smin = try num(try obj(p, "smin")),
        .smax = try num(try obj(p, "smax")),
        .vol_days = @intCast(try int(try obj(p, "vol_days"))),
        .recenter_days = @intCast(try int(try obj(p, "recenter_days"))),
        .band = (try optNum(p, "band")) orelse 0,
        .n = @intCast((try optInt(p, "n")) orelse 0),
    };
}

pub fn fromValue(v: Value) !Ledger {
    const params = try paramsFromValue(try obj(v, "params"));
    if (params.levels > config.max_levels) return error.InvalidState;
    const sp = try obj(v, "start_px");
    const h = try obj(v, "h");
    const va = try obj(v, "vault");
    const g = try obj(v, "grid");
    const c = try obj(v, "ctx");

    var led: Ledger = .{
        .name = engine.FixedStr(16).init(try str(try obj(v, "ledger"))),
        .params = params,
        .paper = if (optField(v, "paper")) |x| try boolean(x) else true,
        .created_utc = engine.FixedStr(40).init(if (optField(v, "created_utc")) |x| try str(x) else ""),
        .start_px = .{ .dgb = try num(try obj(sp, "DGB")), .maj = try coins(sp) },
        .start_usd = try num(try obj(v, "start_usd")),
        .start_dgb = try num(try obj(v, "start_dgb")),
        .h = .{ .dgb = try num(try obj(h, "DGB")), .usd = try num(try obj(h, "USD")), .maj = try coins(h) },
        .vault = .{
            .maj = try coins(va),
            .usdt_pending = try num(try obj(va, "usdt_pending")),
            .usdt_since = try optInt(va, "usdt_since"),
            .sol_wallet = try num(try obj(va, "sol_wallet")),
            .sol_withdrawals = @intCast(try int(try obj(va, "sol_withdrawals"))),
            .sol_fees = try num(try obj(va, "sol_fees")),
        },
        .grid = .{
            .ref = try num(try obj(g, "ref")),
            .step = try optNum(g, "step"),
            .slice = try num(try obj(g, "slice")),
            .active = try boolean(try obj(g, "active")),
            .last_recenter = try int(try obj(g, "last_recenter")),
        },
        .mode = if (std.mem.eql(u8, try str(try obj(v, "mode")), "BTC")) .BTC else .DGB,
        .left_dgb = try optNum(v, "left_dgb"),
        .last_bar = try optInt(v, "last_bar"),
        .last_day = try optInt(v, "last_day"),
        .ctx = .{
            .step = try optNum(c, "step"),
            .rel = if (optField(c, "rel")) |r| try coins(r) else null,
            .r = try optNum(c, "R"),
            .rma = try optNum(c, "Rma"),
        },
        .halted = try boolean(try obj(v, "halted")),
        .peak_usd = try num(try obj(v, "peak_usd")),
        .max_dd = try num(try obj(v, "max_dd")),
        .feed_fail = if (optField(v, "feed_fail")) |x| try boolean(x) else false,
        .siphoned_usd = try num(try obj(v, "siphoned_usd")),
        .fills = @intCast(try int(try obj(v, "fills"))),
    };
    if (optField(v, "source")) |x| led.source.set(try str(x));
    const inv = try obj(g, "inv");
    if (inv != .array) return error.InvalidState;
    for (inv.array.items) |lot| {
        if (lot != .array or lot.array.items.len != 2) return error.InvalidState;
        if (led.grid.inv_len >= config.max_levels) return error.InvalidState;
        led.grid.push(.{ .q = try num(lot.array.items[0]), .cost = try num(lot.array.items[1]) });
    }
    return led;
}

// ------------------------------------------------------------------ save

/// Python-repr-like float: shortest round-trip digits, ".0" on integral values.
pub fn writeFloat(w: *Writer, x: f64) Writer.Error!void {
    if (std.math.isNan(x)) return w.writeAll("NaN");
    if (std.math.isInf(x)) return w.writeAll(if (x > 0) "Infinity" else "-Infinity");
    const a = @abs(x);
    if (a < 1e16 and x == @trunc(x)) return w.print("{d}.0", .{x});
    if (a != 0 and (a < 1e-4 or a >= 1e16)) return w.print("{e}", .{x});
    return w.print("{d}", .{x});
}

fn writeOptFloat(w: *Writer, x: ?f64) Writer.Error!void {
    if (x) |y| try writeFloat(w, y) else try w.writeAll("null");
}
fn writeOptInt(w: *Writer, x: ?i64) Writer.Error!void {
    if (x) |y| try w.print("{d}", .{y}) else try w.writeAll("null");
}
fn writeStr(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        0...0x1f => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

/// Simple indent-1 JSON emitter mirroring Python's json.dump(..., indent=1) layout.
const J = struct {
    w: *Writer,
    depth: usize = 0,
    first: bool = true,
    fn nl(j: *J) !void {
        try j.w.writeByte('\n');
        for (0..j.depth) |_| try j.w.writeByte(' ');
    }
    fn key(j: *J, k: []const u8) !void {
        if (!j.first) try j.w.writeByte(',');
        j.first = false;
        try j.nl();
        try writeStr(j.w, k);
        try j.w.writeAll(": ");
    }
    fn open(j: *J, k: ?[]const u8) !void {
        if (k) |kk| try j.key(kk);
        try j.w.writeByte('{');
        j.depth += 1;
        j.first = true;
    }
    fn close(j: *J) !void {
        j.depth -= 1;
        try j.nl();
        try j.w.writeByte('}');
        j.first = false;
    }
    fn f(j: *J, k: []const u8, x: f64) !void {
        try j.key(k);
        try writeFloat(j.w, x);
    }
    fn of(j: *J, k: []const u8, x: ?f64) !void {
        try j.key(k);
        try writeOptFloat(j.w, x);
    }
    fn i(j: *J, k: []const u8, x: anytype) !void {
        try j.key(k);
        try j.w.print("{d}", .{x});
    }
    fn oi(j: *J, k: []const u8, x: ?i64) !void {
        try j.key(k);
        try writeOptInt(j.w, x);
    }
    fn b(j: *J, k: []const u8, x: bool) !void {
        try j.key(k);
        try j.w.writeAll(if (x) "true" else "false");
    }
    fn s(j: *J, k: []const u8, x: []const u8) !void {
        try j.key(k);
        try writeStr(j.w, x);
    }
    fn coins(j: *J, k: []const u8, x: [3]f64) !void {
        try j.open(k);
        try j.f("BTC", x[0]);
        try j.f("LTC", x[1]);
        try j.f("SOL", x[2]);
        try j.close();
    }
};

/// Write `led` in the Python state schema.
pub fn write(led: *const Ledger, w: *Writer) Writer.Error!void {
    var j: J = .{ .w = w };
    try w.writeByte('{');
    j.depth = 1;
    try j.s("ledger", led.name.slice());
    try j.open("params");
    const p = led.params;
    try j.s("strategy", @tagName(p.strategy));
    try j.f("k", p.k);
    try j.i("levels", p.levels);
    try j.f("smin", p.smin);
    try j.f("smax", p.smax);
    try j.i("vol_days", p.vol_days);
    try j.i("recenter_days", p.recenter_days);
    if (p.strategy == .regime) {
        try j.f("band", p.band);
        try j.i("n", p.n);
    }
    try j.close();
    try j.b("paper", led.paper);
    try j.s("created_utc", led.created_utc.slice());
    try j.open("start_px");
    try j.f("DGB", led.start_px.dgb);
    try j.f("BTC", led.start_px.maj[0]);
    try j.f("LTC", led.start_px.maj[1]);
    try j.f("SOL", led.start_px.maj[2]);
    try j.close();
    try j.f("start_usd", led.start_usd);
    try j.f("start_dgb", led.start_dgb);
    try j.open("h");
    try j.f("DGB", led.h.dgb);
    try j.f("USD", led.h.usd);
    try j.f("BTC", led.h.maj[0]);
    try j.f("LTC", led.h.maj[1]);
    try j.f("SOL", led.h.maj[2]);
    try j.close();
    try j.open("vault");
    try j.f("BTC", led.vault.maj[0]);
    try j.f("LTC", led.vault.maj[1]);
    try j.f("SOL", led.vault.maj[2]);
    try j.f("usdt_pending", led.vault.usdt_pending);
    try j.oi("usdt_since", led.vault.usdt_since);
    try j.f("sol_wallet", led.vault.sol_wallet);
    try j.i("sol_withdrawals", led.vault.sol_withdrawals);
    try j.f("sol_fees", led.vault.sol_fees);
    try j.close();
    try j.open("grid");
    try j.f("ref", led.grid.ref);
    try j.of("step", led.grid.step);
    try j.f("slice", led.grid.slice);
    try j.key("inv");
    try w.writeByte('[');
    for (led.grid.lots(), 0..) |lot, n| {
        if (n > 0) try w.writeAll(", ");
        try w.writeByte('[');
        try writeFloat(w, lot.q);
        try w.writeAll(", ");
        try writeFloat(w, lot.cost);
        try w.writeByte(']');
    }
    try w.writeByte(']');
    try j.b("active", led.grid.active);
    try j.i("last_recenter", led.grid.last_recenter);
    try j.close();
    try j.s("mode", @tagName(led.mode));
    try j.of("left_dgb", led.left_dgb);
    try j.oi("last_bar", led.last_bar);
    try j.oi("last_day", led.last_day);
    try j.open("ctx");
    if (led.ctx.step) |x| try j.f("step", x);
    if (led.ctx.rel) |x| try j.coins("rel", x);
    if (led.ctx.r) |x| try j.f("R", x);
    if (led.ctx.rma) |x| try j.f("Rma", x);
    try j.close();
    try j.b("halted", led.halted);
    try j.f("peak_usd", led.peak_usd);
    try j.f("max_dd", led.max_dd);
    try j.b("feed_fail", led.feed_fail);
    try j.f("siphoned_usd", led.siphoned_usd);
    try j.i("fills", led.fills);
    if (led.source.len > 0) try j.s("source", led.source.slice());
    try w.writeAll("\n}");
}

/// Serialize to a caller-owned slice.
pub fn saveAlloc(gpa: std.mem.Allocator, led: *const Ledger) error{OutOfMemory}![]u8 {
    var aw: Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    write(led, &aw.writer) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Atomic save (tmp + rename), like engine.py save(). `sub_path` e.g. "state/S1.json".
pub fn saveFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, led: *const Ledger) !void {
    const data = try saveAlloc(gpa, led);
    defer gpa.free(data);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{sub_path});
    defer gpa.free(tmp);
    try dir.writeFile(io, .{ .sub_path = tmp, .data = data });
    try dir.rename(tmp, dir, sub_path, io);
}

pub fn loadFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) !Ledger {
    const bytes = try dir.readFileAlloc(io, sub_path, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    return loadSlice(gpa, bytes);
}
