//
// plugin.zig
// Copyright (C) 2023 Christopher Odom <christopher.r.odom@gmail.com>
//
// Distributed under terms of the MIT license.
//
//! Contains primary definitions for the actual plugin itself
const std = @import("std");
const span = std.mem.span;
const c_allocator = std.heap.c_allocator;
const c = @import("c.zig").c;

const m = std.math;

const ef = @import("effects.zig");

const P = enum(usize) {
    Gain = 0,
    OutputGain,
    Bass,
    Mid,
    Treble,
    Count,
};

fn num_params() u32 {
    return @intFromEnum(P.Count);
}

clap_plugin: c.clap_plugin_t,
host: [*c]const c.clap_host_t,
sample_rate: f64,

filters: std.ArrayList(ef.biquad_d2) = undefined,

// Parameter state
params: [num_params()]f32,
main_params: [num_params()]f32,
changed: [num_params()]bool,
main_changed: [num_params()]bool,
mut: std.Thread.Mutex,

const Plugin = @This();
// zig api

pub fn init(plugin: *Plugin) bool {
    // plugin.voices = std.ArrayList(Voice).init(c_allocator);
    plugin.mut = .{};

    var i: u32 = 0;
    while (i < num_params()) : (i += 1) {
        var info = std.mem.zeroes(c.clap_param_info_t);
        _ = ExtensionParams.extension.get_info.?(&plugin.clap_plugin, i, @ptrCast(&info));
        plugin.params[i] = @floatCast(info.default_value);
        plugin.main_params[i] = @floatCast(info.default_value);
    }
    return true;
}

pub fn activate(plugin: *Plugin, sample_rate: f64, min_frames_count: u32, max_frames_count: u32) bool {
    _ = max_frames_count;
    _ = min_frames_count;
    plugin.sample_rate = sample_rate;
    plugin.filters = std.ArrayList(ef.biquad_d2){};

    plugin.filters.append(c_allocator, ef.biquad_d2.init_peak(20, 2.3, 0.25, plugin.sample_rate)) catch unreachable;
    plugin.filters.append(c_allocator, ef.biquad_d2.init_peak(520, 0.1, 1.00, plugin.sample_rate)) catch unreachable;
    plugin.filters.append(c_allocator, ef.biquad_d2.init_peak(6000, 2.3, 0.05, plugin.sample_rate)) catch unreachable;
    return true;
}

pub fn deactivate(plugin: *Plugin) void {
    plugin.filters.deinit(c_allocator);
}

pub fn create_plugin() Plugin {
    var ret: Plugin = undefined;
    ret.clap_plugin = std.mem.zeroes(c.clap_plugin_t);
    ret.host = null;
    ret.params = .{0} ** num_params();
    ret.main_params = .{0} ** num_params();
    ret.main_changed = .{false} ** num_params();
    ret.mut = .{};
    return ret;
}

pub fn param_changed(plugin: Plugin) bool {
    for (plugin.changed) |changed| {
        if (changed) return true;
    }
    return false;
}

pub fn sync_main_to_audio(plugin: *Plugin, out: [*c]const c.clap_output_events_t) void {
    plugin.mut.lock();
    defer plugin.mut.unlock();

    var i: u32 = 0;
    while (i < num_params()) : (i += 1) {
        if (plugin.main_changed[i]) {
            plugin.params[i] = plugin.main_params[i];
            plugin.main_changed[i] = false;

            var event = std.mem.zeroes(c.clap_event_param_value_t);
            event.header = .{
                .size = @sizeOf(c.clap_event_param_value),
                .time = 0,
                .space_id = c.CLAP_CORE_EVENT_SPACE_ID,
                .type = c.CLAP_EVENT_PARAM_VALUE,
                .flags = 0,
            };
            event.param_id = i;
            event.cookie = null;
            event.note_id = -1;
            event.port_index = -1;
            event.channel = -1;
            event.key = -1;
            event.value = plugin.params[i];
            _ = out.*.try_push.?(out, &event.header);
        }
    }
    // mutex handled in defer clause
}

pub fn sync_audio_to_main(plugin: *Plugin) bool {
    plugin.mut.lock();
    defer plugin.mut.unlock();

    var i: usize = 0;
    while (i < num_params()) : (i += 1) {
        if (plugin.changed[i]) {
            plugin.main_params[i] = plugin.params[i];
            plugin.changed[i] = false;
            return true;
        }
    }
    return false;
}

