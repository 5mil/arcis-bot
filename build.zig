const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dgb_mod = b.createModule(.{
        .root_source_file = b.path("src/arcis-dgb/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const desk_mod = b.createModule(.{
        .root_source_file = b.path("src/dgb_desk.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "arcis_dgb", .module = dgb_mod } },
    });
    const live_mod = b.createModule(.{
        .root_source_file = b.path("src/live_feed.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "arcis_dgb", .module = dgb_mod } },
    });
    const routine_mod = b.createModule(.{
        .root_source_file = b.path("src/dgb_routine.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "arcis_dgb", .module = dgb_mod },
            .{ .name = "dgb_desk", .module = desk_mod },
            .{ .name = "live_feed", .module = live_mod },
        },
    });

    const smoke = b.addExecutable(.{ .name = "desk_smoke", .root_module = b.createModule(.{
        .root_source_file = b.path("src/desk_smoke.zig"), .target = target, .optimize = optimize,
        .imports = &.{ .{ .name = "arcis_dgb", .module = dgb_mod }, .{ .name = "dgb_desk", .module = desk_mod } },
    }) });
    b.installArtifact(smoke);
    const run_smoke = b.addRunArtifact(smoke);
    run_smoke.step.dependOn(b.getInstallStep());
    b.step("smoke", "ReplayFeed desk smoke").dependOn(&run_smoke.step);

    const live = b.addExecutable(.{ .name = "live_smoke", .root_module = b.createModule(.{
        .root_source_file = b.path("src/live_smoke.zig"), .target = target, .optimize = optimize,
        .imports = &.{ .{ .name = "arcis_dgb", .module = dgb_mod }, .{ .name = "dgb_desk", .module = desk_mod }, .{ .name = "live_feed", .module = live_mod } },
    }) });
    b.installArtifact(live);
    const run_live = b.addRunArtifact(live);
    run_live.step.dependOn(b.getInstallStep());
    b.step("live-smoke", "Live feed + desk tick").dependOn(&run_live.step);

    const routine = b.addExecutable(.{ .name = "dgb-routine", .root_module = routine_mod });
    b.installArtifact(routine);
    const run_routine = b.addRunArtifact(routine);
    run_routine.step.dependOn(b.getInstallStep());
    run_routine.addPassthruArgs();
    b.step("routine", "One paper tick + observation (pass -- --loop for 2h)").dependOn(&run_routine.step);
}
