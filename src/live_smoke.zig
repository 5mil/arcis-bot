const std = @import("std");
const dgb = @import("arcis_dgb");
const desk = @import("dgb_desk");
const live = @import("live_feed");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    try cwd.createDirPath(io, "zig-out/hearth-live/state");
    const hdir = try cwd.openDir(io, "zig-out/hearth-live", .{});

    var d = try desk.Desk.init(gpa, io, hdir);
    defer d.deinit();

    var lf = live.LiveFeed.init(gpa, io);
    defer lf.deinit();

    const now_ts = std.Io.Clock.real.now(io);
    const now: i64 = @intCast(@divFloor(now_ts.nanoseconds, 1_000_000));
    try d.tickOnce(now, lf.feed(), dgb.engine.null_sink);

    const s1 = d.ledgers[@intFromEnum(desk.LedgerName.S1)].?;
    const s5 = d.ledgers[@intFromEnum(desk.LedgerName.S5)].?;
    std.debug.print("source={s} bars={d}\n", .{ lf.source, lf.hourly.len });
    std.debug.print("S1 fills={d} mode={s}\n", .{ s1.fills, @tagName(s1.mode) });
    std.debug.print("S5 fills={d} mode={s}\n", .{ s5.fills, @tagName(s5.mode) });
    const px = dgb.Prices{ .dgb = lf.hourly[lf.hourly.len - 1].c, .maj = lf.spot };
    if (d.report(.S1, px)) |r| std.debug.print("S1 score {d:.0}\n", .{r.dgb_score});
    if (d.report(.S5, px)) |r| std.debug.print("S5 score {d:.0}\n", .{r.dgb_score});
    std.debug.print("live feed smoke OK\n", .{});
}
