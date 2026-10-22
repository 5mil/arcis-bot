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
    const exe = b.addExecutable(.{
        .name = "desk_smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/desk_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "arcis_dgb", .module = dgb_mod },
                .{ .name = "dgb_desk", .module = desk_mod },
            },
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("smoke", "Run desk ReplayFeed smoke").dependOn(&run.step);
}
