# BGFX

Build BGFX with Zig. Includes BGFX library and `shaderc` shader compiler. Comes with helpers to compile shaders from `build.zig`.

The [example](example) directory contains a fully working example using both BGFX library and `shaderc` helpers.

## How to use

Add the dependency to your `build.zig.zon`, either via:

```
zig fetch --save git+https://github.com/jean-dao/zig-bgfx
```

Or by manually adding a local version:

```zig
.zig_bgfx = .{
    .path = "path/to/zig-bgfx",
},
```

## Build BGFX

You can then include BGFX in your `build.zig`, e.g.:

```zig
const bgfx = b.dependency("zig_bgfx", .{
    .optimize = .ReleaseFast,
});
exe.linkLibrary(bgfx.artifact("bgfx"));
```

And use the library by including the C API header, e.g.:

```zig
const c = @cImport({
    @cInclude("bgfx/c99/bgfx.h");
});
```

### Available backends

The following BGFX backends are supported:

- `vulkan`
- `opengl`
- `directx11`
- `directx12`
- `metal`

The `opengles` backend is not tested and not included by default, but can be manually enabled.

By default the following backends will be enabled on the following targets:

- linux: `vulkan`, `opengl`
- windows: `vulkan`, `opengl`, `directx11`, `directx12`
- macos: `metal`

You can manually enable/disable targets via options, e.g.:

```zig
const bgfx = b.dependency("zig_bgfx", .{
    .optimize = .ReleaseFast,
    .opengl = false,
});
```

A specific OpenGL version can be set via the "opengl-version" option. It is used to set the `BGFX_CONFIG_RENDERER_OPENGL` build macro, thus following the same format: 2-digit major/minor number (e.g. "21" is OpenGL 2.1).

## Using `shaderc`

`shaderc` is not built by default, if you're just interested in getting the binary, run `zig build -Dbgfx=false -Dshaderc` from this directory. (`-Dbgfx=false` disables building the BGFX library).

Some helpers are also provided to directly build shaders from `build.zig`. To use them, you need first to import the project in your `build.zig` script, e.g.:

```zig
const zig_bgfx = @import("zig_bgfx");
```

You can then use the following helpers.

### `buildShader()`

Compile a single shader from source file. Returns a `LazyPath` that can either be directly imported from source code, or be installed to `zig-out`, e.g.:

```zig
const shader = zig_bgfx.buildShader(
    b,                                        // *std.Build
    .{
        .target = target.result,              // std.Target
        .path = b.path("path/to/shader.sc"),  // LazyPath of the shader source
        .type = .fragment,                    // ShaderType (matches `shaderc` `--type` option)
        .modle = .spirv,                      // ShaderModel (matches `shaderc` `--profile` option)
    },
);

// install to zig-out
const shader_install = b.addInstallFile(shader, "my_shader.bin");
b.getInstallStep().dependOn(&shader_install.step);
```

### `buildShaderDir()`

Compile a directory hierarchy of shader source files. Returns a `std.Build.Step.WriteFile` that can either be directly imported from source code (see [`createShaderModule()`](#createShaderModule) below), or be installed to `zig-out`, e.g.:

```zig
const shader_dir = try zig_bgfx.buildShaderDir(
    b,                                    // *std.Build
    .{
        .target = target.result,          // std.Target
        .root_path = "shader_directory",  // path of shaders root directory
        // backend_configs omitted to use default
    },
);

// install to zig-out
const shader_dir_install = b.addInstallDirectory(.{
    .source_dir = shader_dir.files.getDirectory(),
    .install_dir = .prefix,
    .install_subdir = "my_shader_dir",
});
b.getInstallStep().dependOn(&shader_dir_install.step);
```

Shader files need to end with `.sc` and need to be prefixed with:

-  Fragment shaders: `fs_`
-  Vertex shaders: `vs_`
-  Compute shaders: `cs_`

Shader files will be compiled for each backend defined by the `backend_configs` parameter. See `default_shaderc_backend_configs` for the default backend definitions. See [example/build.zig](example/build.zig) for an example of custom backend definitions.

### `createShaderModule()`

Create a Zig module from a directory of compiled shaders generated by [`buildShaderDir()`](#buildShaderDir).

The module can then be imported and used by Zig source code. The module root struct will contain a declaration per backend, each supported backend will contain all compiled shader accessible as `[]const u8` fields, e.g.:

```zig
const my_shader_lib = @import("my_shader_lib");
const shaders = switch (c.bgfx_get_renderer_type()) {
    c.BGFX_RENDERER_TYPE_OPENGL => my_shader_lib.opengl,
    c.BGFX_RENDERER_TYPE_VULKAN => my_shader_lib.vulkan,
    c.BGFX_RENDERER_TYPE_DIRECT3D11 => my_shader_lib.directx,
    c.BGFX_RENDERER_TYPE_METAL => my_shader_lib.metal,
    else => std.debug.panic("GPU is not supported", .{}),
};

const ref = c.bgfx_make_ref(shaders.foo.fs_bar.ptr, @intCast(shaders.foo.fs_bar.len));
const shader_handle = c.bgfx_create_shader(ref);
```

**Warning**: Make sure the shader models defined by the [`buildShaderDir()`](#buildshaderdir) `backend_configs` parameter are compatible with the BGFX library compiled backends. For example, a BGFX library compiled with "opengl-version=21" won't be able to load shaders compiled with a shader model "140" (GLSL 1.4), since OpenGL 2.1 only support GLSL 1.2 (shader model "120").