pub fn process_event(plugin: *Plugin, event: [*c]const c.clap_event_header_t) void {
    if (event.*.space_id == c.CLAP_CORE_EVENT_SPACE_ID) {
        if (event.*.type == c.CLAP_EVENT_PARAM_VALUE) {
            const value_ev = ptr_as(*const c.clap_event_param_value_t, event);
            const i: u32 = value_ev.*.param_id;

            plugin.mut.lock();
            plugin.params[i] = @floatCast(value_ev.value);
            plugin.changed[i] = true;
            plugin.mut.unlock();
        }
    }
}

pub fn render_audio(plugin: *Plugin, start: u32, end: u32, inputL: [*c]f32, inputR: [*c]f32, outputL: [*c]f32, outputR: [*c]f32) void {
    var index: usize = start;
    while (index < end) : (index += 1) {
        var inL: f32 = inputL[index];
        var inR: f32 = inputR[index];

        // params
        const gain = plugin.params[@intFromEnum(P.Gain)];
        const output_gain = plugin.params[@intFromEnum(P.OutputGain)];

        // Filters
        for (plugin.filters.items) |*filter| {
            inL = filter.process(inL);
            inR = filter.process(inR);
        }
        const eqL = inL;
        const eqR = inR;

        // Distortion
        const distortionL: f32 = ef.cub_nonl_distortion(eqL, gain, 0.0) * output_gain;
        const distortionR: f32 = ef.cub_nonl_distortion(eqR, gain, 0.0) * output_gain;

        const outL = distortionL;
        const outR = distortionR;

        outputL[index] = outL;
        outputR[index] = outR;
    }
}

pub const PluginClass = c.clap_plugin_t{
    .desc = &@import("root").PluginDescriptor,
    .plugin_data = null,
    .init = clap_init,
    .destroy = clap_destroy,
    .activate = clap_activate,
    .deactivate = clap_deactivate,
    .start_processing = clap_start_processing,
    .stop_processing = clap_stop_processing,
    .reset = clap_reset,
    .process = clap_process,
    .get_extension = clap_get_extension,
    .on_main_thread = clap_on_main_thread,
};

fn clap_init(_plugin: [*c]const c.clap_plugin_t) callconv(.c) bool {
    const plugin = ptr_as(*Plugin, _plugin.*.plugin_data);
    return plugin.init();
}

fn clap_destroy(_plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    const plugin = ptr_as(*Plugin, _plugin.*.plugin_data);
    c_allocator.destroy(plugin);
}

fn clap_activate(_plugin: [*c]const c.clap_plugin_t, sample_rate: f64, min_frames_count: u32, max_frames_count: u32) callconv(.c) bool {
    const plugin = ptr_as(*Plugin, _plugin.*.plugin_data);
    return plugin.activate(sample_rate, min_frames_count, max_frames_count);
}

fn clap_deactivate(_plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    const plugin = ptr_as(*Plugin, _plugin.*.plugin_data);
    plugin.deactivate();
}

fn clap_start_processing(_plugin: [*c]const c.clap_plugin_t) callconv(.c) bool {
    _ = _plugin;
    return true;
}

fn clap_stop_processing(_plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    _ = _plugin;
}

fn clap_reset(_plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    _ = _plugin;
}

fn clap_on_main_thread(_plugin: [*c]const c.clap_plugin_t) callconv(.c) void {
    _ = _plugin;
}

fn clap_get_extension(_plugin: [*c]const c.clap_plugin_t, id: [*c]const u8) callconv(.c) ?*const anyopaque {
    const plugin = ptr_as(*Plugin, _plugin.*.plugin_data);
    _ = plugin;
    if (std.mem.eql(u8, span(id), c.CLAP_EXT_NOTE_PORTS[0..])) {
        return as_const_void(&ExtensionNotePorts.extension);
    }
    if (std.mem.eql(u8, span(id), c.CLAP_EXT_AUDIO_PORTS[0..])) {
        return as_const_void(&ExtensionAudioPorts.extension);
    }
    if (std.mem.eql(u8, span(id), c.CLAP_EXT_PARAMS[0..])) {
        return as_const_void(&ExtensionParams.extension);
    }
    if (std.mem.eql(u8, span(id), c.CLAP_EXT_STATE[0..])) {
        return as_const_void(&ExtensionState.extension);
    }
    return null;
}

