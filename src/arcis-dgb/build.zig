const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module other packages (arcis) import as "arcis_dgb".
    const mod = b.addModule("arcis_dgb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "arcis-dgb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "arcis_dgb", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run the replay CLI").dependOn(&run_cmd.step);

    // Unit tests (in-module)
    const unit = b.addTest(.{ .root_module = mod });
    const run_unit = b.addRunArtifact(unit);

    // Parity tests vs the Python desk (fixtures in testdata/, regenerate with tools/gen_parity.py)
    const opts = b.addOptions();
    opts.addOptionPathDirectory("testdata", b.path("testdata"));
    const parity = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/parity.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "arcis_dgb", .module = mod },
                .{ .name = "build_options", .module = opts.createModule() },
            },
        }),
    });
    const run_parity = b.addRunArtifact(parity);

    const test_step = b.step("test", "Run unit + parity tests");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&run_parity.step);
    b.step("test-unit", "Run unit tests only").dependOn(&run_unit.step);
    b.step("test-parity", "Run parity tests only").dependOn(&run_parity.step);
}
