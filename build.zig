pub const ShadercBackendConfig = struct {
    enabled: ?bool = null,
    supported_platforms: []const std.Target.Os.Tag = &.{},
    name: []const u8,
    shader_model: ShaderModel,

    fn isEnabled(self: ShadercBackendConfig, platform: std.Target.Os.Tag) bool {
        if (self.enabled) |enabled|
            return enabled;

        for (self.supported_platforms) |supported_platform| {
            if (supported_platform == platform)
                return true;
        }

        return false;
    }
};

pub const default_shaderc_backend_configs: []const ShadercBackendConfig = &.{
    .{
        .name = "opengl",
        .supported_platforms = &.{ .windows, .linux },
        .shader_model = .@"120",
    },
    .{
        .name = "vulkan",
        .supported_platforms = &.{ .windows, .linux },
        .shader_model = .spirv,
    },
    .{
        .name = "metal",
        .supported_platforms = &.{.macos},
        .shader_model = .metal,
    },
    .{
        .name = "directx",
        .supported_platforms = &.{.windows},
        .shader_model = .s_5_0,
    },
};

pub const ShaderType = enum {
    vertex,
    fragment,
    compute,
};

pub const ShaderModel = enum {
    @"100_es",
    @"300_es",
    @"310_es",
    @"320_es",
    s_4_0,
    s_5_0,
    metal,
    @"metal10-10",
    @"metal11-10",
    @"metal12-10",
    @"metal20-11",
    @"metal21-11",
    @"metal22-11",
    @"metal23-14",
    @"metal24-14",
    @"metal30-14",
    @"metal31-14",
    pssl,
    spirv,
    @"spirv10-10",
    @"spirv13-11",
    @"spirv14-11",
    @"spirv15-12",
    @"spirv16-13",
    @"120",
    @"130",
    @"140",
    @"150",
    @"330",
    @"400",
    @"410",
    @"420",
    @"430",
    @"440",
};

pub const BackendType = enum {
    directx11,
    directx12,
    metal,
    vulkan,
    opengl,
};

pub const Backend = union(BackendType) {
    directx11,
    directx12,
    metal,
    vulkan,
    opengl: struct {
        gles: bool = false,
        version: u8,
    },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const bi: BuildInfo = .{
        .target = target,
        .optimize = b.standardOptimizeOption(.{}),
        .upstream_bgfx = b.dependency("bgfx", .{}),
        .upstream_bimg = b.dependency("bimg", .{}),
        .upstream_bx = b.dependency("bx", .{}),
    };

    if (b.option(bool, "bgfx", "Build BGFX library") orelse true)
        buildInstallBgfx(b, bi);

    if (b.option(bool, "shaderc", "Build shaderc") orelse false)
        buildInstallShaderc(b, bi);
}

fn getConfiguredBackend(b: *std.Build, tag: std.Target.Os.Tag, backend_type: BackendType) ?Backend {
    const name = @tagName(backend_type);
    switch (backend_type) {
        .opengl => {
            const opengl = b.option(bool, "opengl", "Enable BGFX 'opengl' backend") orelse
                backendDefaultSupport(backend_type, tag);

            const opengl_version = b.option(
                u8,
                "opengl-version",
                b.fmt(
                    "BGFX 'opengl' backend version (2-digit major-minor format, default: {})",
                    .{default_opengl_version},
                ),
            ) orelse default_opengl_version;

            // OpenGLES is not supported out of the box (untested), so only enable it when explicitly set
            const opengles = b.option(bool, "opengles", "Enable BGFX 'opengles' backend") orelse false;
            const opengles_version = b.option(
                u8,
                "opengles-version",
                b.fmt(
                    "BGFX 'opengles' backend version (2-digit major-minor format, default: {})",
                    .{default_opengles_version},
                ),
            ) orelse default_opengles_version;

            if (opengl and opengles)
                @panic("Cannot enable both 'opengl' and 'opengles' at the same time");

            if (!opengl and !opengles)
                return null;

            if (opengl)
                return .{ .opengl = .{ .gles = false, .version = opengl_version } };
            if (opengles)
                return .{ .opengl = .{ .gles = true, .version = opengles_version } };
            return null;
        },
        inline else => |nocfg_backend| {
            if (b.option(bool, name, b.fmt("Enable BGFX '{s}' backend", .{name}))) |enabled|
                return if (enabled) nocfg_backend else null;

            if (backendDefaultSupport(nocfg_backend, tag))
                return nocfg_backend;

            return null;
        },
    }
}

fn backendDefaultSupport(backend: BackendType, platform: std.Target.Os.Tag) bool {
    for (default_platforms.get(backend)) |default_platform| {
        if (default_platform == platform)
            return true;
    }

    return false;
}

const default_platforms: std.enums.EnumArray(BackendType, []const std.Target.Os.Tag) = .init(.{
    .directx11 = &.{.windows},
    .directx12 = &.{.windows},
    .metal = &.{.macos},
    .vulkan = &.{ .linux, .windows },
    .opengl = &.{ .linux, .windows },
});
const default_opengl_version = 21;
const default_opengles_version = 20;

pub const ShaderOptions = struct {
    target: std.Target,
    path: std.Build.LazyPath,
    type: ShaderType,
    model: ShaderModel,
};

pub fn buildShader(
    b: *std.Build,
    opts: ShaderOptions,
) std.Build.LazyPath {
    const zig_bgfx = b.dependencyFromBuildZig(@This(), .{
        // use native target to build shaderc
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
        .bgfx = false,
        .shaderc = true,
    });
    const shaderc = zig_bgfx.artifact("shaderc");
    return buildShaderInner(
        b,
        shaderc,
        zig_bgfx.builder.dependency("bgfx", .{}),
        opts.target,
        opts.path,
        "shader.bin",
        opts.type,
        opts.model,
    );
}

pub const ShaderDirOptions = struct {
    target: std.Target,
    root_path: []const u8,
    backend_configs: []const ShadercBackendConfig = default_shaderc_backend_configs,
};

const ShaderDir = struct {
    files: *std.Build.Step.WriteFile,
    backend_names: []const []const u8,
};

