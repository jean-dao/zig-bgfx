const zig_bgfx = @import("zig_bgfx");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "zig_bgfx_example",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // link SDL
    const sdl = b.dependency("sdl", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    exe.linkLibrary(sdl.artifact("SDL3"));

    // link BGFX
    const bgfx = b.dependency("zig_bgfx", .{
        .target = target,
        .optimize = .ReleaseFast,
    });
    exe.linkLibrary(bgfx.artifact("bgfx"));

    // compile shaders
    const shader_dir = zig_bgfx.buildShaderDir(b, .{
        .target = target.result,
        .root_path = "shaders",
    }) catch {
        @panic("failed to compile all shaders in path 'shaders'");
    };

    // create a module to embed directly shaders in zig code
    exe.root_module.addAnonymousImport("shaders_lib", .{
        .root_source_file = zig_bgfx.createShaderModule(b, shader_dir) catch {
            std.debug.panic("failed to create shader module from path 'shaders'", .{});
        },
    });

    b.installArtifact(exe);

    // install compiled shaders in zig-out
    const shader_dir_install = b.addInstallDirectory(.{
        .source_dir = shader_dir.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "my_shader_dir",
    });
    b.getInstallStep().dependOn(&shader_dir_install.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

const std = @import("std");
