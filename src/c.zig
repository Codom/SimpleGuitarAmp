//
// c.zig
// Copyright (C) 2023 Christopher Odom <christopher.r.odom@gmail.com>
//
// Distributed under terms of the MIT license.
//

pub const c = @cImport({
    @cInclude("clap/clap.h");
});
