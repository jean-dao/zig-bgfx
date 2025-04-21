# BGFX

Build BGFX with Zig. Includes BGFX library and `shaderc` shader compiler. Comes with helpers to compile shaders from `build.zig`.

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

See [examples/sdl-bgfx](examples/sdl-bgfx) for a complete working example.

### Available backends

The following BGFX backends are available:

- `vulkan`
- `opengl`
- `directx` (DirectX 11)
- `metal`

By default the following backends will be enabled on the following targets:

- linux: `vulkan`, `opengl`
- windows: `vulkan`, `opengl`, `directx`
- macos: `metal`

You can manually enable/disable targets via options, e.g.:

```zig
const bgfx = b.dependency("zig_bgfx", .{
    .optimize = .ReleaseFast,
    .opengl = false,
});
```

## Using `shaderc`

`shaderc` is not built by default, if you're just interested in getting the binary, run `zig build -Dbgfx=false -Dshaderc` from this directory. (`-Dbgfx=false` disables building the BGFX library).

Some helpers are also provided to directly build shaders from `build.zig`. To use them, you need first to `lazyImport()` the project in your `build.zig` script, e.g.:

```zig
const zig_bgfx = b.lazyImport(@This(), "zig_bgfx") orelse {
    std.debug.print("couldn't lazyImport 'zig-bgfx'\n", .{});
    return;
};
```

You can then use the following helpers.

### `buildShader()`

Compile a single shader from source file. Returns a `LazyPath` that can either be directly imported from source code, or be installed to `zig-out`, e.g.:

```zig
const shader = zig_bgfx.buildShader(
    b,                                // *std.Build
    target.result,                    // std.Target
    b.path("path/to/shader.sc"),      // LazyPath of the shader source
    .fragment,                        // ShaderType (matches `shaderc` `--type` option)
    .spirv,                           // ShaderModel (matches `shaderc` `--profile` option)
);

// install to zig-out
const shader_install = b.addInstallFile(shader, "my_shader.bin");
b.getInstallStep().dependOn(&shader_install.step);
```

See [examples/shaderc](examples/shaderc) for a complete working example.

### `createShaderModule()`

Create a zig module from shader source hierarchy, e.g.:

```zig
const root_source_file = try zig_bgfx.createShaderModule(
    b,                       // *std.Build
    target.result,           // std.Target
    "shader_directory",      // path to shaders root directory
);

exe.root_module.addAnonymousImport("my_shader_lib", .{ .root_source_file = root_source_file });
```

The module can then be imported and used by Zig source code. The module root struct will contains a declaration per backend, each supported backend will contain all compiled shader accessible as `[]const u8` fields, e.g.:

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

Shader files need to end with `.sc` and need to be prefixed with:

-  Fragment shaders: `fs_`
-  Vertex shaders: `vs_`
-  Compute shaders: `cs_`

The shader model is derived from the backend, see `shader_default_model` fields of `BackendDef` definitions.

See [examples/shaderc](examples/shaderc) for a complete working example.