pub fn buildShaderDir(
    b: *std.Build,
    opts: ShaderDirOptions,
) !ShaderDir {
    const zig_bgfx = b.dependencyFromBuildZig(@This(), .{
        // use native target to build shaderc
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
        .bgfx = false,
        .shaderc = true,
    });
    const upstream_bgfx = zig_bgfx.builder.dependency("bgfx", .{});
    const shaderc = zig_bgfx.artifact("shaderc");

    var root_dir = b.build_root.handle.openDir(opts.root_path, .{ .iterate = true }) catch |err| {
        std.debug.panic(
            "unable to open '{s}' directory: {s}",
            .{ opts.root_path, @errorName(err) },
        );
    };
    defer root_dir.close();

    var wf = b.addWriteFiles();
    var it = try root_dir.walk(b.allocator);
    defer it.deinit();

    const extension = ".sc";
    while (try it.next()) |entry| {
        if (entry.kind == .directory)
            continue;

        if (!std.mem.endsWith(u8, entry.basename, extension))
            continue;

        const shader_type: ShaderType = if (std.mem.startsWith(u8, entry.basename, "fs_"))
            .fragment
        else if (std.mem.startsWith(u8, entry.basename, "vs_"))
            .vertex
        else if (std.mem.startsWith(u8, entry.basename, "cs_"))
            .compute
        else
            continue;

        const rel_dir_path = std.fs.path.dirname(entry.path);
        const input_path = b.pathJoin(&.{ opts.root_path, entry.path });
        const stem = entry.basename[0 .. entry.basename.len - extension.len];
        const basename = b.fmt("{s}.bin", .{stem});
        for (opts.backend_configs) |backend_config| {
            if (backend_config.isEnabled(opts.target.os.tag)) {
                // output compiled shader in backend specific directory
                const rel_output_path = if (rel_dir_path) |p|
                    b.pathJoin(&.{ backend_config.name, p, basename })
                else
                    b.pathJoin(&.{ backend_config.name, basename });

                const compiled_shader = buildShaderInner(
                    b,
                    shaderc,
                    upstream_bgfx,
                    opts.target,
                    b.path(input_path),
                    rel_output_path,
                    shader_type,
                    backend_config.shader_model,
                );

                _ = wf.addCopyFile(compiled_shader, rel_output_path);
            }
        }
    }

    var backend_names: std.ArrayList([]const u8) = .init(b.allocator);
    for (opts.backend_configs) |backend_config| {
        try backend_names.append(backend_config.name);
    }

    return .{ .files = wf, .backend_names = backend_names.items };
}

pub fn createShaderModule(
    b: *std.Build,
    input: ShaderDir,
) !std.Build.LazyPath {
    var builder: ModuleBuilder = .{};
    defer builder.deinit(b.allocator);

    const wf = b.addWriteFiles();
    for (input.files.files.items) |file| {
        const lazy_path: std.Build.LazyPath = .{
            .generated = .{
                .file = &input.files.generated_directory,
                .sub_path = file.sub_path,
            },
        };
        _ = wf.addCopyFile(lazy_path, file.sub_path);

        try builder.add(b.allocator, file.sub_path);
    }

    const content = try builder.genContent(b.allocator, input);
    defer b.allocator.free(content);

    return wf.add("shader_module.zig", content);
}

