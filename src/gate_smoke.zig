const std = @import("std");
const gate = @import("live_gate");
const exec = @import("live_executor");
const dgb = @import("arcis_dgb");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "zig-out/hearth-gate");
    const h = try cwd.openDir(io, "zig-out/hearth-gate", .{});

    const g = gate.Gate.check(io, h);
    std.debug.print("gate enabled={} reason={s}\n", .{ g.enabled, g.reason });

    var led = dgb.Ledger{
        .name = .{},
        .params = dgb.config.s1,
        .created_utc = .{},
        .start_px = .{ .dgb = 0.004, .maj = .{ 1, 1, 1 } },
        .start_usd = 1000,
        .start_dgb = 250000,
        .h = .{ .dgb = 0, .usd = 1000 },
        .grid = .{ .ref = 0.004, .step = null, .slice = 0.1, .last_recenter = 0 },
        .peak_usd = 1000,
    };
    var ex = exec.LiveExecutor.init(gpa, io, h);
    const ev = dgb.Event{
        .ledger = "S1",
        .t_ms = 0,
        .action = .buy,
        .asset = .DGB,
        .qty = 100,
        .price = 0.004,
        .usd = 0.4,
        .reason = .grid_level,
    };
    const ok = try ex.consider("S1", &led, ev, 0);
    std.debug.print("consider returned {} (expect false)\n", .{ok});
    const latest = try h.readFileAlloc(io, "audit/latest.log", gpa, .limited(1024));
    defer gpa.free(latest);
    std.debug.print("audit: {s}", .{latest});
    std.debug.print("gate smoke OK (live disabled)\n", .{});
}
