pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "shaderc-example",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zig_bgfx = b.lazyImport(@This(), "zig_bgfx") orelse {
        std.debug.print("couldn't lazyImport 'zig-bgfx'\n", .{});
        return;
    };

    // choose a default shader model based on OS
    const shader_model: zig_bgfx.ShaderModel = switch (target.result.os.tag) {
        .linux => .spirv,
        .macos => .metal,
        .windows => .s_5_0,
        else => .@"120",
    };

    // directly embed compiled shader in source file
    exe.root_module.addAnonymousImport("fs_color", .{
        .root_source_file = zig_bgfx.buildShader(
            b,
            target.result,
            b.path("shaders/fs_color.sc"),
            .fragment,
            shader_model,
        ),
    });

    // install compiled shader in zig-out
    const shader_install = b.addInstallFile(
        zig_bgfx.buildShader(
            b,
            target.result,
            b.path("shaders/vs_default.sc"),
            .vertex,
            shader_model,
        ),
        b.fmt("vs_default_{s}.bin", .{@tagName(shader_model)}),
    );
    b.getInstallStep().dependOn(&shader_install.step);

    // automatically compile and embed shaders into a module
    exe.root_module.addAnonymousImport(
        "shader",
        .{
            .root_source_file = zig_bgfx.createShaderModule(
                b,
                target.result,
                "shaders",
            ) catch {
                std.debug.panic("failed to create shader module from path 'shaders'", .{});
            },
        },
    );

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