const ModuleBuilder = struct {
    backends: std.StringHashMapUnmanaged(void) = .empty,
    toplevels: std.StringHashMapUnmanaged(void) = .empty,
    decls: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) = .empty,

    const BackendGen = struct {
        type: std.ArrayListUnmanaged(u8),
        decls: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(u8)),
        escaped_path_sep: []const u8,

        fn init(
            allocator: std.mem.Allocator,
            escaped_path_sep: []const u8,
            backend_names: []const []const u8,
        ) !BackendGen {
            var self: BackendGen = .{
                .type = .empty,
                .decls = .empty,
                .escaped_path_sep = escaped_path_sep,
            };

            for (backend_names) |backend_name| {
                try self.decls.putNoClobber(allocator, backend_name, .empty);

                const backend_decl = self.decls.getPtr(backend_name).?;
                try backend_decl.appendSlice(allocator, "pub const ");
                try backend_decl.appendSlice(allocator, backend_name);
                try backend_decl.appendSlice(allocator, ": ShaderCollection = .{\n");
            }

            try self.type.appendSlice(allocator, "const ShaderCollection = struct {\n");

            return self;
        }

        fn addField(
            self: *BackendGen,
            allocator: std.mem.Allocator,
            wf: *std.Build.Step.WriteFile,
            field_defs: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)),
            field: []const u8,
            indent: []const u8,
        ) !void {
            const name = std.fs.path.stem(field);
            try self.type.appendSlice(allocator, indent);
            try self.type.appendSlice(allocator, name);
            try self.type.appendSlice(allocator, ": ");

            if (field_defs.getPtr(field)) |children| {
                try self.type.appendSlice(allocator, "struct {\n");
                {
                    var backend_it = self.decls.valueIterator();
                    while (backend_it.next()) |backend_decl| {
                        try backend_decl.appendSlice(allocator, indent);
                        try backend_decl.append(allocator, '.');
                        try backend_decl.appendSlice(allocator, name);
                        try backend_decl.appendSlice(allocator, " = .{\n");
                    }
                }

                const child_indent = try std.mem.concat(allocator, u8, &.{
                    indent,
                    "    ",
                });
                defer allocator.free(child_indent);

                var children_it = children.keyIterator();
                while (children_it.next()) |child_ptr| {
                    try self.addField(
                        allocator,
                        wf,
                        field_defs,
                        child_ptr.*,
                        child_indent,
                    );
                }

                try self.type.appendSlice(allocator, indent);
                try self.type.appendSlice(allocator, "} = .{},\n");
                {
                    var backend_it = self.decls.valueIterator();
                    while (backend_it.next()) |backend_decl| {
                        try backend_decl.appendSlice(allocator, indent);
                        try backend_decl.appendSlice(allocator, "},\n");
                    }
                }
            } else {
                try self.type.appendSlice(allocator, "[]const u8 = &.{},\n");

                var backend_it = self.decls.iterator();
                while (backend_it.next()) |kv| {
                    const backend = kv.key_ptr.*;
                    const path = try std.fs.path.join(allocator, &.{ backend, field });
                    defer allocator.free(path);
                    path_exists: {
                        for (wf.files.items) |file| {
                            if (std.mem.eql(u8, file.sub_path, path))
                                break :path_exists;
                        }

                        continue;
                    }

                    const backend_decl = kv.value_ptr;
                    try backend_decl.appendSlice(allocator, indent);
                    try backend_decl.append(allocator, '.');
                    try backend_decl.appendSlice(allocator, name);
                    try backend_decl.appendSlice(allocator, " = @\"");
                    try backend_decl.appendSlice(allocator, backend);
                    try backend_decl.appendSlice(allocator, self.escaped_path_sep);
                    try backend_decl.appendSlice(allocator, field);
                    try backend_decl.appendSlice(allocator, "\"[0..],\n");
                }
            }
        }

        fn appendInto(
            self: BackendGen,
            allocator: std.mem.Allocator,
            content: *std.ArrayListUnmanaged(u8),
        ) !void {
            try content.appendSlice(allocator, self.type.items);
            try content.appendSlice(allocator, "};\n\n");

            var backend_decl_it = self.decls.valueIterator();
            while (backend_decl_it.next()) |backend_decl| {
                try content.appendSlice(allocator, backend_decl.items);
                try content.appendSlice(allocator, "};\n\n");
            }
        }

        fn deinit(self: *BackendGen, allocator: std.mem.Allocator) void {
            self.type.deinit(allocator);

            {
                var it = self.decls.valueIterator();
                while (it.next()) |backend_decl| {
                    backend_decl.deinit(allocator);
                }
                self.decls.deinit(allocator);
            }
        }
    };

    fn genContent(
        self: *ModuleBuilder,
        allocator: std.mem.Allocator,
        input: ShaderDir,
    ) ![]const u8 {
        var content: std.ArrayListUnmanaged(u8) = .empty;
        const escaped_path_sep = blk: {
            const size = std.mem.replacementSize(u8, std.fs.path.sep_str, "\\", "\\\\");
            const output = try allocator.alloc(u8, size);
            _ = std.mem.replace(u8, std.fs.path.sep_str, "\\", "\\\\", output);
            break :blk output;
        };
        defer allocator.free(escaped_path_sep);

        // embed shader file declarations
        for (input.files.files.items) |file| {
            const escaped_name = blk: {
                const size = std.mem.replacementSize(
                    u8,
                    file.sub_path,
                    std.fs.path.sep_str,
                    escaped_path_sep,
                );
                const output = try allocator.alloc(u8, size);
                _ = std.mem.replace(
                    u8,
                    file.sub_path,
                    std.fs.path.sep_str,
                    escaped_path_sep,
                    output,
                );
                break :blk output;
            };
            defer allocator.free(escaped_name);
            try content.appendSlice(allocator, "const @\"");
            try content.appendSlice(allocator, escaped_name);
            try content.appendSlice(allocator, "\" = @embedFile(\"");
            try content.appendSlice(allocator, escaped_name);
            try content.appendSlice(allocator, "\");\n");
        }

        try content.append(allocator, '\n');

        var backend_gen: BackendGen = try .init(allocator, escaped_path_sep, input.backend_names);
        defer backend_gen.deinit(allocator);

        var toplevel_it = self.toplevels.keyIterator();
        while (toplevel_it.next()) |toplevel_ptr| {
            try backend_gen.addField(allocator, input.files, self.decls, toplevel_ptr.*, "    ");
        }

        try backend_gen.appendInto(allocator, &content);
        return try content.toOwnedSlice(allocator);
    }

    fn add(self: *ModuleBuilder, allocator: std.mem.Allocator, path: []const u8) !void {
        var it = try std.fs.path.componentIterator(path);
        const backend = (it.first() orelse return).name;
        if (!self.backends.contains(backend))
            try self.backends.putNoClobber(allocator, backend, {});

        std.debug.assert(std.mem.startsWith(u8, path, backend));
        std.debug.assert(std.mem.eql(
            u8,
            path[backend.len..][0..std.fs.path.sep_str.len],
            std.fs.path.sep_str,
        ));

        const subpath = path[backend.len + std.fs.path.sep_str.len ..];
        try self.addDecls(allocator, subpath);
    }

    fn addDecls(
        self: *ModuleBuilder,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !void {
        if (std.fs.path.dirname(path)) |parent| {
            const parent_gop = try self.decls.getOrPut(allocator, parent);
            if (!parent_gop.found_existing)
                parent_gop.value_ptr.* = .empty;
            try parent_gop.value_ptr.put(allocator, path, {});
            try self.addDecls(allocator, parent);
        } else {
            if (!self.toplevels.contains(path))
                try self.toplevels.putNoClobber(allocator, path, {});
        }
    }

    fn deinit(self: *ModuleBuilder, allocator: std.mem.Allocator) void {
        self.backends.deinit(allocator);
        self.toplevels.deinit(allocator);

        var decl_it = self.decls.valueIterator();
        while (decl_it.next()) |value_ptr| {
            value_ptr.deinit(allocator);
        }
        self.decls.deinit(allocator);
    }
};

fn buildShaderInner(
    b: *std.Build,
    shaderc: *std.Build.Step.Compile,
    upstream_bgfx: *std.Build.Dependency,
    target: std.Target,
    input_path: std.Build.LazyPath,
    output_path: []const u8,
    shader_type: ShaderType,
    shader_model: ShaderModel,
) std.Build.LazyPath {
    const shaderc_step = b.addRunArtifact(shaderc);
    shaderc_step.addArg("-i");
    shaderc_step.addDirectoryArg(upstream_bgfx.path("src"));
    shaderc_step.addArg("-f");
    shaderc_step.addFileArg(input_path);
    shaderc_step.addArg("-o");
    const output = shaderc_step.addOutputFileArg(output_path);

    shaderc_step.addArgs(&.{
        "--type",
        @tagName(shader_type),
        "--platform",
        switch (target.os.tag) {
            .linux => "linux",
            .windows => "windows",
            .macos => "osx",
            else => |tag| {
                std.debug.print("building shaders for target {s} is not supported\n", .{@tagName(tag)});
                unreachable;
            },
        },
        "--profile",
        @tagName(shader_model),
    });

    return output;
}

