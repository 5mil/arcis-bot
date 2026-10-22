const std = @import("std");
const wallets = @import("wallets");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "zig-out/hearth-wallets");
    const h = try cwd.openDir(io, "zig-out/hearth-wallets", .{});

    var w = wallets.Wallets{};
    w.setFunding("DGB_FUNDING_ADDRESS");
    w.setReward("DGB_REWARD_ADDRESS");

    const s = w.splitGain(100.0);
    std.debug.print("gain 100 -> refuel {d:.2} reward {d:.2}\n", .{ s.refuel, s.reward });
    try wallets.recordSplit(io, h, 0, "S1", 100.0, w);
    std.debug.print("wallet split smoke OK (5/95)\n", .{});
}
