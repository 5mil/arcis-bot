//! 2-hour paper routine for the DGB desk.
//! Ticks both ledgers via the live (or any) Feed and appends an observation
//! to the hearth. PAPER ONLY.
//!
//! Callable from the Arcis workflow runner or run standalone:
//!   zig build routine          # one tick now
//!   zig build routine -- --loop  # every 2h
const std = @import("std");
const dgb = @import("arcis_dgb");
const desk_mod = @import("dgb_desk");
const live = @import("live_feed");

pub const Routine = struct {
    desk: desk_mod.Desk,
    feed: live.LiveFeed,
    gpa: std.mem.Allocator,
    io: std.Io,
    hearth: std.Io.Dir,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, hearth: std.Io.Dir) !Routine {
        return .{
            .desk = try desk_mod.Desk.init(gpa, io, hearth),
            .feed = live.LiveFeed.init(gpa, io),
            .gpa = gpa,
            .io = io,
            .hearth = hearth,
        };
    }

    pub fn deinit(self: *Routine) void {
        self.desk.deinit();
        self.feed.deinit();
    }

    /// One paper tick + observation. Feed failure leaves ledgers untouched.
    pub fn runOnce(self: *Routine, now_ms: i64) !void {
        var ls = dgb.ListSink.init(self.gpa);
        defer ls.deinit();
        self.desk.tickOnce(now_ms, self.feed.feed(), ls.sink()) catch |err| {
            try self.writeFail(now_ms, err);
            return;
        };
        try self.writeObservation(now_ms, &ls);
    }

    fn writeObservation(self: *Routine, now_ms: i64, ls: *dgb.ListSink) !void {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        try w.print("{d} dgb-desk-tick source={s} bars={d} events={d}\n", .{ now_ms, self.feed.source, self.feed.hourly.len, ls.list.items.len });
        const px = if (self.feed.hourly.len > 0)
            dgb.Prices{ .dgb = self.feed.hourly[self.feed.hourly.len - 1].c, .maj = self.feed.spot }
        else
            dgb.Prices{ .dgb = 0, .maj = .{ 0, 0, 0 } };
        inline for ([_]desk_mod.LedgerName{ .S1, .S5 }) |n| {
            if (self.desk.ledgers[@intFromEnum(n)]) |led| {
                const mode = if (led.halted) "HALTED" else @tagName(led.mode);
                if (self.desk.report(n, px)) |r| {
                    try w.print("  {s} score={d:.0} usd={d:.2} mode={s} fills={d} lots={d}\n", .{
                        @tagName(n), r.dgb_score, r.usd_total, mode, led.fills, led.grid.inv_len,
                    });
                }
            } else {
                try w.print("  {s} (not yet created)\n", .{@tagName(n)});
            }
        }
        // last few events
        const evs = ls.list.items;
        const start = if (evs.len > 5) evs.len - 5 else 0;
        for (evs[start..]) |ev| {
            try w.print("  event {s} {s} qty={d:.4} usd={d:.2}\n", .{ ev.action.pyName(), @tagName(ev.asset), ev.qty, ev.usd });
        }
        const text = aw.written();
        try self.hearth.createDirPath(self.io, "observations");
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "observations/{d}.log", .{now_ms});
        try self.hearth.writeFile(self.io, .{ .sub_path = name, .data = text });
        // also keep a latest pointer
        try self.hearth.writeFile(self.io, .{ .sub_path = "observations/latest.log", .data = text });
    }

    fn writeFail(self: *Routine, now_ms: i64, err: anyerror) !void {
        try self.hearth.createDirPath(self.io, "observations");
        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "{d} FEED_FAIL {s}\n", .{ now_ms, @errorName(err) });
        try self.hearth.writeFile(self.io, .{ .sub_path = "observations/latest.log", .data = msg });
        try self.hearth.writeFile(self.io, .{ .sub_path = "feed_fail.flag", .data = msg });
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(gpa);
    const loop = args.len > 1 and std.mem.eql(u8, args[1], "--loop");

    try cwd.createDirPath(io, "zig-out/hearth/state");
    try cwd.createDirPath(io, "zig-out/hearth/observations");
    const hdir = try cwd.openDir(io, "zig-out/hearth", .{});

    var r = try Routine.init(gpa, io, hdir);
    defer r.deinit();

    while (true) {
        const now_ts = std.Io.Clock.real.now(io);
        const now: i64 = now_ts.toMilliseconds();
        r.runOnce(now) catch |e| std.debug.print("routine error: {s}\n", .{@errorName(e)});
        std.debug.print("tick at {d} done\n", .{now});
        if (!loop) break;
        // sleep 2h
        std.Io.Clock.Duration.sleep(.{ .raw = .{ .nanoseconds = 2 * 3600 * 1_000_000_000 }, .clock = .real }, io) catch break;
    }
}