fn clap_process(_plugin: [*c]const c.clap_plugin_t, _process: [*c]const c.clap_process) callconv(.c) c.clap_process_status {
    const plugin = ptr_as(*Plugin, _plugin.*.plugin_data);

    plugin.sync_main_to_audio(_process.*.out_events);

    if (plugin.param_changed()) {
        const bass_v = plugin.params[@intFromEnum(P.Bass)];
        const mid_v = plugin.params[@intFromEnum(P.Mid)];
        const treb_v = plugin.params[@intFromEnum(P.Treble)];

        plugin.filters.items[0].set_peak(20, bass_v, 0.25, plugin.sample_rate);
        plugin.filters.items[1].set_peak(520, mid_v, 1.00, plugin.sample_rate);
        plugin.filters.items[2].set_peak(6000, treb_v, 0.05, plugin.sample_rate);
    }

    const frame_count = _process.*.frames_count;
    const input_event_count = _process.*.in_events.*.size.?(_process.*.in_events);

    var event_i: u32 = 0;
    var next_event_frame: u32 = if (input_event_count != 0) 0 else frame_count;

    var i: u32 = 0;
    while (i < frame_count) {
        while (event_i < input_event_count and next_event_frame == i) {
            const event = _process.*.in_events.*.get.?(_process.*.in_events, event_i);

            if (event.*.time != i) {
                next_event_frame = event.*.time;
                break;
            }

            plugin.process_event(event);
            event_i += 1;

            if (event_i == input_event_count) {
                next_event_frame = frame_count;
                break;
            }
        }

        plugin.render_audio(i, next_event_frame, _process.*.audio_inputs[0].data32[0], _process.*.audio_inputs[0].data32[1], _process.*.audio_outputs[0].data32[0], _process.*.audio_outputs[0].data32[1]);
        i = next_event_frame;
    }

    for (plugin.filters.items) |*filter| {
        filter.bi_sanitize();
    }

    return c.CLAP_PROCESS_CONTINUE;
}

// c api

// Extension for midi ports
const ExtensionNotePorts = struct {
    const extension = c.clap_plugin_note_ports_t{
        .count = count,
        .get = get,
    };

    fn count(_: [*c]const c.clap_plugin_t, is_input: bool) callconv(.c) u32 {
        _ = is_input;
        // if(is_input) return 1;
        return 0;
    }

    fn get(_: [*c]const c.clap_plugin_t, index: u32, is_input: bool, info: [*c]c.clap_note_port_info_t) callconv(.c) bool {
        _ = index;
        _ = is_input;
        _ = info;
        return false;
        // if(!is_input or index != 0) return false;
        // info.*.id = 0;
        // info.*.supported_dialects = c.CLAP_NOTE_DIALECT_CLAP;
        // info.*.preferred_dialect = c.CLAP_NOTE_DIALECT_CLAP;
        // std.log.info("{s}", .{std.fmt.bufPrintZ(info.*.name[0..], "Note Port", .{}) catch unreachable});
        // return true;
    }
};

// Audio ports
const ExtensionAudioPorts = struct {
    const extension = c.clap_plugin_audio_ports_t{
        .count = count,
        .get = get,
    };

    fn count(_: [*c]const c.clap_plugin_t, is_input: bool) callconv(.c) u32 {
        if (is_input) return 1;
        return 1;
    }

    fn get(_: [*c]const c.clap_plugin_t, index: u32, is_input: bool, info: [*c]c.clap_audio_port_info_t) callconv(.c) bool {
        if (index != 0) return false;
        if (is_input) {
            info.*.id = 0;
            info.*.channel_count = 2;
            info.*.flags = c.CLAP_AUDIO_PORT_IS_MAIN;
            info.*.port_type = &c.CLAP_PORT_STEREO;
            info.*.in_place_pair = c.CLAP_INVALID_ID;
            _ = std.fmt.bufPrintZ(info.*.name[0..], "Audio Input", .{}) catch unreachable;
            return true;
        } else {
            info.*.id = 1;
            info.*.channel_count = 2;
            info.*.flags = c.CLAP_AUDIO_PORT_IS_MAIN;
            info.*.port_type = &c.CLAP_PORT_STEREO;
            info.*.in_place_pair = c.CLAP_INVALID_ID;
            _ = std.fmt.bufPrintZ(info.*.name[0..], "Audio Output", .{}) catch unreachable;
            return true;
        }
    }
};

