pub fn main() !void {
    const width = 800;
    const height = 600;

    const window = c.SDL_CreateWindow(
        "sdl-bgfx-example",
        c.SDL_WINDOWPOS_UNDEFINED,
        c.SDL_WINDOWPOS_UNDEFINED,
        width,
        height,
        c.SDL_WINDOW_SHOWN | c.SDL_WINDOW_RESIZABLE,
    ) orelse {
        std.debug.print("failed to create SDL window\n", .{});
        return error.SdlCreateWindow;
    };
    defer c.SDL_DestroyWindow(window);

    var wmi: c.SDL_SysWMinfo = undefined;
    wmi.version.major = c.SDL_MAJOR_VERSION;
    wmi.version.minor = c.SDL_MINOR_VERSION;
    wmi.version.patch = c.SDL_PATCHLEVEL;

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

    // platform dependent WM setup
    if (c.SDL_GetWindowWMInfo(window, &wmi) == c.SDL_FALSE) {
        std.debug.print("failed to get SDL window WM info\n", .{});
        return error.SdlGetWindowWmInfo;
    }

    switch (builtin.os.tag) {
        .linux => switch (wmi.subsystem) {
            c.SDL_SYSWM_X11 => {
                bgfx_init.platformData.ndt = wmi.info.x11.display;
                bgfx_init.platformData.nwh = @ptrFromInt(wmi.info.x11.window);
            },
            c.SDL_SYSWM_WAYLAND => {
                std.debug.print("Wayland not supported\n", .{});
                return error.UnsupportedPlatform;
            },
            else => {
                std.debug.print(
                    "unsupported windowing subsystem (SDL_SYSWM_TYPE={})\n",
                    .{wmi.subsystem},
                );
                return error.UnsupportedPlatform;
            },
        },
        .windows => {
            bgfx_init.platformData.nwh = wmi.info.win.window;
        },
        .macos => {
            bgfx_init.platformData.nwh = wmi.info.cocoa.window;
            bgfx_init.platformData.ndt = null;
        },
        else => {
            std.debug.print("unsupported os: {s}\n", .{@tagName(builtin.os.tag)});
            return error.UnsupportedPlatform;
        },
    }

    c.bgfx_set_platform_data(&bgfx_init.platformData);

    // macos needs this
    _ = c.bgfx_render_frame(-1);

    if (!c.bgfx_init(&bgfx_init)) {
        std.debug.print("failed to initialize bgfx\n", .{});
        return error.BgfxInit;
    }
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
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => running = false,
                c.SDL_KEYDOWN => switch (event.key.keysym.sym) {
                    c.SDLK_q, c.SDLK_ESCAPE => running = false,
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

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_syswm.h");
    @cInclude("bgfx/c99/bgfx.h");
});
const builtin = @import("builtin");
const std = @import("std");
