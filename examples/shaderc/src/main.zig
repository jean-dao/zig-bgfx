// single shader embedded
const fs_color = @embedFile("fs_color");

// generated module from full shader directory hierarchy
const shader = @import("shader");

pub fn main() void {
    std.debug.print("embedded fs_color shader size: {}\n", .{fs_color.len});

    std.debug.print("example of shaders from module:\n", .{});
    inline for (@typeInfo(shader).@"struct".decls) |decl| {
        const backend = @field(shader, decl.name);
        const fs_color2 = backend.nested.fs_color2;
        if (fs_color2.len == 0) {
            std.debug.print("    {s}.nested.fs_color2 not available\n", .{decl.name});
        } else {
            std.debug.print(
                "    {s}.nested.fs_color2 shader size: {}\n",
                .{ decl.name, fs_color2.len },
            );
        }
    }
}

const std = @import("std");
