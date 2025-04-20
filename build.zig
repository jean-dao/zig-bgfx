pub fn build(b: *std.Build) !void {
    const bi: BuildInfo = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .upstream_bgfx = b.dependency("bgfx", .{}),
        .upstream_bimg = b.dependency("bimg", .{}),
        .upstream_bx = b.dependency("bx", .{}),
    };

    if (b.option(bool, "bgfx", "Build BGFX library") orelse true)
        try buildInstallBgfx(b, bi);

    if (b.option(bool, "shaderc", "Build shaderc") orelse false) {
        const shaderc = buildShaderc(b, bi, bi.optimize);
        b.installArtifact(shaderc);
    }
}

pub fn buildShader(
    b: *std.Build,
    target: std.Target,
    input: std.Build.LazyPath,
    shader_type: ShaderType,
    shader_model: ShaderModel,
) std.Build.LazyPath {
    const zig_bgfx = b.dependencyFromBuildZig(@This(), .{});
    const bi: BuildInfo = .{
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
        .upstream_bgfx = zig_bgfx.builder.dependency("bgfx", .{}),
        .upstream_bimg = zig_bgfx.builder.dependency("bimg", .{}),
        .upstream_bx = zig_bgfx.builder.dependency("bx", .{}),
    };
    const shaderc = buildShaderc(b, bi, .Debug);
    return buildShaderInner(b, bi, shaderc, target, input, "shader.bin", shader_type, shader_model);
}

