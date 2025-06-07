// shaders in "shaders" directory, automatically compiled with `shaderc`
const shaders_lib = @import("shaders_lib");

pub fn main() void {
    const width = 800;
    const height = 600;

    if (!c.SDL_Init(c.SDL_INIT_VIDEO))
        sdlError("failed to initialize SDL");
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("zig-bgfx-example", width, height, 0) orelse {
        sdlError("failed to create SDL window");
    };
    defer c.SDL_DestroyWindow(window);

    // make sure to properly populate `bgfx_init_t` struct
    // see the following definition in BGFX `src/bgfx.cpp` file:
    // - Init::Init()
    // - Init::Limits::Limits()
    // - Resolution::Resolution()
    // - PlatformData::PlatformData()
    // the C API doesn't provide defaults
    var bgfx_init = std.mem.zeroes(c.bgfx_init_t);
    bgfx_init.type = c.BGFX_RENDERER_TYPE_COUNT;
    bgfx_init.vendorId = c.BGFX_PCI_ID_NONE;
    bgfx_init.capabilities = std.math.maxInt(u64);
    bgfx_init.resolution.format = c.BGFX_TEXTURE_FORMAT_RGBA8;
    bgfx_init.resolution.width = width;
    bgfx_init.resolution.height = height;
    bgfx_init.resolution.reset = c.BGFX_RESET_VSYNC;
    bgfx_init.resolution.numBackBuffers = 2;
    bgfx_init.limits.maxEncoders = 8;
    bgfx_init.limits.minResourceCbSize = 64 << 10;
    bgfx_init.limits.transientVbSize = 6 << 20;
    bgfx_init.limits.transientIbSize = 2 << 20;

    bgfx_init.platformData = getPlatformData(window);
    c.bgfx_set_platform_data(&bgfx_init.platformData);

    // macos needs this
    _ = c.bgfx_render_frame(-1);

    // initialize BGFX
    if (!c.bgfx_init(&bgfx_init))
        std.debug.panic("failed to initialize bgfx\n", .{});
    defer c.bgfx_shutdown();

    const renderer_type = c.bgfx_get_renderer_type();
    const backend_name = c.bgfx_get_renderer_name(renderer_type);
    std.debug.print("Using {s} backend\n", .{backend_name});

    // select shaders compatible with current BGFX backend
    const shaders = switch (renderer_type) {
        c.BGFX_RENDERER_TYPE_OPENGL => shaders_lib.opengl,
        c.BGFX_RENDERER_TYPE_VULKAN => shaders_lib.vulkan,
        c.BGFX_RENDERER_TYPE_DIRECT3D11 => shaders_lib.directx,
        c.BGFX_RENDERER_TYPE_METAL => shaders_lib.metal,
        else => @panic("GPU is not supported"),
    };

    // create cube vertex buffer and index buffer
    const vbh, const ibh = createCube();
    defer c.bgfx_destroy_vertex_buffer(vbh);
    defer c.bgfx_destroy_index_buffer(ibh);

    // create programs
    const programs: []const struct {
        name: [:0]const u8,
        handle: c.bgfx_program_handle_t,
    } = &.{
        .{
            .name = "plain",
            .handle = createProgram(shaders.vs_default, shaders.fs_color),
        },
        .{
            .name = "shaded",
            .handle = createProgram(shaders.vs_default, shaders.fs_shaded),
        },
    };
    defer {
        for (programs) |program|
            c.bgfx_destroy_program(program.handle);
    }

    // create uniform
    const u_color = c.bgfx_create_uniform("u_color", c.BGFX_UNIFORM_TYPE_VEC4, 1);
    defer c.bgfx_destroy_uniform(u_color);

    // show debug text
    c.bgfx_set_debug(c.BGFX_DEBUG_TEXT);

    // set view 0 clear state
    c.bgfx_set_view_clear(0, c.BGFX_CLEAR_COLOR | c.BGFX_CLEAR_DEPTH, 0x333333ff, 1, 0);

    // main loop
    var running = true;
    var mesh_rotation: f32 = 0;
    var program_index: usize = 0;
    var color_index: usize = 0;
    while (running) {
        // handle events
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_KEY_DOWN => switch (event.key.key) {
                    c.SDLK_Q, c.SDLK_ESCAPE => running = false,
                    c.SDLK_SPACE => program_index = (program_index + 1) % programs.len,
                    c.SDLK_TAB => color_index = (color_index + 1) % colors.len,
                    else => {},
                },
                else => {},
            }
        }

        mesh_rotation += 0.05;
        if (mesh_rotation >= 2.0 * std.math.pi)
            mesh_rotation = 0;

        const program = programs[program_index];
        const color = colors[color_index];

        // setup view
        const at: math.Vec3 = .{ 0, 0, 0 };
        const eye: math.Vec3 = .{ 0, 6, -15 };
        const view: [16]f32 = math.mtxLookAt(eye, at);
        const proj: [16]f32 = math.mtxProj(
            60,
            @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height)),
            0.01,
            100,
            c.bgfx_get_caps().*.homogeneousDepth,
        );
        c.bgfx_set_view_transform(0, &view, &proj);
        c.bgfx_set_view_rect(0, 0, 0, width, height);

        // submit cube
        const transform = math.mtxRotateY(mesh_rotation);
        _ = c.bgfx_set_transform(&transform, 1);
        c.bgfx_set_uniform(u_color, &color, 1);
        c.bgfx_set_vertex_buffer(0, vbh, 0, std.math.maxInt(u32));
        c.bgfx_set_index_buffer(ibh, 0, std.math.maxInt(u32));
        c.bgfx_set_state(c.BGFX_STATE_WRITE_R | c.BGFX_STATE_WRITE_G |
            c.BGFX_STATE_WRITE_B | c.BGFX_STATE_WRITE_A |
            c.BGFX_STATE_WRITE_Z | c.BGFX_STATE_DEPTH_TEST_LESS |
            c.BGFX_STATE_CULL_CCW | c.BGFX_STATE_MSAA, 0);
        c.bgfx_submit(0, program.handle, 1, c.BGFX_DISCARD_ALL);

        // print debug text
        c.bgfx_dbg_text_clear(0, false);
        c.bgfx_dbg_text_printf(1, 1, 0xf, "Using %s backend", backend_name);
        c.bgfx_dbg_text_printf(1, 2, 0xf, "Current program: %s", program.name.ptr);
        c.bgfx_dbg_text_printf(1, 4, 0xf, "Press Space to cycle through programs");
        c.bgfx_dbg_text_printf(1, 5, 0xf, "Press Tab to cycle through colors");

        // render frame
        _ = c.bgfx_frame(false);
    }
}

