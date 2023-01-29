//! CLAP integration. ALl of the ugly host interop should
//! live here as well.
const std = @import("std");
const c = @import("c.zig");
const c_allocator = std.heap.c_allocator;
const span = std.mem.span;

const plugin = @import("plugin.zig");
const PluginClass = plugin.PluginClass;

/// The entrypoint to all of the plugins
export const clap_entry = c.clap_plugin_entry {
    .clap_version = .{.major = 1, .minor = 1, .revision = 6},
    .init = init_plugin,
    .deinit = deinit_plugin,
    .get_factory = get_factory
};

const PluginFactory = c.clap_plugin_factory_t {
    .get_plugin_count = get_plugin_count,
    .get_plugin_descriptor = get_plugin_descriptor,
    .create_plugin = create_plugin,
};

pub const PluginDescriptor = c.clap_plugin_descriptor {
    .clap_version = .{
        .major = c.CLAP_VERSION_MAJOR,
        .minor = c.CLAP_VERSION_MINOR,
        .revision = c.CLAP_VERSION_REVISION
    },
    .id          = "zig.HelloCLAP",
    .name        = "HelloCLAP",
    .vendor      = "Christopher Odom (also nakst)",
    .url         = "https://chrisodom.org/",
    .support_url = "https://chrisodom.org/",
    .manual_url  = "https://chrisodom.org/",
    .version     = "1.0.0",
    .description = "The ziggiest plugin ever.",
    .features    = &[_][*c]const u8{
        c.CLAP_PLUGIN_FEATURE_INSTRUMENT,
        c.CLAP_PLUGIN_FEATURE_SYNTHESIZER,
        c.CLAP_PLUGIN_FEATURE_STEREO,
        null, // cringing @ null termination xD
    },
};

fn get_plugin_count(_: [*c]const c.clap_plugin_factory_t) callconv(.C) u32 {
    return 1;
}

fn get_plugin_descriptor(
    _: [*c]const c.clap_plugin_factory_t,
    index: u32, // index
) callconv(.C) [*c]const c.clap_plugin_descriptor_t{
    return if(index == 0) &PluginDescriptor else null;
}

fn create_plugin(
    factory:   [*c]const c.clap_plugin_factory,
    host:      [*c]const c.clap_host_t,
    plugin_id: [*c]const u8,
) callconv(.C) [*c]const c.clap_plugin_t {
    _ = factory;
    if(
        !c.clap_version_is_compatible(host.*.clap_version) or
        !std.mem.eql(u8, span(plugin_id), span(PluginDescriptor.id))
    ) {
        return null;
    }

    var ret = c_allocator.create(plugin) catch return null;
    ret.* = .{
        .host = host,
        .clap_plugin = PluginClass,
        .sample_rate = 0,
        .voices = undefined,
    };
    ret.clap_plugin.plugin_data = @ptrCast(?*anyopaque, ret);
    return &ret.clap_plugin;
}

fn init_plugin(path: [*c]const u8) callconv(.C) bool {
    _ = path;
    return true;
}

fn deinit_plugin() callconv(.C) void {
}

fn get_factory(factory_id: [*c]const u8) callconv(.C) ?*const anyopaque {
    if(std.mem.eql(u8, span(factory_id), c.CLAP_PLUGIN_FACTORY_ID[0..]))
        return &PluginFactory;
    return null;
}

pub fn log(
    comptime level: std.log.Level,
    comptime _: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = "(" ++ level.asText() ++ ") ";

    // Print the message to stderr, silently ignoring any errors
    std.debug.getStderrMutex().lock();
    defer std.debug.getStderrMutex().unlock();
    const stderr = std.io.getStdErr().writer();
    nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;
}