pub fn createShaderModule(
    b: *std.Build,
    target: std.Target,
    root_path: []const u8,
) !std.Build.LazyPath {
    const zig_bgfx = b.dependencyFromBuildZig(@This(), .{});
    const bi: BuildInfo = .{
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
        .upstream_bgfx = zig_bgfx.builder.dependency("bgfx", .{}),
        .upstream_bimg = zig_bgfx.builder.dependency("bimg", .{}),
        .upstream_bx = zig_bgfx.builder.dependency("bx", .{}),
    };
    const shaderc = buildShaderc(b, bi, .Debug);

    const backends = try getBackends(b, target.os.tag);

    var root_dir = b.build_root.handle.openDir(root_path, .{ .iterate = true }) catch |err| {
        std.debug.panic("unable to open '{s}' directory: {s}", .{ root_path, @errorName(err) });
    };
    defer root_dir.close();

    var file_decls: std.ArrayListUnmanaged(u8) = .empty;
    defer file_decls.deinit(b.allocator);

    var mod_backend_type: std.ArrayListUnmanaged(u8) = .empty;
    defer mod_backend_type.deinit(b.allocator);
    try mod_backend_type.appendSlice(b.allocator, "const ShaderCollection = struct {\n");

    const backend_structs: []std.ArrayListUnmanaged(u8) =
        try b.allocator.alloc(std.ArrayListUnmanaged(u8), backends.len);
    for (backend_structs) |*backend_struct|
        backend_struct.* = .empty;
    defer {
        for (backend_structs) |*backend_struct|
            backend_struct.deinit(b.allocator);
        b.allocator.free(backend_structs);
    }

    var dir_stack: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (dir_stack.items) |dir|
            b.allocator.free(dir);
        dir_stack.deinit(b.allocator);
    }

    var wf = b.addWriteFiles();
    var it = try root_dir.walk(b.allocator);
    defer it.deinit();

    var last_it_stack_len: usize = 0;
    while (try it.next()) |entry| : (last_it_stack_len = it.stack.items.len) {
        var cur_dir = if (dir_stack.items.len > 0)
            dir_stack.items[dir_stack.items.len - 1]
        else
            root_path;

        if (entry.kind == .directory) {
            for (backend_structs) |*content| {
                try content.appendSlice(
                    b.allocator,
                    b.fmt(".{s} = .{{\n", .{entry.basename}),
                );
            }

            try mod_backend_type.appendSlice(
                b.allocator,
                b.fmt("{s}: struct {{\n", .{entry.basename}),
            );

            try dir_stack.append(b.allocator, b.pathJoin(&.{ cur_dir, entry.basename }));
            continue;
        }

        if (it.stack.items.len < last_it_stack_len) {
            for (backend_structs) |*content|
                try content.appendSlice(b.allocator, "},\n");
            try mod_backend_type.appendSlice(b.allocator, "},");
            b.allocator.free(cur_dir);
            _ = dir_stack.pop();
            cur_dir = if (dir_stack.items.len > 0)
                dir_stack.items[dir_stack.items.len - 1]
            else
                root_path;
        }

        const shader_type: ShaderType = if (std.mem.startsWith(u8, entry.basename, "fs_"))
            .fragment
        else if (std.mem.startsWith(u8, entry.basename, "vs_"))
            .vertex
        else if (std.mem.startsWith(u8, entry.basename, "cs_"))
            .compute
        else
            continue;

        const stem = std.fs.path.stem(entry.basename);
        for (backends, backend_structs) |backend, *content| {
            if (!backend.enabled)
                continue;

            const model = backend.shader_default_model;
            const basename = b.fmt("{}_{s}_{s}", .{ dir_stack.items.len, @tagName(model), stem });
            const name = b.fmt("{s}.bin", .{basename});
            const input_path = b.pathJoin(&.{ cur_dir, entry.basename });
            const compiled_shader = buildShaderInner(
                b,
                bi,
                shaderc,
                target,
                b.path(input_path),
                name,
                shader_type,
                model,
            );

            _ = wf.addCopyFile(compiled_shader, name);

            try file_decls.appendSlice(
                b.allocator,
                b.fmt("const raw_{s} = @embedFile(\"{s}\");\n", .{ basename, name }),
            );

            try content.appendSlice(
                b.allocator,
                b.fmt(".{s} = raw_{s}[0..],\n", .{ stem, basename }),
            );
        }

        try mod_backend_type.appendSlice(b.allocator, b.fmt("{s}: []const u8 = &.{{}},\n", .{stem}));
    }

    for (dir_stack.items) |_| {
        for (backend_structs) |*content|
            try content.appendSlice(b.allocator, "},\n");
        try mod_backend_type.appendSlice(b.allocator, "};\n");
    }

    try mod_backend_type.appendSlice(b.allocator, "};\n");

    var module_content: std.ArrayListUnmanaged(u8) = .empty;
    defer module_content.deinit(b.allocator);

    try module_content.appendSlice(b.allocator, file_decls.items);
    try module_content.appendSlice(b.allocator, mod_backend_type.items);

    for (backends, backend_structs) |backend, content| {
        try module_content.appendSlice(
            b.allocator,
            b.fmt("pub const {s}: ShaderCollection = .{{\n", .{backend.name}),
        );
        try module_content.appendSlice(b.allocator, content.items);
        try module_content.appendSlice(b.allocator, "};\n");
    }

    return wf.add("shader_module.zig", module_content.items);
}