fn buildInstallBgfx(b: *std.Build, bi: BuildInfo) void {
    const lib = b.addLibrary(.{
        .name = "bgfx",
        .root_module = b.createModule(.{
            .target = bi.target,
            .optimize = bi.optimize,
        }),
    });

    const tag = bi.target.result.os.tag;
    switch (tag) {
        .linux => {
            lib.linkSystemLibrary("GL");
            lib.linkSystemLibrary("X11");
        },
        .windows => {
            lib.linkSystemLibrary("opengl32");
            lib.linkSystemLibrary("gdi32");
        },
        .macos => {
            lib.linkFramework("QuartzCore");
        },
        else => {
            std.debug.print("warning: unsupported os {s}, no system library linked", .{@tagName(tag)});
        },
    }

    // enable backends
    for (std.enums.values(BackendType)) |backend_type| {
        if (getConfiguredBackend(b, tag, backend_type)) |backend| {
            switch (backend) {
                .directx11 => lib.root_module.addCMacro("BGFX_CONFIG_RENDERER_DIRECT3D11", "1"),
                .directx12 => lib.root_module.addCMacro("BGFX_CONFIG_RENDERER_DIRECT3D12", "1"),
                .metal => lib.root_module.addCMacro("BGFX_CONFIG_RENDERER_METAL", "1"),
                .vulkan => lib.root_module.addCMacro("BGFX_CONFIG_RENDERER_VULKAN", "1"),
                .opengl => |cfg| lib.root_module.addCMacro(
                    if (cfg.gles) "BGFX_CONFIG_RENDERER_OPENGLES" else "BGFX_CONFIG_RENDERER_OPENGL",
                    b.fmt("{}", .{cfg.version}),
                ),
            }
        }
    }

    // include paths
    lib.addIncludePath(bi.upstream_bimg.path("include"));
    lib.addIncludePath(bi.upstream_bgfx.path("include"));

    lib.addIncludePath(bi.upstream_bimg.path("3rdparty"));
    lib.addIncludePath(bi.upstream_bimg.path("3rdparty/astc-encoder/include"));
    lib.addIncludePath(bi.upstream_bgfx.path("3rdparty"));
    lib.addIncludePath(bi.upstream_bgfx.path("3rdparty/khronos"));
    lib.addIncludePath(bi.upstream_bgfx.path("src"));
    if (tag == .windows)
        lib.addIncludePath(bi.upstream_bgfx.path("3rdparty/directx-headers/include/directx"));

    // source files
    lib.addCSourceFiles(.{
        .root = bi.upstream_bimg.path("src"),
        .files = bimg_src_files,
        .flags = bgfx_cpp_flags,
    });

    lib.addCSourceFiles(.{
        .root = bi.upstream_bimg.path("3rdparty/astc-encoder/source"),
        .files = bimg_astc_codec_src_files,
        .flags = bgfx_cpp_flags,
    });

    lib.addCSourceFiles(.{
        .root = bi.upstream_bgfx.path("src"),
        .files = if (tag == .macos) macos_bgfx_src_files else bgfx_src_files,
        .flags = bgfx_cpp_flags,
    });

    lib.root_module.addCMacro("BX_CONFIG_DEBUG", switch (bi.optimize) {
        .Debug => "1",
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => "0",
    });
    includeBx(bi, lib);

    lib.linkLibCpp();

    // install lib and headers
    b.installArtifact(lib);
    lib.installHeader(bi.upstream_bx.path("include/bx/platform.h"), "bx/platform.h");
    lib.installHeader(bi.upstream_bgfx.path("include/bgfx/defines.h"), "bgfx/defines.h");
    lib.installHeader(bi.upstream_bgfx.path("include/bgfx/c99/bgfx.h"), "bgfx/c99/bgfx.h");
}

fn buildInstallShaderc(b: *std.Build, bi: BuildInfo) void {
    const exe = b.addExecutable(.{
        .name = "shaderc",
        .root_module = b.createModule(.{
            .target = bi.target,
            .optimize = bi.optimize,
        }),
    });

    // spirv-tools
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/spirv-tools"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/spirv-tools/include"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/spirv-tools/include/generated"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/spirv-tools/source"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/spirv-headers/include"));
    exe.addCSourceFiles(.{
        .root = bi.upstream_bgfx.path("3rdparty/spirv-tools/source"),
        .files = spirv_tools_src_files,
        .flags = spirv_tools_cpp_flags,
    });

    // spirv-cross
    exe.root_module.addCMacro("SPIRV_CROSS_EXCEPTIONS_TO_ASSERTIONS", "");
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/spirv-cross/include"));
    exe.addCSourceFiles(.{
        .root = bi.upstream_bgfx.path("3rdparty/spirv-cross"),
        .files = spirv_cross_src_files,
        .flags = spirv_cross_cpp_flags,
    });

    // glslang
    exe.root_module.addCMacro("ENABLE_OPT", "1");
    exe.root_module.addCMacro("ENABLE_HLSL", "1");
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/glslang"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/spirv-tools/include"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/spirv-tools/source"));
    exe.addCSourceFiles(.{
        .root = bi.upstream_bgfx.path("3rdparty/glslang"),
        .files = glslang_src_files,
        .flags = glslang_cpp_flags,
    });

    if (bi.target.result.os.tag == .windows) {
        exe.addCSourceFiles(.{
            .root = bi.upstream_bgfx.path("3rdparty/glslang"),
            .files = windows_glslang_src_files,
            .flags = glslang_cpp_flags,
        });
    } else {
        exe.addCSourceFiles(.{
            .root = bi.upstream_bgfx.path("3rdparty/glslang"),
            .files = not_windows_glslang_src_files,
            .flags = glslang_cpp_flags,
        });
    }

    // glsl-optimizer
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/glsl-optimizer/include"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/glsl-optimizer/src"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/glsl-optimizer/src/mesa"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/glsl-optimizer/src/mapi"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/glsl-optimizer/src/glsl"));
    exe.addCSourceFiles(.{
        .root = bi.upstream_bgfx.path("3rdparty/glsl-optimizer/src"),
        .files = glsl_optimizer_src_files,
        .flags = glsl_optimizer_cpp_flags,
    });

    // fcpp
    exe.root_module.addCMacro("NINCLUDE", "64");
    exe.root_module.addCMacro("NWORK", "65536");
    exe.root_module.addCMacro("NBUF", "65536");
    exe.root_module.addCMacro("OLD_PREPROCESSOR", "0");
    exe.addCSourceFiles(.{
        .root = bi.upstream_bgfx.path("3rdparty/fcpp"),
        .files = fcpp_src_files,
        .flags = fcpp_cpp_flags,
    });

    // shaderc
    exe.addIncludePath(bi.upstream_bimg.path("include"));
    exe.addIncludePath(bi.upstream_bgfx.path("include"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/dxsdk/include"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/fcpp"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/glslang/glslang/Public"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/glslang/glslang/Include"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/glslang"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/glsl-optimizer/include"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/glsl-optimizer/src/glsl"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/spirv-cross"));
    exe.addIncludePath(bi.upstream_bgfx.path("3rdparty/spirv-tools/include"));
    exe.addCSourceFiles(.{
        .root = bi.upstream_bgfx.path(""),
        .files = shaderc_src_files,
        .flags = shaderc_cpp_flags,
    });

    if (bi.target.result.os.tag == .macos) {
        exe.linkFramework("Cocoa");
    }

    exe.root_module.addCMacro("BX_CONFIG_DEBUG", "0");
    includeBx(bi, exe);
    exe.linkLibCpp();
    b.installArtifact(exe);
}

