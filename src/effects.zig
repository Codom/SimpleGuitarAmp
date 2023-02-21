//
// effects.zig
// Copyright (C) 2023 Christopher Odom <christopher.r.odom@gmail.com>
//
// Distributed under terms of the MIT license.
//
//! Implements several basic effect primitives
//!
//! A lot of this work is based off of freely available work
//! from other plugins, namely the CALF audio suite and equations
//! from the Faust standard library.
const std = @import("std");

/// std.math is used a lot, so we truncate it's namespace to m
const m = std.math;

/// Cubic nonlineary distortion that appoximates solid state
/// distortion
///
/// This is taken from the Faust standard library
pub fn cub_nonl_distortion(in: f32, gain: f32, offset: f32) f32 {
        const offset_in = in + offset;
        const pregain = offset_in * std.math.pow(f32, 10.0, gain * 2.0);
        const clip = std.math.clamp(pregain, -1.0, 1.0);
        const out = clip - ((clip*clip*clip*clip) / 3.0);
        return out;
}


/// This is derived from the Robert Bristow-Johnson's equations,
/// and the specific implementation from the calf audio tools suite.
///
/// Implements direct form 2 as it is slightly faster.
pub const biquad_d2 = struct {
    w1: f64 = 0, // sample[n - 1]
    w2: f64 = 0, // sample[n - 2]
    a0: f64,
    b1: f64,
    a1: f64,
    b2: f64,
    a2: f64,

    /// Returns a zero-init biquad
    pub inline fn init() @This() {
        return std.mem.zeroes(@This());
    }

    pub inline fn init_bandpass(freq_center: f64, q: f64, gain: f64, sample_rate: f64) @This() {
        var ret = std.mem.zeroes(@This());
        ret.set_bandpass(freq_center, q, gain, sample_rate);
        return ret;
    }

    pub inline fn init_peak(freq_center: f64, q: f64, gain: f64, sample_rate: f64) @This() {
        var ret = std.mem.zeroes(@This());
        ret.set_peak(freq_center, q, gain, sample_rate);
        return ret;
    }

    pub inline fn set_bandpass(self: *@This(), freq_center: f64, q: f64, gain: f64, sample_rate: f64) void {
        const omega = 2.0 * m.pi * freq_center / sample_rate;
        const sn = m.sin(omega);
        const cs = m.cos(omega);
        const alpha = sn / (2.0*q);

        const inv = 1.0 / (1.0 + alpha);

        self.a0 = gain * inv * alpha;
        self.a1 = 0.0;
        self.a2 = -gain * inv * alpha;
        self.b1 = -2 * cs * inv;
        self.b2 = (1 - alpha) * inv;
    }

    pub inline fn set_peak(self: *@This(), freq_center: f64, q: f64, gain: f64, sample_rate: f64) void { 
        const A = m.sqrt(gain);
        const w0 = freq_center * 2 * m.pi * (1.0 / sample_rate);
        const alpha = m.sin(w0) / (2 * q);
        const ib0 = 1.0 / (1 + alpha / A);

        const a1b1 = -2 * m.cos(w0) * ib0;

        self.a0 = ib0 * (1 + alpha * A);
        self.a1 = a1b1;
        self.a2 = ib0 * (1 - alpha * A);
        self.b1 = a1b1;
        self.b2 = ib0 * (1 - (alpha / A));
    }

    pub inline fn bi_sanitize(self: *@This()) void {
        sanitize(&self.w1);
        sanitize(&self.w2);
    }

    /// Processes input n sample
    pub inline fn process (
        self: *@This(),
        in:  f32,
    ) f32 {
        var n: f32 = in;
        normalize(&n);
        sanitize(&n);
        sanitize(&self.w1);
        sanitize(&self.w2);

        const tmp = n - self.w1 * self.b1 - self.w2 * self.b2;
        const out = tmp * self.a0 + self.w1 * self.a1 + self.w2 * self.a2;
        self.w2 = self.w1;
        self.w1 = tmp;

        // std.log.info("{d}, {d}, {d}", .{tmp, self.w1, self.w2});

        return @floatCast(f32, out);
    }
};

fn normalize(n: anytype) void {
    assert_float_ptr(n);

    if(!m.isNormal(n.*)) {
        n.* = 0;
    }
}

fn sanitize(n: anytype) void {
    assert_float_ptr(n);

    const small_value = (1.0/16777216.0);
    if(@fabs(n.*) < small_value) n.* = 0;
}

fn assert_float_ptr(n: anytype) void {
    const N = @TypeOf(n);
    if(N != *f32 and N != *f64) {
        @compileError("Valid usage of sanitize is on *f32 or *f64");
    }
}
