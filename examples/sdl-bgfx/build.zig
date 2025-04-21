pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "sdl-bgfx-example",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (target.result.os.tag != .linux) {
        const sdl = b.dependency("SDL", .{});
        exe.linkLibrary(sdl.artifact("SDL2"));
    } else {
        // allyourcodebase/SDL doesn't support Wayland
        exe.linkSystemLibrary("SDL2");
    }

    const bgfx = b.dependency("zig_bgfx", .{});
    exe.linkLibrary(bgfx.artifact("bgfx"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

const std = @import("std");