fn includeBx(bi: BuildInfo, comp: *std.Build.Step.Compile) void {
    comp.addIncludePath(bi.upstream_bx.path("include"));
    comp.addIncludePath(bi.upstream_bx.path("3rdparty"));

    switch (bi.target.result.os.tag) {
        .linux => comp.addIncludePath(bi.upstream_bx.path("include/compat/linux")),
        .windows => comp.addIncludePath(bi.upstream_bx.path("include/compat/mingw")),
        .macos => comp.addIncludePath(bi.upstream_bx.path("include/compat/osx")),
        else => |tag| std.debug.print(
            "warning: unsupported os {s}, include directives will be missing",
            .{@tagName(tag)},
        ),
    }

    comp.addCSourceFiles(.{
        .root = bi.upstream_bx.path("src"),
        .files = bx_src_files,
        .flags = bgfx_cpp_flags,
    });

    comp.linkLibCpp();
}

const BuildInfo = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    upstream_bgfx: *std.Build.Dependency,
    upstream_bimg: *std.Build.Dependency,
    upstream_bx: *std.Build.Dependency,
};

const bgfx_cpp_flags = &.{
    "-fno-strict-aliasing",
    "-fno-exceptions",
    "-fno-sanitize=undefined",
    "-fno-rtti",
    "-ffast-math",
    "-Wno-date-time",
};

const bx_src_files = &.{
    "amalgamated.cpp",
};

const bimg_src_files = &.{
    "image.cpp",
    "image_gnf.cpp",
};

const bimg_astc_codec_src_files = &.{
    "astcenc_averages_and_directions.cpp",
    "astcenc_integer_sequence.cpp",
    "astcenc_block_sizes.cpp",
    "astcenc_mathlib.cpp",
    "astcenc_color_quantize.cpp",
    "astcenc_mathlib_softfloat.cpp",
    "astcenc_color_unquantize.cpp",
    "astcenc_partition_tables.cpp",
    "astcenc_compress_symbolic.cpp",
    "astcenc_percentile_tables.cpp",
    "astcenc_compute_variance.cpp",
    "astcenc_pick_best_endpoint_format.cpp",
    "astcenc_decompress_symbolic.cpp",
    "astcenc_diagnostic_trace.cpp",
    "astcenc_quantization.cpp",
    "astcenc_entry.cpp",
    "astcenc_symbolic_physical.cpp",
    "astcenc_find_best_partitioning.cpp",
    "astcenc_weight_align.cpp",
    "astcenc_ideal_endpoints_and_weights.cpp",
    "astcenc_weight_quant_xfer_tables.cpp",
    "astcenc_image.cpp",
};

const bgfx_src_files = &.{
    "amalgamated.cpp",
};

const macos_bgfx_src_files = &.{
    "amalgamated.mm",
};

const spirv_tools_cpp_flags = &.{
    "-Wno-switch",
    "-Wno-misleading-indentation",
    "-fno-sanitize=undefined",
};

