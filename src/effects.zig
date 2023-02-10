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
pub const biquad_d2 = struct {
    w1: f64 = 0, // sample[n - 1]
    w2: f64 = 0, // sample[n - 2]
    a0: f64,
    b1: f64,
    a1: f64,
    b2: f64,
    a2: f64,

    /// Lowpass filter based on Robert Bristow-Johnson's equations
    /// Perhaps every synth code that doesn't use SVF uses these
    /// equations :)
    /// @param fc     resonant frequency
    /// @param q      resonance (gain at fc)
    /// @param sr     sample rate
    /// @param gain   amplification (gain at 0Hz)
    /// 
    pub inline fn set_lp_rbj(fc: f32, q: f32, sr: f32, _gain: ?f32) @This()
    {
        const gain: f32 = if(_gain) |g| g else 1.0; // default param value of 1.0
        const omega=(2.0*m.pi*fc/sr);
        const sn=m.sin(omega);
        const cs=m.cos(omega);
        const alpha=(sn/(2*q));
        const inv=(1.0/(1.0+alpha));

        const a0 =  (gain*inv*(1.0 - cs)*0.5);
        const a2 =  a0;
        const a1 =  a0 + a0;
        const b1 =  (-2.0*cs*inv);
        const b2 =  ((1.0 - alpha)*inv);

        return .{
            .a0 = a0,
            .a1 = a1,
            .a2 = a2,
            .b1 = b1,
            .b2 = b2,
        };
    }

    /// Applies a peak eq filter to a z value
    pub inline fn apply_peak_eq_filter(
        sample_rate: f64,  // hz
        freq:        f32,  // hz
        gain:        f32,
        Q:           f32,  // filter "width"
    ) @This() {
        const A     = m.sqrt(gain);
        const w0 = freq * 2 * m.pi * (1.0 / sample_rate);
        const alpha = m.sin(w0) / (2 * Q);
        const ib0 = 1.0 / (1 + alpha / A);

        // std.log.info("sr = {d}, A = {d}, w0 = {d}, alpha = {d}, ib0 = {d}", .{sample_rate, A, w0, alpha, ib0});

        return .{
            .b1 = -2.0 * m.cos(w0) * ib0,
            .a1 = -2.0 * m.cos(w0) * ib0,
            .a0 = ib0 * (1 + alpha * A),
            .a2 = ib0 * (1 - alpha * A),
            .b2 = ib0 * (1 - alpha / A),
        };
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
