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
    const gate_mod = b.createModule(.{
        .root_source_file = b.path("src/live_gate.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exec_mod = b.createModule(.{
        .root_source_file = b.path("src/live_executor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "arcis_dgb", .module = dgb_mod },
            .{ .name = "live_gate", .module = gate_mod },
        },
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

    inline for (.{
        .{ "desk_smoke", "src/desk_smoke.zig", "smoke", "ReplayFeed desk smoke" },
        .{ "live_smoke", "src/live_smoke.zig", "live-smoke", "Live feed + desk tick" },
        .{ "gate_smoke", "src/gate_smoke.zig", "gate-smoke", "Confirm live gate closed" },
    }) |spec| {
        const exe = b.addExecutable(.{
            .name = spec[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(spec[1]),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "arcis_dgb", .module = dgb_mod },
                    .{ .name = "dgb_desk", .module = desk_mod },
                    .{ .name = "live_feed", .module = live_mod },
                    .{ .name = "live_gate", .module = gate_mod },
                    .{ .name = "live_executor", .module = exec_mod },
                },
            }),
        });
        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        run.step.dependOn(b.getInstallStep());
        b.step(spec[2], spec[3]).dependOn(&run.step);
    }

    const routine = b.addExecutable(.{ .name = "dgb-routine", .root_module = routine_mod });
    b.installArtifact(routine);
    const run_routine = b.addRunArtifact(routine);
    run_routine.step.dependOn(b.getInstallStep());
    run_routine.addPassthruArgs();
    b.step("routine", "One paper tick + observation").dependOn(&run_routine.step);
}