const spirv_tools_src_files = &.{
    "opt/aggressive_dead_code_elim_pass.cpp",
    "opt/pass_manager.cpp",
    "opt/dead_insert_elim_pass.cpp",
    "opt/remove_unused_interface_variables_pass.cpp",
    "opt/propagator.cpp",
    "opt/eliminate_dead_members_pass.cpp",
    "opt/block_merge_pass.cpp",
    "opt/local_single_store_elim_pass.cpp",
    "opt/loop_fusion_pass.cpp",
    "opt/eliminate_dead_io_components_pass.cpp",
    "opt/build_module.cpp",
    "opt/replace_desc_array_access_using_var_index.cpp",
    "opt/compact_ids_pass.cpp",
    "opt/relax_float_ops_pass.cpp",
    "opt/desc_sroa_util.cpp",
    "opt/instruction.cpp",
    "opt/eliminate_dead_functions_util.cpp",
    "opt/def_use_manager.cpp",
    "opt/optimizer.cpp",
    "opt/ir_context.cpp",
    "opt/modify_maximal_reconvergence.cpp",
    "opt/convert_to_half_pass.cpp",
    "opt/basic_block.cpp",
    "opt/copy_prop_arrays.cpp",
    "opt/replace_invalid_opc.cpp",
    "opt/spread_volatile_semantics.cpp",
    "opt/type_manager.cpp",
    "opt/workaround1209.cpp",
    "opt/module.cpp",
    "opt/loop_dependence.cpp",
    "opt/amd_ext_to_khr.cpp",
    "opt/licm_pass.cpp",
    "opt/types.cpp",
    "opt/wrap_opkill.cpp",
    "opt/register_pressure.cpp",
    "opt/switch_descriptorset_pass.cpp",
    "opt/feature_manager.cpp",
    "opt/combine_access_chains.cpp",
    "opt/pch_source_opt.cpp",
    "opt/mem_pass.cpp",
    "opt/opextinst_forward_ref_fixup_pass.cpp",
    "opt/freeze_spec_constant_value_pass.cpp",
    "opt/scalar_analysis_simplification.cpp",
    "opt/local_single_block_elim_pass.cpp",
    "opt/dead_variable_elimination.cpp",
    "opt/ir_loader.cpp",
    "opt/ssa_rewrite_pass.cpp",
    "opt/scalar_analysis.cpp",
    "opt/dead_branch_elim_pass.cpp",
    "opt/desc_sroa.cpp",
    "opt/fold_spec_constant_op_and_composite_pass.cpp",
    "opt/loop_fission.cpp",
    "opt/vector_dce.cpp",
    "opt/fix_func_call_arguments.cpp",
    "opt/if_conversion.cpp",
    "opt/unify_const_pass.cpp",
    "opt/analyze_live_input_pass.cpp",
    "opt/graphics_robust_access_pass.cpp",
    "opt/struct_cfg_analysis.cpp",
    "opt/inline_exhaustive_pass.cpp",
    "opt/scalar_replacement_pass.cpp",
    "opt/ccp_pass.cpp",
    "opt/private_to_local_pass.cpp",
    "opt/trim_capabilities_pass.cpp",
    "opt/remove_duplicates_pass.cpp",
    "opt/loop_peeling.cpp",
    "opt/loop_unroller.cpp",
    "opt/loop_descriptor.cpp",
    "opt/loop_fusion.cpp",
    "opt/dataflow.cpp",
    "opt/flatten_decoration_pass.cpp",
    "opt/constants.cpp",
    "opt/folding_rules.cpp",
    "opt/eliminate_dead_constant_pass.cpp",
    "opt/simplification_pass.cpp",
    "opt/interp_fixup_pass.cpp",
    "opt/cfg.cpp",
    "opt/local_redundancy_elimination.cpp",
    "opt/reduce_load_size.cpp",
    "opt/strip_debug_info_pass.cpp",
    "opt/code_sink.cpp",
    "opt/loop_dependence_helpers.cpp",
    "opt/set_spec_constant_default_value_pass.cpp",
    "opt/loop_unswitch_pass.cpp",
    "opt/loop_utils.cpp",
    "opt/inline_opaque_pass.cpp",
    "opt/redundancy_elimination.cpp",
    "opt/decoration_manager.cpp",
    "opt/split_combined_image_sampler_pass.cpp",
    "opt/inline_pass.cpp",
    "opt/invocation_interlock_placement_pass.cpp",
    "opt/merge_return_pass.cpp",
    "opt/block_merge_util.cpp",
    "opt/eliminate_dead_output_stores_pass.cpp",
    "opt/fold.cpp",
    "opt/local_access_chain_convert_pass.cpp",
    "opt/remove_dontinline_pass.cpp",
    "opt/cfg_cleanup_pass.cpp",
    "opt/strength_reduction_pass.cpp",
    "opt/pass.cpp",
    "opt/function.cpp",
    "opt/composite.cpp",
    "opt/eliminate_dead_functions_pass.cpp",
    "opt/instruction_list.cpp",
    "opt/dominator_analysis.cpp",
    "opt/value_number_table.cpp",
    "opt/control_dependence.cpp",
    "opt/struct_packing_pass.cpp",
    "opt/interface_var_sroa.cpp",
    "opt/liveness.cpp",
    "opt/convert_to_sampled_image_pass.cpp",
    "opt/dominator_tree.cpp",
    "opt/debug_info_manager.cpp",
    "opt/const_folding_rules.cpp",
    "opt/strip_nonsemantic_info_pass.cpp",
    "opt/fix_storage_class.cpp",
    "opt/upgrade_memory_model.cpp",
    "reduce/structured_loop_to_selection_reduction_opportunity_finder.cpp",
    "reduce/simple_conditional_branch_to_branch_reduction_opportunity.cpp",
    "reduce/remove_instruction_reduction_opportunity.cpp",
    "reduce/conditional_branch_to_simple_conditional_branch_reduction_opportunity.cpp",
    "reduce/remove_selection_reduction_opportunity.cpp",
    "reduce/reduction_opportunity.cpp",
    "reduce/structured_loop_to_selection_reduction_opportunity.cpp",
    "reduce/structured_construct_to_block_reduction_opportunity_finder.cpp",
    "reduce/remove_selection_reduction_opportunity_finder.cpp",
    "reduce/remove_function_reduction_opportunity_finder.cpp",
    "reduce/reduction_util.cpp",
    "reduce/remove_unused_struct_member_reduction_opportunity_finder.cpp",
    "reduce/pch_source_reduce.cpp",
    "reduce/merge_blocks_reduction_opportunity.cpp",
    "reduce/operand_to_dominating_id_reduction_opportunity_finder.cpp",
    "reduce/operand_to_const_reduction_opportunity_finder.cpp",
    "reduce/conditional_branch_to_simple_conditional_branch_opportunity_finder.cpp",
    "reduce/change_operand_to_undef_reduction_opportunity.cpp",
    "reduce/remove_function_reduction_opportunity.cpp",
    "reduce/reducer.cpp",
    "reduce/structured_construct_to_block_reduction_opportunity.cpp",
    "reduce/reduction_pass.cpp",
    "reduce/merge_blocks_reduction_opportunity_finder.cpp",
    "reduce/operand_to_undef_reduction_opportunity_finder.cpp",
    "reduce/remove_block_reduction_opportunity_finder.cpp",
    "reduce/remove_block_reduction_opportunity.cpp",
    "reduce/change_operand_reduction_opportunity.cpp",
    "reduce/remove_struct_member_reduction_opportunity.cpp",
    "reduce/reduction_opportunity_finder.cpp",
    "reduce/simple_conditional_branch_to_branch_opportunity_finder.cpp",
    "reduce/remove_unused_instruction_reduction_opportunity_finder.cpp",
    "val/construct.cpp",
    "val/validate_logicals.cpp",
    "val/validate_memory_semantics.cpp",
    "val/validate_barriers.cpp",
    "val/validate_decorations.cpp",
    "val/validate_interfaces.cpp",
    "val/validate_image.cpp",
    "val/validate_scopes.cpp",
    "val/instruction.cpp",
    "val/validate_ray_query.cpp",
    "val/basic_block.cpp",
    "val/validate.cpp",
    "val/validate_small_type_uses.cpp",
    "val/validate_instruction.cpp",
    "val/validate_literals.cpp",
    "val/validate_primitives.cpp",
    "val/validate_non_uniform.cpp",
    "val/validate_composites.cpp",
    "val/validate_tensor_layout.cpp",
    "val/validate_bitwise.cpp",
    "val/validate_capability.cpp",
    "val/validate_function.cpp",
    "val/validate_mesh_shading.cpp",
    "val/validation_state.cpp",
    "val/validate_ray_tracing.cpp",
    "val/validate_misc.cpp",
    "val/validate_cfg.cpp",
    "val/validate_annotation.cpp",
    "val/validate_arithmetics.cpp",
    "val/validate_constants.cpp",
    "val/validate_execution_limitations.cpp",
    "val/validate_builtins.cpp",
    "val/validate_derivatives.cpp",
    "val/validate_extensions.cpp",
    "val/validate_ray_tracing_reorder.cpp",
    "val/validate_type.cpp",
    "val/validate_debug.cpp",
    "val/validate_mode_setting.cpp",
    "val/validate_layout.cpp",
    "val/validate_atomics.cpp",
    "val/function.cpp",
    "val/validate_id.cpp",
    "val/validate_conversion.cpp",
    "val/validate_adjacency.cpp",
    "val/validate_memory.cpp",
    "assembly_grammar.cpp",
    "binary.cpp",
    "diagnostic.cpp",
    "disassemble.cpp",
    "enum_string_mapping.cpp",
    "ext_inst.cpp",
    "extensions.cpp",
    "libspirv.cpp",
    "name_mapper.cpp",
    "opcode.cpp",
    "operand.cpp",
    "parsed_operand.cpp",
    "print.cpp",
    "software_version.cpp",
    "spirv_endian.cpp",
    "spirv_optimizer_options.cpp",
    "spirv_reducer_options.cpp",
    "spirv_target_env.cpp",
    "spirv_validator_options.cpp",
    "table.cpp",
    "text.cpp",
    "text_handler.cpp",
    "to_string.cpp",
    "util/bit_vector.cpp",
    "util/parse_number.cpp",
    "util/string_utils.cpp",
};