// Parameters extension
//
// This tells the host about the properties of our parameters
// (.count, .get_info), gives it a way to query the current
// value of parameters (.get_value), gives it a way to
// transform values to and from text (.value_to_text,
// .text_to_value), and also provides a mechanism for
// parameter synchronization when the plugin isn't processing
// audio (.flush). (https://nakst.gitlab.io/tutorial/clap-part-2.html)
//
const ExtensionParams = struct {
    const extension = c.clap_plugin_params{
        .count = count,
        .get_info = get_info,
        .get_value = get_value,
        .value_to_text = value_to_text,
        .text_to_value = text_to_value,
        .flush = flush,
    };

    fn count(_: [*c]const c.clap_plugin_t) callconv(.c) u32 {
        return num_params();
    }

    fn get_info(_plugin: [*c]const c.clap_plugin_t, index: u32, info: [*c]c.clap_param_info) callconv(.c) bool {
        _ = _plugin;
        if (index > num_params()) {
            return false;
        }

        switch (@as(P, @enumFromInt(index))) {
            P.Gain => {
                info.* = std.mem.zeroes(c.clap_param_info);
                info.*.id = index;
                info.*.flags = c.CLAP_PARAM_IS_AUTOMATABLE | c.CLAP_PARAM_IS_MODULATABLE;
                info.*.min_value = 0.0;
                info.*.max_value = 1.0;
                info.*.default_value = 0.5;
                _ = std.fmt.bufPrintZ(info.*.name[0..], "Gain", .{}) catch unreachable;
                return true;
            },

            P.OutputGain => {
                info.* = std.mem.zeroes(c.clap_param_info);
                info.*.id = index;
                info.*.flags = c.CLAP_PARAM_IS_AUTOMATABLE | c.CLAP_PARAM_IS_MODULATABLE;
                info.*.min_value = 0.0;
                info.*.max_value = 1.0;
                info.*.default_value = 0.2;
                _ = std.fmt.bufPrintZ(info.*.name[0..], "Output Gain", .{}) catch unreachable;
                return true;
            },

            P.Bass => {
                info.* = std.mem.zeroes(c.clap_param_info);
                info.*.id = index;
                info.*.flags = c.CLAP_PARAM_IS_AUTOMATABLE | c.CLAP_PARAM_IS_MODULATABLE;
                info.*.min_value = 0.1;
                info.*.max_value = 100.0;
                info.*.default_value = 50.0;
                _ = std.fmt.bufPrintZ(info.*.name[0..], "Bass", .{}) catch unreachable;
                return true;
            },

            P.Mid => {
                info.* = std.mem.zeroes(c.clap_param_info);
                info.*.id = index;
                info.*.flags = c.CLAP_PARAM_IS_AUTOMATABLE | c.CLAP_PARAM_IS_MODULATABLE;
                info.*.min_value = 0.01;
                info.*.max_value = 100.0;
                info.*.default_value = 50.0;
                _ = std.fmt.bufPrintZ(info.*.name[0..], "Mid", .{}) catch unreachable;
                return true;
            },

            P.Treble => {
                info.* = std.mem.zeroes(c.clap_param_info);
                info.*.id = index;
                info.*.flags = c.CLAP_PARAM_IS_AUTOMATABLE | c.CLAP_PARAM_IS_MODULATABLE;
                info.*.min_value = 0.01;
                info.*.max_value = 100.0;
                info.*.default_value = 50.0;
                _ = std.fmt.bufPrintZ(info.*.name[0..], "Treble", .{}) catch unreachable;
                return true;
            },

            else => {
                return false;
            },
        }
        unreachable;
    }

    fn get_value(_plugin: [*c]const c.clap_plugin_t, id: c.clap_id, value: [*c]f64) callconv(.c) bool {
        const plugin = ptr_as(*Plugin, _plugin.*.plugin_data);
        const i: u32 = @intCast(id);
        if (i >= num_params()) return false;

        plugin.mut.lock();
        defer plugin.mut.unlock();

        var val: f64 = 0;
        if (plugin.main_changed[i]) {
            val = plugin.main_params[i];
        } else {
            val = plugin.params[i];
        }
        value.* = val;
        return true;
    }

    fn value_to_text(_plugin: [*c]const c.clap_plugin_t, id: c.clap_id, value: f64, display: [*c]u8, size: u32) callconv(.c) bool {
        _ = _plugin;
        const i: u32 = @intCast(id);
        if (i >= num_params()) return false;

        switch (@as(P, @enumFromInt(i))) {
            else => {
                _ = std.fmt.bufPrintZ(display[0..size], "{d:.2}", .{value}) catch unreachable;
                return true;
            },
        }
    }

    fn text_to_value(_plugin: [*c]const c.clap_plugin_t, id: c.clap_id, display: [*c]const u8, value: [*c]f64) callconv(.c) bool {
        _ = _plugin;
        _ = id;
        _ = display;
        _ = value;
        return false;
    }

    fn flush(_plugin: [*c]const c.clap_plugin_t, ev_in: [*c]const c.clap_input_events_t, ev_out: [*c]const c.clap_output_events_t) callconv(.c) void {
        const plugin = ptr_as(*Plugin, _plugin.*.plugin_data);
        const ev_count = ev_in.*.size.?(ev_in);
        plugin.sync_main_to_audio(ev_out);

        var i: u32 = 0;
        while (i < ev_count) : (i += 1) {
            plugin.process_event(ev_in.*.get.?(ev_in, i));
        }
    }
};