fn buildShaderInner(
    b: *std.Build,
    bi: BuildInfo,
    shaderc: *std.Build.Step.Compile,
    target: std.Target,
    input: std.Build.LazyPath,
    output_basename: []const u8,
    shader_type: ShaderType,
    shader_model: ShaderModel,
) std.Build.LazyPath {
    const shaderc_step = b.addRunArtifact(shaderc);
    shaderc_step.addArg("-i");
    shaderc_step.addDirectoryArg(bi.upstream_bgfx.path("src"));
    shaderc_step.addArg("-f");
    shaderc_step.addFileArg(input);
    shaderc_step.addArg("-o");
    const output = shaderc_step.addOutputFileArg(output_basename);

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

fn buildInstallBgfx(b: *std.Build, bi: BuildInfo) !void {
    const lib = b.addLibrary(.{
        .name = "bgfx",
        .root_module = b.createModule(.{
            .target = bi.target,
            .optimize = bi.optimize,
        }),
    });

    const tag = lib.rootModuleTarget().os.tag;
    switch (tag) {
        .linux => {
            lib.linkSystemLibrary("GL");
            lib.linkSystemLibrary("X11");
        },
        .windows => {
            lib.linkSystemLibrary("opengl32");
            lib.linkSystemLibrary("gdi32");
        },
        .macos => {},
        else => {
            std.debug.print("warning: unsupported os {s}, no system library linked", .{@tagName(tag)});
        },
    }

    // enable backends
    const backends = try getBackends(b, bi.target.result.os.tag);
    for (backends) |backend| {
        if (backend.enabled)
            lib.root_module.addCMacro(backend.bgfx_config_macro, "1");
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

    includeBx(bi, lib);

    lib.linkLibCpp();

    // install lib and headers
    b.installArtifact(lib);
    lib.installHeadersDirectory(bi.upstream_bx.path("include"), "", .{});
    lib.installHeadersDirectory(bi.upstream_bimg.path("include"), "", .{});
    lib.installHeadersDirectory(bi.upstream_bgfx.path("include"), "", .{});
}

fn buildShaderc(
    b: *std.Build,
    bi: BuildInfo,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "shaderc",
        .root_module = b.createModule(.{
            .target = bi.target,
            .optimize = optimize,
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

    includeBx(bi, exe);
    exe.linkLibCpp();

    return exe;
}

fn includeBx(bi: BuildInfo, comp: *std.Build.Step.Compile) void {
    comp.root_module.addCMacro("BX_CONFIG_DEBUG", "0");
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

fn getBackends(b: *std.Build, tag: std.Target.Os.Tag) ![]const Backend {
    var backends: std.ArrayListUnmanaged(Backend) = .empty;
    for (backend_definitions) |def| {
        const enabled = blk: {
            if (b.option(bool, def.name, def.option_descr)) |enabled| {
                break :blk enabled;
            } else {
                for (def.supported_platforms) |supported_tag| {
                    if (tag == supported_tag) {
                        break :blk true;
                    }
                }

                break :blk false;
            }
        };

        try backends.append(b.allocator, Backend.init(enabled, def));
    }

    return backends.items;
}

const Backend = struct {
    enabled: bool,
    name: []const u8,
    shader_default_model: ShaderModel,
    bgfx_config_macro: []const u8,

    fn init(enabled: bool, def: BackendDef) Backend {
        return .{
            .enabled = enabled,
            .name = def.name,
            .shader_default_model = def.shader_default_model,
            .bgfx_config_macro = def.bgfx_config_macro,
        };
    }
};

const BackendDef = struct {
    name: []const u8,
    option_descr: []const u8,
    supported_platforms: []const std.Target.Os.Tag,
    shader_default_model: ShaderModel,
    bgfx_config_macro: []const u8,
};

const backend_definitions: []const BackendDef = &.{
    .{
        .name = "opengl",
        .option_descr = "Enable OpenGL backend",
        .supported_platforms = &.{ .windows, .linux, .macos },
        .shader_default_model = .@"120",
        .bgfx_config_macro = "BGFX_CONFIG_RENDERER_OPENGL",
    },
    .{
        .name = "vulkan",
        .option_descr = "Enable Vulkan backend",
        .supported_platforms = &.{ .windows, .linux },
        .shader_default_model = .spirv,
        .bgfx_config_macro = "BGFX_CONFIG_RENDERER_VULKAN",
    },
    .{
        .name = "directx",
        .option_descr = "Enable DirectX 11 backend",
        .supported_platforms = &.{.windows},
        .shader_default_model = .s_5_0,
        .bgfx_config_macro = "BGFX_CONFIG_RENDERER_DIRECT3D11",
    },
    .{
        .name = "metal",
        .option_descr = "Enable Metal backend",
        .supported_platforms = &.{.macos},
        .shader_default_model = .metal,
        .bgfx_config_macro = "BGFX_CONFIG_RENDERER_METAL",
    },
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
