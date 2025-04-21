pub fn main() void {
    const width = 800;
    const height = 600;

    if (!c.SDL_Init(c.SDL_INIT_VIDEO))
        sdlError("failed to initialize SDL");
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow("sdl-bgfx-example", width, height, 0) orelse {
        sdlError("failed to create SDL window");
    };
    defer c.SDL_DestroyWindow(window);

    // make sure to properly populate `bgfx_init_t` struct
    // see `Init::Init()` and `Init::Limits::Limits()` in BGFX `src/bgfx.cpp` file
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

    if (!c.bgfx_init(&bgfx_init))
        std.debug.panic("failed to initialize bgfx\n", .{});
    defer c.bgfx_shutdown();

    std.debug.print("using {s} renderer\n", .{c.bgfx_get_renderer_name(c.bgfx_get_renderer_type())});

    // show debug text
    c.bgfx_set_debug(c.BGFX_DEBUG_TEXT);
    c.bgfx_set_view_clear(0, c.BGFX_CLEAR_COLOR | c.BGFX_CLEAR_DEPTH, 0xdeadbeff, 1, 0);
    c.bgfx_set_view_rect(0, 0, 0, width, height);

    var frame_number: usize = 0;
    var running = true;
    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => running = false,
                c.SDL_EVENT_KEY_DOWN => switch (event.key.key) {
                    c.SDLK_Q, c.SDLK_ESCAPE => running = false,
                    else => {},
                },
                else => {},
            }
        }

        c.bgfx_set_view_rect(0, 0, 0, width, height);
        c.bgfx_touch(0);
        c.bgfx_dbg_text_clear(0, false);
        c.bgfx_dbg_text_printf(1, 1, 0x4f, "Frame#:%d", frame_number);
        frame_number = c.bgfx_frame(false);
    }
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

const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("bgfx/c99/bgfx.h");
});
const builtin = @import("builtin");
const std = @import("std");
