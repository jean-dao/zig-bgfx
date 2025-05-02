// Matrix related code mostly translated from github.com/bkaradzic/bx/blob/master/src/math.cpp
pub const Vec3 = @Vector(3, f32);

pub fn mtxLookAt(eye: Vec3, at: Vec3) [16]f32 {
    const up: Vec3 = .{ 0, 1, 0 };
    const view = vecNormalize(at - eye);
    const uxv = vecCross(up, view);
    const right: Vec3 = if (vecDot(uxv, uxv) == 0) .{ -1, 0, 0 } else vecNormalize(uxv);
    const new_up = vecCross(view, right);

    return .{
        right[0],
        new_up[0],
        view[0],
        0,

        right[1],
        new_up[1],
        view[1],
        0,

        right[2],
        new_up[2],
        view[2],
        0,

        -vecDot(right, eye),
        -vecDot(new_up, eye),
        -vecDot(view, eye),
        1,
    };
}

pub fn mtxProj(
    fovy_deg: f32,
    aspect_ratio: f32,
    near: f32,
    far: f32,
    homogeneousNdc: bool,
) [16]f32 {
    const fovy_rad = fovy_deg * std.math.pi / 180;
    const height = 1.0 / std.math.tan(fovy_rad * 0.5);
    const width = height * 1.0 / aspect_ratio;
    const diff = far - near;
    const aa = if (homogeneousNdc) (far + near) / diff else far / diff;
    const bb = if (homogeneousNdc) (2.0 * far * near) / diff else near * aa;
    var mtx = std.mem.zeroes([16]f32);
    mtx[0] = width;
    mtx[5] = height;
    mtx[10] = aa;
    mtx[11] = 1;
    mtx[14] = -bb;
    return mtx;
}

pub fn mtxRotateY(rot_rad: f32) [16]f32 {
    const sin = std.math.sin(rot_rad);
    const cos = std.math.cos(rot_rad);

    var mtx = std.mem.zeroes([16]f32);
    mtx[0] = cos;
    mtx[2] = sin;
    mtx[5] = 1;
    mtx[8] = -sin;
    mtx[10] = cos;
    mtx[15] = 1;
    return mtx;
}

pub fn mtxScale(scale: Vec3) [16]f32 {
    var mtx = std.mem.zeroes([16]f32);
    mtx[0] = scale[0];
    mtx[5] = scale[1];
    mtx[10] = scale[2];
    mtx[15] = 1;
    return mtx;
}

pub fn mtxId() [16]f32 {
    var mtx = std.mem.zeroes([16]f32);
    mtx[0] = 1;
    mtx[5] = 1;
    mtx[10] = 1;
    mtx[15] = 1;
    return mtx;
}

fn vecNormalize(v: Vec3) Vec3 {
    const len = blk: {
        const real_len = vecLen(v);
        break :blk if (real_len != 0)
            real_len
        else
            std.math.floatMin(f32);
    };
    return v * @as(Vec3, @splat(1.0 / len));
}

fn vecCross(v1: Vec3, v2: Vec3) Vec3 {
    return .{
        v1[1] * v2[2] - v1[2] * v2[1],
        v1[2] * v2[0] - v1[0] * v2[2],
        v1[0] * v2[1] - v1[1] * v2[0],
    };
}

fn vecLen(v: Vec3) f32 {
    return @sqrt(vecDot(v, v));
}

fn vecDot(v1: Vec3, v2: Vec3) f32 {
    return @reduce(.Add, v1 * v2);
}

const std = @import("std");