const spirv_cross_cpp_flags = &.{
    "-Wno-type-limits",
    "-fno-sanitize=undefined",
};

const spirv_cross_src_files = &.{
    "spirv_cfg.cpp",
    "spirv_cpp.cpp",
    "spirv_cross.cpp",
    "spirv_cross_parsed_ir.cpp",
    "spirv_cross_util.cpp",
    "spirv_glsl.cpp",
    "spirv_hlsl.cpp",
    "spirv_msl.cpp",
    "spirv_parser.cpp",
    "spirv_reflect.cpp",
};

const glslang_cpp_flags = &.{
    "-Wno-logical-op",
    "-Wno-maybe-uninitialized",
    "-fno-strict-aliasing",
    "-Wno-ignored-qualifiers",
    "-Wno-implicit-fallthrough",
    "-Wno-missing-field-initializers",
    "-Wno-reorder",
    "-Wno-return-type",
    "-Wno-shadow",
    "-Wno-sign-compare",
    "-Wno-switch",
    "-Wno-undef",
    "-Wno-unknown-pragmas",
    "-Wno-unused-function",
    "-Wno-unused-parameter",
    "-Wno-unused-variable",
    "-Wno-c++11-extensions",
    "-Wno-unused-const-variable",
    "-Wno-deprecated-register",
    "-Wno-unused-but-set-variable",
    "-fno-sanitize=undefined",
};

const glslang_src_files = &.{
    "glslang/GenericCodeGen/CodeGen.cpp",
    "glslang/GenericCodeGen/Link.cpp",
    "glslang/HLSL/hlslGrammar.cpp",
    "glslang/HLSL/hlslTokenStream.cpp",
    "glslang/HLSL/hlslOpMap.cpp",
    "glslang/HLSL/hlslScanContext.cpp",
    "glslang/HLSL/hlslAttributes.cpp",
    "glslang/HLSL/hlslParseables.cpp",
    "glslang/HLSL/hlslParseHelper.cpp",
    "glslang/CInterface/glslang_c_interface.cpp",
    "glslang/stub.cpp",
    "glslang/MachineIndependent/attribute.cpp",
    "glslang/MachineIndependent/Versions.cpp",
    "glslang/MachineIndependent/ParseHelper.cpp",
    "glslang/MachineIndependent/InfoSink.cpp",
    "glslang/MachineIndependent/linkValidate.cpp",
    "glslang/MachineIndependent/preprocessor/PpContext.cpp",
    "glslang/MachineIndependent/preprocessor/Pp.cpp",
    "glslang/MachineIndependent/preprocessor/PpTokens.cpp",
    "glslang/MachineIndependent/preprocessor/PpScanner.cpp",
    "glslang/MachineIndependent/preprocessor/PpAtom.cpp",
    "glslang/MachineIndependent/IntermTraverse.cpp",
    "glslang/MachineIndependent/limits.cpp",
    "glslang/MachineIndependent/glslang_tab.cpp",
    "glslang/MachineIndependent/parseConst.cpp",
    "glslang/MachineIndependent/Constant.cpp",
    "glslang/MachineIndependent/SpirvIntrinsics.cpp",
    "glslang/MachineIndependent/ShaderLang.cpp",
    "glslang/MachineIndependent/Scan.cpp",
    "glslang/MachineIndependent/ParseContextBase.cpp",
    "glslang/MachineIndependent/intermOut.cpp",
    "glslang/MachineIndependent/reflection.cpp",
    "glslang/MachineIndependent/iomapper.cpp",
    "glslang/MachineIndependent/RemoveTree.cpp",
    "glslang/MachineIndependent/SymbolTable.cpp",
    "glslang/MachineIndependent/Initialize.cpp",
    "glslang/MachineIndependent/PoolAlloc.cpp",
    "glslang/MachineIndependent/Intermediate.cpp",
    "glslang/MachineIndependent/propagateNoContraction.cpp",
    "glslang/ResourceLimits/ResourceLimits.cpp",
    "glslang/ResourceLimits/resource_limits_c.cpp",

    "SPIRV/Logger.cpp",
    "SPIRV/GlslangToSpv.cpp",
    "SPIRV/InReadableOrder.cpp",
    "SPIRV/CInterface/spirv_c_interface.cpp",
    "SPIRV/SPVRemapper.cpp",
    "SPIRV/SpvBuilder.cpp",
    "SPIRV/doc.cpp",
    "SPIRV/SpvTools.cpp",
    "SPIRV/SpvPostProcess.cpp",
    "SPIRV/disassemble.cpp",
};

const windows_glslang_src_files = &.{
    "glslang/OSDependent/Windows/ossource.cpp",
};

const not_windows_glslang_src_files = &.{
    "glslang/OSDependent/Unix/ossource.cpp",
};

const glsl_optimizer_cpp_flags = &.{
    "-fno-strict-aliasing",
    "-Wno-implicit-fallthrough",
    "-Wno-parentheses",
    "-Wno-sign-compare",
    "-Wno-unused-function",
    "-Wno-unused-parameter",
    "-Wno-deprecated-register",
    "-Wno-misleading-indentation",
    "-fno-sanitize=undefined",
};