const colors: []const [4]f32 = &.{
    .{ 1, 0.23, 0.19, 1 },
    .{ 1, 0.58, 0, 1 },
    .{ 1, 0.8, 0, 1 },
    .{ 0.2, 0.78, 0.35, 1 },
    .{ 0.35, 0.78, 0.98, 1 },
    .{ 0, 0.48, 1, 1 },
    .{ 0.69, 0.32, 0.87, 1 },
    .{ 1, 0.18, 0.33, 1 },
    .{ 0.39, 0.82, 1, 1 },
    .{ 0.69, 1, 0.34, 1 },
};

fn createProgram(vs: []const u8, fs: []const u8) c.bgfx_program_handle_t {
    const vs_ref = c.bgfx_make_ref(vs.ptr, @intCast(vs.len)) orelse @panic("OOM");
    const vs_handle = c.bgfx_create_shader(vs_ref);
    assertValidHandle(vs_handle);

    const fs_ref = c.bgfx_make_ref(fs.ptr, @intCast(fs.len)) orelse @panic("OOM");
    const fs_handle = c.bgfx_create_shader(fs_ref);
    assertValidHandle(fs_handle);

    const prog_handle = c.bgfx_create_program(vs_handle, fs_handle, true);
    assertValidHandle(prog_handle);

    return prog_handle;
}

fn createCube() struct { c.bgfx_vertex_buffer_handle_t, c.bgfx_index_buffer_handle_t } {
    // define vertex layout
    const Vertex = [6]f32;
    var layout = std.mem.zeroes(c.bgfx_vertex_layout_s);
    _ = c.bgfx_vertex_layout_begin(&layout, c.BGFX_RENDERER_TYPE_NOOP);
    _ = c.bgfx_vertex_layout_add(
        &layout,
        c.BGFX_ATTRIB_POSITION,
        3,
        c.BGFX_ATTRIB_TYPE_FLOAT,
        false,
        false,
    );
    _ = c.bgfx_vertex_layout_add(
        &layout,
        c.BGFX_ATTRIB_NORMAL,
        3,
        c.BGFX_ATTRIB_TYPE_FLOAT,
        false,
        false,
    );
    c.bgfx_vertex_layout_end(&layout);

    // define vertices
    const vertex_count = 4 * 5; // skip bottom face
    const vertices, const vertices_mem = bgfxAlloc(Vertex, vertex_count);

    vertices[0] = .{ -1, -1, 1, 0, 0, 1 };
    vertices[1] = .{ 1, -1, 1, 0, 0, 1 };
    vertices[2] = .{ -1, 1, 1, 0, 0, 1 };
    vertices[3] = .{ 1, 1, 1, 0, 0, 1 };

    vertices[4] = .{ 1, -1, 1, 1, 0, 0 };
    vertices[5] = .{ 1, -1, -1, 1, 0, 0 };
    vertices[6] = .{ 1, 1, 1, 1, 0, 0 };
    vertices[7] = .{ 1, 1, -1, 1, 0, 0 };

    vertices[8] = .{ -1, -1, -1, -1, 0, 0 };
    vertices[9] = .{ -1, -1, 1, -1, 0, 0 };
    vertices[10] = .{ -1, 1, -1, -1, 0, 0 };
    vertices[11] = .{ -1, 1, 1, -1, 0, 0 };

    vertices[12] = .{ 1, -1, -1, 0, 0, -1 };
    vertices[13] = .{ -1, -1, -1, 0, 0, -1 };
    vertices[14] = .{ 1, 1, -1, 0, 0, -1 };
    vertices[15] = .{ -1, 1, -1, 0, 0, -1 };

    vertices[16] = .{ -1, 1, 1, 0, 1, 0 };
    vertices[17] = .{ 1, 1, 1, 0, 1, 0 };
    vertices[18] = .{ -1, 1, -1, 0, 1, 0 };
    vertices[19] = .{ 1, 1, -1, 0, 1, 0 };

    // define indices
    const index_count = 5 * 2 * 3; // 2 triangles per face
    const indices, const indices_mem = bgfxAlloc(u32, index_count);

    for ([_]u32{ 0, 1, 2, 3, 4 }) |idx| {
        indices[idx * 6 + 0] = idx * 4 + 0;
        indices[idx * 6 + 1] = idx * 4 + 1;
        indices[idx * 6 + 2] = idx * 4 + 2;
        indices[idx * 6 + 3] = idx * 4 + 1;
        indices[idx * 6 + 4] = idx * 4 + 3;
        indices[idx * 6 + 5] = idx * 4 + 2;
    }

    const vbh = c.bgfx_create_vertex_buffer(vertices_mem, &layout, c.BGFX_BUFFER_NONE);
    assertValidHandle(vbh);

    const ibh = c.bgfx_create_index_buffer(indices_mem, c.BGFX_BUFFER_INDEX32);
    assertValidHandle(ibh);

    return .{ vbh, ibh };
}

