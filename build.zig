const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zctx", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    // Example executables
    const example_names = [_][]const u8{
        "basic",
        "timeout",
        "propagation",
        "value",
        "wait_any",
    };

    for (&example_names) |name| {
        const src_path = b.fmt("example/{s}.zig", .{name});
        const step_name = b.fmt("run-example-{s}", .{name});
        const step_desc = b.fmt("Run example: {s}", .{name});

        const exe_mod = b.createModule(.{
            .root_source_file = b.path(src_path),
            .target = target,
            .optimize = optimize,
        });
        exe_mod.addImport("zctx", mod);

        const exe = b.addExecutable(.{
            .name = name,
            .root_module = exe_mod,
        });

        const run = b.addRunArtifact(exe);
        const step = b.step(step_name, step_desc);
        step.dependOn(&run.step);
    }
}
