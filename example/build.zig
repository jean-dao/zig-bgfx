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
        // example: disable DirectX 12 support
        .directx12 = false,
        // example: set supported OpenGL version (GLSL 1.4 used below is only supported since OpenGL 3.1)
        .@"opengl-version" = 31,
    });
    exe.linkLibrary(bgfx.artifact("bgfx"));

    // compile shaders
    const shader_dir = zig_bgfx.buildShaderDir(b, .{
        .target = target.result,
        .root_path = "shaders",
        .backend_configs = &.{
            .{ .name = "opengl", .shader_model = .@"140", .supported_platforms = &.{ .windows, .linux } },
            .{ .name = "vulkan", .shader_model = .spirv, .supported_platforms = &.{ .windows, .linux } },
            .{ .name = "directx", .shader_model = .s_5_0, .supported_platforms = &.{.windows} },
            .{ .name = "metal", .shader_model = .metal, .supported_platforms = &.{.macos} },
        },
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
        .source_dir = shader_dir.files.getDirectory(),
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
