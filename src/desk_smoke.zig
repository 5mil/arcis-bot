const std = @import("std");
const dgb = @import("arcis_dgb");
const desk = @import("dgb_desk");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var bars = try dgb.data.loadFile(gpa, io, "src/arcis-dgb/testdata/bars.json");
    defer bars.deinit(gpa);

    try cwd.createDirPath(io, "zig-out/hearth-smoke/state");
    const hdir = try cwd.openDir(io, "zig-out/hearth-smoke", .{});

    var d = try desk.Desk.init(gpa, io, hdir);
    defer d.deinit();

    var rf: dgb.iface.ReplayFeed = .{ .bars = &bars };
    var ls = dgb.ListSink.init(gpa);
    defer ls.deinit();

    const now = bars.hourly[bars.hourly.len - 1].t + dgb.engine.hour_ms;
    try d.tickOnce(now, rf.feed(), ls.sink());

    const s1 = d.ledgers[@intFromEnum(desk.LedgerName.S1)].?;
    const s5 = d.ledgers[@intFromEnum(desk.LedgerName.S5)].?;
    std.debug.print("S1 fills={d} mode={s} halted={}\n", .{ s1.fills, @tagName(s1.mode), s1.halted });
    std.debug.print("S5 fills={d} mode={s} halted={}\n", .{ s5.fills, @tagName(s5.mode), s5.halted });
    std.debug.print("events: {d}\n", .{ls.list.items.len});

    const px = dgb.Prices{ .dgb = bars.hourly[bars.hourly.len - 1].c, .maj = bars.spot_close[bars.spot_close.len - 1] };
    if (d.report(.S1, px)) |r| {
        std.debug.print("S1 score {d:.0} / start {d:.0}\n", .{ r.dgb_score, r.start_dgb });
    }
    if (d.report(.S5, px)) |r| {
        std.debug.print("S5 score {d:.0} / start {d:.0}\n", .{ r.dgb_score, r.start_dgb });
    }

    // confirm state files exist
    _ = try hdir.statFile(io, "state/S1.json", .{});
    _ = try hdir.statFile(io, "state/S5.json", .{});
    std.debug.print("state files written; desk ReplayFeed smoke OK\n", .{});
}