fn bgfxAlloc(comptime T: type, count: usize) struct { []T, *const c.bgfx_memory_t } {
    const size: u32 = @intCast(count * @sizeOf(T));
    const mem: *const c.bgfx_memory_t = c.bgfx_alloc(size) orelse @panic("OOM");
    const ptr: [*]align(@alignOf(T)) T = @alignCast(@ptrCast(mem.data));
    return .{ ptr[0..count], mem };
}

fn assertValidHandle(handle: anytype) void {
    std.debug.assert(handle.idx != std.math.maxInt(u16));
}

fn getPlatformData(window: *c.SDL_Window) c.bgfx_platform_data_t {
    var data = std.mem.zeroes(c.bgfx_platform_data_t);

    switch (builtin.os.tag) {
        .linux => {
            const video_driver = std.mem.span(c.SDL_GetCurrentVideoDriver() orelse {
                sdlError("failed to get SDL video driver");
            });

            if (std.mem.eql(u8, video_driver, "x11")) {
                data.type = c.BGFX_NATIVE_WINDOW_HANDLE_TYPE_DEFAULT;
                data.ndt = getWindowPtrProp(window, c.SDL_PROP_WINDOW_X11_DISPLAY_POINTER);
                data.nwh = getWindowIntProp(window, c.SDL_PROP_WINDOW_X11_WINDOW_NUMBER);
            } else if (std.mem.eql(u8, video_driver, "wayland")) {
                data.type = c.BGFX_NATIVE_WINDOW_HANDLE_TYPE_WAYLAND;
                data.ndt = getWindowPtrProp(window, c.SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER);
                data.nwh = getWindowPtrProp(window, c.SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER);
            } else {
                std.debug.panic("unsupported window driver: {s}\n", .{video_driver});
            }
        },
        .windows => {
            data.nwh = getWindowPtrProp(window, c.SDL_PROP_WINDOW_WIN32_HWND_POINTER);
        },
        .macos => {
            data.nwh = getWindowPtrProp(window, c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER);
        },
        else => {
            std.debug.panic("unsupported os: {s}\n", .{@tagName(builtin.os.tag)});
        },
    }

    return data;
}

fn getWindowPtrProp(window: *c.SDL_Window, prop: [:0]const u8) *anyopaque {
    const properties = c.SDL_GetWindowProperties(window);
    if (properties == 0)
        sdlError("failed to get SDL window properties");

    return c.SDL_GetPointerProperty(properties, prop, null) orelse {
        std.debug.panic("failed to get SDL window property '{s}'", .{prop});
    };
}

fn getWindowIntProp(window: *c.SDL_Window, prop: [:0]const u8) *anyopaque {
    const properties = c.SDL_GetWindowProperties(window);
    if (properties == 0)
        sdlError("failed to get SDL window properties");

    // No idea if 0 is a valid property
    return @ptrFromInt(@as(usize, @intCast(c.SDL_GetNumberProperty(properties, prop, 0))));
}

fn sdlError(msg: []const u8) noreturn {
    std.debug.print("{s}: {s}\n", .{ msg, c.SDL_GetError() });
    std.process.exit(1);
}

const math = @import("math.zig");
const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("bgfx/c99/bgfx.h");
});
const builtin = @import("builtin");
const std = @import("std");
