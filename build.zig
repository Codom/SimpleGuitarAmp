const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const lib = b.addSharedLibrary("vst", "src/main.zig", b.version(1, 0, 0));
    lib.setBuildMode(mode);
    lib.linkLibC();
    lib.addIncludeDir("clap/include/");
    lib.install();

    const main_tests = b.addTest("src/main.zig");
    main_tests.setBuildMode(mode);
    main_tests.linkLibC();
    main_tests.addIncludeDir("clap/include/");

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}