const ExtensionState = struct {
    const extension = c.clap_plugin_state_t{
        .save = save,
        .load = load,
    };

    fn save(_plugin: [*c]const c.clap_plugin, stream: [*c]const c.clap_ostream) callconv(.c) bool {
        const plugin = ptr_as(*Plugin, _plugin.*.plugin_data);

        var ok = plugin.sync_audio_to_main();
        if (!ok) {
            std.log.err("Failed to sync audio to main!!!", .{});
        }

        const size = @sizeOf(f32) * num_params();
        var write_size: i64 = 0;
        while (size != write_size) { // if write_size is 0, then error
            const nbytes = stream.*.write.?(stream, as_void(&plugin.main_params), size);
            if (nbytes == 0) {
                break;
            }
            write_size += nbytes;
        }
        ok = ok or size == write_size;

        return ok;
    }

    fn load(_plugin: [*c]const c.clap_plugin, stream: [*c]const c.clap_istream) callconv(.c) bool {
        const plugin = ptr_as(*Plugin, _plugin.*.plugin_data);

        plugin.mut.lock();
        const size = @sizeOf(f32) * num_params();
        var read_size = stream.*.read.?(stream, as_void(&plugin.main_params), size);
        while (size != read_size and read_size <= 0) { // if read_size is 0, then error
            const nbytes = stream.*.read.?(stream, as_void(&plugin.main_params), size);
            if (nbytes == 0) {
                break;
            }

            read_size += nbytes;
        }
        plugin.mut.unlock();

        return size == read_size;
    }
};

// I hate dealing with c style type erasure in zig, so these
// make the process a bit more concise
fn as_void(ptr: anytype) ?*anyopaque {
    return @ptrCast(ptr);
}

fn as_const_void(ptr: anytype) ?*const anyopaque {
    return @ptrCast(ptr);
}

fn ptr_as(comptime T: anytype, ptr: anytype) T {
    return @ptrCast(@alignCast(ptr));
}

fn percent_to_hz(percent: anytype) f64 {
    return percent_log_scale(percent, 20.0, 20000.0);
}

// Does a logarithmic interp between the two values with a
// percentage value.
fn percent_log_scale(percent: anytype, y1: anytype, y2: anytype) f64 {
    const logx1 = 1;
    const logy1 = m.log10(y1);

    const logx2 = m.log10(101.0);
    const logy2 = m.log10(y2);

    const logx = m.log10(percent + 1);
    const logy = logy1 + (logx - logx1) * ((logy2 - logy1) / (logx2 - logx1));

    return m.pow(f64, 10, logy);
}