const glsl_optimizer_src_files = &.{
    "glsl/glcpp/glcpp-lex.c",
    "glsl/glcpp/glcpp-parse.c",
    "glsl/glcpp/pp.c",
    "glsl/ast_array_index.cpp",
    "glsl/ast_expr.cpp",
    "glsl/ast_function.cpp",
    "glsl/ast_to_hir.cpp",
    "glsl/ast_type.cpp",
    "glsl/builtin_functions.cpp",
    "glsl/builtin_types.cpp",
    "glsl/builtin_variables.cpp",
    "glsl/glsl_lexer.cpp",
    "glsl/glsl_optimizer.cpp",
    "glsl/glsl_parser.cpp",
    "glsl/glsl_parser_extras.cpp",
    "glsl/glsl_symbol_table.cpp",
    "glsl/glsl_types.cpp",
    "glsl/hir_field_selection.cpp",
    "glsl/ir.cpp",
    "glsl/ir_basic_block.cpp",
    "glsl/ir_builder.cpp",
    "glsl/ir_clone.cpp",
    "glsl/ir_constant_expression.cpp",
    "glsl/ir_equals.cpp",
    "glsl/ir_expression_flattening.cpp",
    "glsl/ir_function.cpp",
    "glsl/ir_function_can_inline.cpp",
    "glsl/ir_function_detect_recursion.cpp",
    "glsl/ir_hierarchical_visitor.cpp",
    "glsl/ir_hv_accept.cpp",
    "glsl/ir_import_prototypes.cpp",
    "glsl/ir_print_glsl_visitor.cpp",
    "glsl/ir_print_metal_visitor.cpp",
    "glsl/ir_print_visitor.cpp",
    "glsl/ir_rvalue_visitor.cpp",
    "glsl/ir_stats.cpp",
    "glsl/ir_unused_structs.cpp",
    "glsl/ir_validate.cpp",
    "glsl/ir_variable_refcount.cpp",
    "glsl/link_atomics.cpp",
    "glsl/link_functions.cpp",
    "glsl/link_interface_blocks.cpp",
    "glsl/link_uniform_block_active_visitor.cpp",
    "glsl/link_uniform_blocks.cpp",
    "glsl/link_uniform_initializers.cpp",
    "glsl/link_uniforms.cpp",
    "glsl/link_varyings.cpp",
    "glsl/linker.cpp",
    "glsl/loop_analysis.cpp",
    "glsl/loop_controls.cpp",
    "glsl/loop_unroll.cpp",
    "glsl/lower_clip_distance.cpp",
    "glsl/lower_discard.cpp",
    "glsl/lower_discard_flow.cpp",
    "glsl/lower_if_to_cond_assign.cpp",
    "glsl/lower_instructions.cpp",
    "glsl/lower_jumps.cpp",
    "glsl/lower_mat_op_to_vec.cpp",
    "glsl/lower_named_interface_blocks.cpp",
    "glsl/lower_noise.cpp",
    "glsl/lower_offset_array.cpp",
    "glsl/lower_output_reads.cpp",
    "glsl/lower_packed_varyings.cpp",
    "glsl/lower_packing_builtins.cpp",
    "glsl/lower_ubo_reference.cpp",
    "glsl/lower_variable_index_to_cond_assign.cpp",
    "glsl/lower_vec_index_to_cond_assign.cpp",
    "glsl/lower_vec_index_to_swizzle.cpp",
    "glsl/lower_vector.cpp",
    "glsl/lower_vector_insert.cpp",
    "glsl/lower_vertex_id.cpp",
    "glsl/opt_algebraic.cpp",
    "glsl/opt_array_splitting.cpp",
    "glsl/opt_constant_folding.cpp",
    "glsl/opt_constant_propagation.cpp",
    "glsl/opt_constant_variable.cpp",
    "glsl/opt_copy_propagation.cpp",
    "glsl/opt_copy_propagation_elements.cpp",
    "glsl/opt_cse.cpp",
    "glsl/opt_dead_builtin_variables.cpp",
    "glsl/opt_dead_builtin_varyings.cpp",
    "glsl/opt_dead_code.cpp",
    "glsl/opt_dead_code_local.cpp",
    "glsl/opt_dead_functions.cpp",
    "glsl/opt_flatten_nested_if_blocks.cpp",
    "glsl/opt_flip_matrices.cpp",
    "glsl/opt_function_inlining.cpp",
    "glsl/opt_if_simplification.cpp",
    "glsl/opt_minmax.cpp",
    "glsl/opt_noop_swizzle.cpp",
    "glsl/opt_rebalance_tree.cpp",
    "glsl/opt_redundant_jumps.cpp",
    "glsl/opt_structure_splitting.cpp",
    "glsl/opt_swizzle_swizzle.cpp",
    "glsl/opt_tree_grafting.cpp",
    "glsl/opt_vectorize.cpp",
    "glsl/s_expression.cpp",
    "glsl/standalone_scaffolding.cpp",
    "glsl/strtod.c",
    "mesa/main/imports.c",
    "mesa/program/prog_hash_table.c",
    "mesa/program/symbol_table.c",
    "util/hash_table.c",
    "util/ralloc.c",
};

const fcpp_cpp_flags = &.{
    "-Wno-implicit-fallthrough",
    "-Wno-incompatible-pointer-types",
    "-Wno-parentheses-equality",
    "-fno-sanitize=undefined",
};

const fcpp_src_files = &.{
    "cpp1.c",
    "cpp2.c",
    "cpp3.c",
    "cpp4.c",
    "cpp5.c",
    "cpp6.c",
};

const shaderc_cpp_flags = &.{
    "-fno-rtti",
    "-fno-sanitize=undefined",
};

const shaderc_src_files = &.{
    "tools/shaderc/shaderc_hlsl.cpp",
    "tools/shaderc/shaderc.cpp",
    "tools/shaderc/shaderc_spirv.cpp",
    "tools/shaderc/shaderc_metal.cpp",
    "tools/shaderc/shaderc_pssl.cpp",
    "tools/shaderc/shaderc_glsl.cpp",
    "src/vertexlayout.cpp",
    "src/shader.cpp",
    "src/shader_dxbc.cpp",
    "src/shader_spirv.cpp",
};

const std = @import("std");
