// single shader embedded
const fs_color = @embedFile("fs_color");

// generated module from full shader directory hierarchy
const shader = @import("shader");

pub fn main() void {
    std.debug.print("embedded fs_color shader size: {}\n", .{fs_color.len});

    std.debug.print("example of available shaders from module:\n", .{});
    inline for (@typeInfo(shader).@"struct".decls) |decl| {
        const backend = @field(shader, decl.name);
        std.debug.print(
            "    {s}.nested.fs_color2 shader size: {}\n",
            .{ decl.name, @field(backend, "nested").fs_color2.len },
        );
    }
}

const std = @import("std");
