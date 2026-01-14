const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const clap_mod = b.addModule("ZigGuitarAmp", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });


    const lib = b.addLibrary(.{
        .name = "vst",
        .root_module = clap_mod,
        .linkage = .dynamic,
    });
    lib.linkLibC();
    const clap_dep = b.dependency("clap", .{});
    lib.addIncludePath(clap_dep.path("include"));
    b.installArtifact(lib);
}
